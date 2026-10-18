//
//  GeminiLiveAudioPlayer.swift
//  Cuse
//
//  Streams PCM16 24kHz audio chunks (Gemini Live or OpenAI Realtime) to the
//  speakers in real time. Owns an AVAudioPlayerNode but NOT an AVAudioEngine
//  — the session passes in a shared engine so mic capture and playback both
//  run on the same engine. That's a hard requirement for Apple's voice
//  processing (AUVoiceIO) AEC to work: the audio unit needs to see both
//  uplink (mic) and downlink (speaker) on the same engine to subtract
//  speaker bleed from the mic input.
//
//  Why not AVAudioPlayer: it requires a complete audio file. Realtime APIs
//  stream audio in ~40ms chunks over the WebSocket — we need to queue each
//  chunk for playback the instant it arrives.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class GeminiLiveAudioPlayer {

    // MARK: - State

    private let playerNode = AVAudioPlayerNode()

    /// PCM16 mono at 24kHz — both Gemini Live and OpenAI Realtime emit
    /// audio in this format, so the same player works for both.
    private let streamAudioFormat: AVAudioFormat

    /// The engine the player is currently attached to. Owned by the
    /// session, not by us — this is a weak reference so a dropped
    /// session doesn't keep the engine alive.
    private weak var sharedEngine: AVAudioEngine?

    /// Whether the player node is currently attached + connected to
    /// `sharedEngine`. Used to avoid double-attach and to guard
    /// scheduleBuffer when the session hasn't called attach yet.
    private var isAttachedAndConnected: Bool = false

    /// Number of audio buffers we've scheduled on `playerNode` but
    /// that haven't been rendered (consumed) yet. The session uses
    /// this — NOT `playerNode.isPlaying` — to decide when the model
    /// is actually done speaking. `AVAudioPlayerNode.isPlaying` stays
    /// true forever once `play()` is called, regardless of whether the
    /// scheduled queue has drained, so it's useless as a "have we
    /// finished playing?" signal.
    ///
    /// scheduleBuffer's completion handler runs on an audio thread, so
    /// access is lock-protected.
    private var pendingBufferCountStorage: Int = 0
    private let pendingBufferLock = NSLock()

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: GeminiLiveClient.outputSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("[GeminiLiveAudio] Could not create 24kHz PCM16 format — this should never happen")
        }
        self.streamAudioFormat = format
    }

    // MARK: - Engine Attach / Detach

    /// Attach the player node to a shared engine. The session calls this
    /// during `startMicCapture` BEFORE installing the mic tap and BEFORE
    /// enabling voice processing on the input node — the engine has to
    /// know about both directions before AUVoiceIO is wired up, otherwise
    /// the downlink DSP has no clock and the AEC fails with
    /// "audio time stamp does not have valid sample time" log spam.
    ///
    /// Connects the player to the engine's mainMixerNode so the engine
    /// handles sample-rate conversion from our 24kHz source to whatever
    /// the output device wants.
    func attach(to engine: AVAudioEngine) {
        // If we're already attached to this exact engine, no-op.
        if isAttachedAndConnected, sharedEngine === engine {
            return
        }
        // If we're attached to a different (older) engine, detach first.
        if isAttachedAndConnected, let previous = sharedEngine, previous !== engine {
            previous.detach(playerNode)
            isAttachedAndConnected = false
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: streamAudioFormat)
        sharedEngine = engine
        isAttachedAndConnected = true
        print("[GeminiLiveAudio] player node attached to shared engine")
    }

    /// Detach the player from its current engine. Called by the session
    /// during stop / narration enter so the engine can be torn down or
    /// reconfigured for a new session.
    func detach() {
        guard isAttachedAndConnected, let engine = sharedEngine else {
            return
        }
        playerNode.stop()
        engine.detach(playerNode)
        sharedEngine = nil
        isAttachedAndConnected = false
        print("[GeminiLiveAudio] player node detached")
    }

    /// Start the player node. The session must have already started the
    /// shared engine — we don't touch engine lifecycle here.
    func startPlaying() {
        guard isAttachedAndConnected, let engine = sharedEngine, engine.isRunning else {
            return
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Clear any queued audio and re-arm the player so subsequent
    /// scheduleBuffer calls play back immediately. Used on barge-in /
    /// echo-suppressed interrupt. Resets the pending buffer counter
    /// since playerNode.stop() flushes the queue without firing any
    /// completion handlers.
    func clearQueuedAudio() {
        guard isAttachedAndConnected else { return }
        playerNode.stop()
        pendingBufferLock.withLock { pendingBufferCountStorage = 0 }
        if let engine = sharedEngine, engine.isRunning {
            playerNode.play()
        }
        print("[GeminiLiveAudio] Audio queue cleared")
    }

    // MARK: - Audio Chunk Playback

    /// Schedule a PCM16 24kHz audio chunk for playback. Chunks play back
    /// in order — AVAudioPlayerNode handles the queueing. Auto-starts the
    /// player node on first chunk so the session doesn't have to call
    /// `startPlaying()` separately.
    func enqueueAudioChunk(_ pcm16Data: Data) {
        guard isAttachedAndConnected else {
            print("[GeminiLiveAudio] dropped chunk — player not attached to an engine yet")
            return
        }
        guard let engine = sharedEngine, engine.isRunning else {
            print("[GeminiLiveAudio] dropped chunk — shared engine not running")
            return
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        guard let audioBuffer = makeAudioBuffer(from: pcm16Data) else {
            print("[GeminiLiveAudio] Could not create buffer from \(pcm16Data.count)-byte chunk")
            return
        }

        // Track this buffer through render so the session can detect
        // when audio actually finishes playing. The completion handler
        // runs on a real-time audio thread — keep it cheap and lock-safe.
        pendingBufferLock.withLock { pendingBufferCountStorage += 1 }
        playerNode.scheduleBuffer(audioBuffer) { [weak self] in
            self?.pendingBufferLock.withLock {
                if let self = self, self.pendingBufferCountStorage > 0 {
                    self.pendingBufferCountStorage -= 1
                }
            }
        }
    }

    /// Convert a raw PCM16 Data chunk into an AVAudioPCMBuffer that
    /// AVAudioPlayerNode can schedule.
    private func makeAudioBuffer(from pcm16Data: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(streamAudioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        // PCM16 mono => byte count must be divisible by 2. If the server
        // ever sends a different format (stereo, PCM24, etc.), the raw
        // bytes would produce scrambled audio or a silently-dropped
        // buffer. Reject and log instead of schedule-and-hope.
        guard pcm16Data.count % bytesPerFrame == 0 else {
            print("[GeminiLiveAudio] ⚠ dropped \(pcm16Data.count)-byte chunk — not a multiple of \(bytesPerFrame) bytes/frame. Audio format may have changed upstream.")
            return nil
        }
        let frameCount = pcm16Data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: streamAudioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }

        audioBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy the raw PCM16 bytes straight into the buffer's int16ChannelData.
        guard let destinationBuffer = audioBuffer.int16ChannelData?[0] else { return nil }
        pcm16Data.withUnsafeBytes { rawSourcePointer in
            guard let sourceInt16Pointer = rawSourcePointer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }
            destinationBuffer.update(from: sourceInt16Pointer, count: frameCount)
        }

        return audioBuffer
    }

    /// Whether the player has any unrendered buffers in its queue.
    /// THIS — not `playerNode.isPlaying` — is what the session uses to
    /// decide when the model is finished speaking. `AVAudioPlayerNode`'s
    /// `isPlaying` property reports whether `play()` has been called,
    /// not whether there's still audio to render, so it stays true
    /// forever after the first scheduled buffer.
    var isPlaying: Bool {
        return pendingBufferLock.withLock { pendingBufferCountStorage > 0 }
    }

    /// Exposed for sessions that want to inspect the count directly
    /// (e.g. for logging). Same value `isPlaying` checks.
    var pendingBufferCount: Int {
        return pendingBufferLock.withLock { pendingBufferCountStorage }
    }
}
