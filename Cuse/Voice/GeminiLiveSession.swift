//
//  GeminiLiveSession.swift
//  Cuse
//
//  Orchestrates a full Gemini Live conversation session:
//    1. Opens a WebSocket to Gemini via GeminiLiveClient
//    2. Captures mic audio with AVAudioEngine, converts to PCM16 16kHz,
//       and streams it over the WebSocket
//    3. Sends a screenshot at session start so Gemini can see the screen
//    4. Plays back audio responses in real time via GeminiLiveAudioPlayer
//    5. Routes Gemini's CUA action plan tool calls
//       to CompanionManager via callbacks
//

import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class GeminiLiveSession: ObservableObject {

    // MARK: - Published State (bindable from SwiftUI)

    /// Whether a Gemini Live session is currently active.
    @Published private(set) var isActive: Bool = false

    /// Latest partial transcript of what the user is saying.
    @Published private(set) var inputTranscript: String = ""

    /// Whether the model is currently speaking (audio is playing back).
    @Published private(set) var isModelSpeaking: Bool = false {
        didSet {
            // Mirror to a thread-safe atomic so the mic tap callback (which
            // runs on the real-time audio thread) can read without hopping
            // to main actor.
            modelSpeakingLock.withLock { modelSpeakingFlag = isModelSpeaking }
        }
    }

    /// Lock-protected mirror of `isModelSpeaking` for audio-thread reads.
    private var modelSpeakingFlag: Bool = false
    private let modelSpeakingLock = NSLock()

    /// Current mic audio power level (0.0–1.0), for driving the waveform animation.
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0.0

    // MARK: - Callbacks

    /// Fires whenever new input transcript text arrives (the user's speech
    /// as Gemini heard it). CompanionManager uses this to detect "a new
    /// utterance just began" so the per-turn dedup flag resets at the
    /// right moment — NOT on model turn-complete, which false-fires when
    /// ambient noise re-triggers Gemini.
    var onInputTranscriptUpdate: ((String) -> Void)?

    /// Fires when the model finishes its turn.
    var onTurnComplete: (() -> Void)?

    /// Fires when the user interrupts the model (barge-in).
    var onInterrupted: (() -> Void)?

    /// Fires on fatal errors so the caller can surface them to the user.
    var onError: ((Error) -> Void)?

    /// Legacy handler for older Gemini sessions that still call the removed
    /// point tool. New sessions use `submit_workflow_plan`.
    var onPointAtElement: ((_ id: String, _ label: String, _ box2DNormalized: [Int]?, _ screenshotJPEG: Data?) async -> [String: Any])?

    /// Fired when Gemini calls `submit_workflow_plan(goal, app, steps)`.
    /// Gemini produces the plan itself via its own vision + reasoning, so
    /// the handler just hands the steps off to WorkflowRunner and returns
    /// an acknowledgement — no separate planner round-trip needed.
    var onSubmitWorkflowPlan: ((_ id: String, _ goal: String, _ app: String, _ steps: [[String: Any]]) async -> [String: Any])?

    /// Fired when Gemini calls `create_note(title, body)`.
    /// This deterministic demo path opens Notes, creates a note, and types
    /// the supplied content as one voice tool call.
    var onCreateNote: ((_ id: String, _ title: String?, _ body: String) async -> [String: Any])?

    // MARK: - Dependencies

    private let geminiClient = GeminiLiveClient()
    private let audioPlayer = GeminiLiveAudioPlayer()

    /// Whether the local audio queue still has speech scheduled for
    /// playback. Used by the handoff-close logic in CompanionManager
    /// to avoid cutting off Gemini's acknowledgement mid-word.
    var isAudioPlaying: Bool {
        return audioPlayer.isPlaying
    }
    /// AVAudioEngine is rebuilt every session. Reusing a single engine
    /// across sessions caches the input format at the moment of first
    /// creation — if the user later changes input device (AirPods on/off,
    /// sample rate switch from 44.1k to 48k, etc.), installTap explodes
    /// with a format-mismatch fault because we ask for the old format.
    /// A fresh engine per session always queries the CURRENT input format.
    private var audioEngine = AVAudioEngine()
    private let pcm16Converter = BuddyPCM16AudioConverter(targetSampleRate: GeminiLiveClient.inputSampleRate)

    private let systemPrompt: String

    /// Whether the audio input tap has been installed on the engine.
    private var isAudioTapInstalled: Bool = false

    /// Timer that periodically captures a fresh screenshot and sends it to
    /// Gemini so it sees screen changes during the conversation.
    ///
    /// 3 seconds is a deliberate choice. The AX tree lookup (primary pointing
    /// path) is LIVE — it always reflects the current UI state — so we don't
    /// need frequent screenshot refreshes to keep coordinates fresh. The
    /// screenshot only matters for Gemini's visual context ("what is the
    /// user looking at"), which tolerates a few seconds of lag.
    ///
    /// Previously was 1.5s + ran YOLO on every tick, which starved Core Audio
    /// and caused audible stutter in Gemini's speech. YOLO now runs only
    /// on-demand when AX tree lookups miss.
    private var screenshotUpdateTimer: Timer?
    private static let screenshotUpdateInterval: TimeInterval = 3.0

    /// The most recent screenshot sent to Gemini, with full metadata.
    /// CompanionManager reads this when handling tool calls so it can map
    /// Gemini's box_2d coordinates (which are relative to this exact
    /// screenshot) to the correct screen location. Without this the
    /// coordinates would be off by the drift between "what Gemini saw"
    /// and "current screen".
    @Published private(set) var latestCapture: CompanionScreenCapture?

    /// Privacy toggle: when false, this session does not capture or send
    /// screen JPEGs to Gemini. Voice and tool calls still work, but the
    /// model must rely on spoken instructions and local tool results.
    @Published private(set) var isScreenshotStreamingEnabled: Bool = true

    /// Last perceptual hash sent to Gemini, keyed by the screen label
    /// from CompanionScreenCapture (stable per display across ticks).
    /// If a fresh capture is within the dHash threshold we skip the
    /// upload — Gemini already has an equivalent frame. The cache is
    /// cleared on session start and on `invalidateScreenshotHashCache()`
    /// (called by CompanionManager when a tool call fails so we never
    /// accidentally suppress a frame the model needs to re-see).
    private var lastSentScreenshotHashByScreenLabel: [String: UInt64] = [:]

    /// Whether a reconnect attempt is in progress. Prevents the error
    /// path from reporting a fatal error while we're still trying to
    /// recover transparently.
    private var reconnectInFlight: Bool = false

    /// Reconnect attempt counter — resets to zero on successful connect
    /// and caps the exponential backoff at a sane ceiling.
    private var reconnectAttemptIndex: Int = 0
    private static let maxReconnectAttempts: Int = 5

    // MARK: - Init

    init(systemPrompt: String) {
        self.systemPrompt = systemPrompt

        geminiClient.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleGeminiEvent(event)
            }
        }
    }

    // MARK: - Session Lifecycle

    /// Start a new Gemini Live session. Opens the WebSocket, sends the
    /// initial screenshot, and begins streaming mic audio.
    /// Throws if the API key fetch or WebSocket setup fails.
    func start(initialScreenshot: Data?) async throws {
        guard !isActive else {
            print("[GeminiLiveSession] Already active — ignoring start()")
            return
        }

        var startupCompleted = false
        defer { if !startupCompleted { stop() } }
        let apiKey = try await fetchAPIKey()

        try await RetryWithExponentialBackoff.run(
            maxAttempts: 3,
            initialDelay: 0.5,
            operationName: "GeminiLive.connect"
        ) { [weak self] in
            guard let self else {
                throw NSError(domain: "GeminiLiveSession", code: -13,
                              userInfo: [NSLocalizedDescriptionKey: "Session deallocated during WebSocket connect"])
            }
            try await self.geminiClient.connect(
                apiKey: apiKey,
                systemPrompt: self.systemPrompt
            )
        }

        try Task.checkCancellation()

        if !isScreenshotStreamingEnabled {
            geminiClient.sendText("""
            Privacy mode is active: screenshot streaming is disabled for this session. You cannot see the user's screen unless the user explicitly provides visual context in text. Use voice instructions, app names, accessibility labels, workflow tools, and local action execution. Do not claim that you can see the screen.
            """)
        }

        // Fresh session = fresh visual context. Drop any cached hashes
        // from a previous session so the very first frame is always sent
        // (otherwise restarting Cuse on the same unchanged screen would
        // suppress the initial screenshot Gemini needs to see).
        lastSentScreenshotHashByScreenLabel.removeAll()

        try startMicCapture()

        // The player is now attached to the same engine that startMicCapture
        // just started. Prime the player node so the first audio chunk
        // plays back without scheduling latency.
        audioPlayer.startPlaying()

        isActive = true
        startupCompleted = true
        inputTranscript = ""
        hasReceivedUserSpeechThisSession = false
        didSendStateSyncScreenshotForCurrentUserTurn = false

        startPeriodicScreenshotUpdates()

        // Send visual context after the mic is live so the user can start
        // speaking as soon as Gemini setup completes. This avoids making
        // the hotkey feel blocked on ScreenCaptureKit/JPEG work.
        _ = initialScreenshot
        if isScreenshotStreamingEnabled {
            Task { @MainActor in
                await captureAndProcessFrameForGemini()
            }
        }

        print("[GeminiLiveSession] Session started")
    }

    /// End the session — stops mic capture, closes WebSocket, stops playback.
    func stop() {

        stopPeriodicScreenshotUpdates()
        hasReceivedUserSpeechThisSession = false
        didSendStateSyncScreenshotForCurrentUserTurn = false
        stopMicCapture()
        // Player detach happened inside stopMicCapture; clear any
        // residual buffered audio so it doesn't replay on next session.
        audioPlayer.clearQueuedAudio()
        geminiClient.disconnect()

        isActive = false
        isModelSpeaking = false
        print("[GeminiLiveSession] Session stopped")
    }

    /// True after a successful tool call until the user speaks again.
    /// While this is set, `captureAndProcessFrameForGemini` skips the
    /// network push of fresh screenshots. The mic stays live, so the
    /// moment Gemini hears the user speak (any inputTranscript chunk),
    /// the flag clears and screenshots resume.
    ///
    /// Why: after a tool call succeeds (cursor pointed at File, plan
    /// submitted, etc.), Gemini interprets every subsequent screenshot
    /// of "user hasn't moved yet" as "user still needs help" and
    /// re-emits the same tool call. The user reads/acts at human
    /// speed; we have to mute the visual stream to stop the loop.
    private(set) var areScreenshotsSuppressedUntilUserSpeaks: Bool = false

    /// True after Gemini has transcribed at least one user speech chunk
    /// in the current session. Startup screenshots and AX mark messages
    /// are visual context, not user prompts; gating text-only mark sends
    /// behind real speech prevents Gemini from speaking first on connect.
    private var hasReceivedUserSpeechThisSession = false
    private var didSendStateSyncScreenshotForCurrentUserTurn = false

    /// Mark that a tool call was just satisfied, so subsequent
    /// screenshot pushes should be suppressed until the user speaks.
    /// CompanionManager calls this after a successful CUA action plan.
    /// The flag self-clears on the next
    /// inputTranscript chunk (i.e. the user spoke).
    func suppressScreenshotsUntilUserSpeaks() {
        guard isActive else { return }
        if !areScreenshotsSuppressedUntilUserSpeaks {
            print("[GeminiLiveSession] 🔇 screenshots suppressed until user speaks")
        }
        areScreenshotsSuppressedUntilUserSpeaks = true
    }

    /// Manually clear the suppression flag — used when CompanionManager
    /// detects a new push-to-talk press, in case the mic-detected
    /// inputTranscript signal is delayed.
    func clearScreenshotSuppression() {
        guard areScreenshotsSuppressedUntilUserSpeaks else { return }
        areScreenshotsSuppressedUntilUserSpeaks = false
        print("[GeminiLiveSession] 🔊 screenshot suppression cleared")
    }

    /// Send a text input to Gemini — kept around for future use (e.g.
    /// programmatic questions or context injection).
    func sendText(_ text: String) {
        guard isActive else { return }
        geminiClient.sendText(text)
    }

    /// Capture and send one fresh frame for an explicit user gesture, such
    /// as a committed focus highlight. This bypasses scene-deduplication
    /// and post-action screenshot suppression because the user is asking
    /// the model to look at a specific region now.
    func sendFreshScreenshotForUserContext() async -> CompanionScreenCapture? {
        guard isActive, isScreenshotStreamingEnabled else {
            return latestCapture
        }

        guard let screenshots = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
              let primaryCapture = screenshots.first else {
            return latestCapture
        }

        latestCapture = primaryCapture
        if let newHash = ScreenshotPerceptualHash.perceptualHash(forJPEGData: primaryCapture.imageData) {
            lastSentScreenshotHashByScreenLabel[primaryCapture.label] = newHash
        }
        geminiClient.sendScreenshot(primaryCapture.imageData)
        return primaryCapture
    }

    // MARK: - Push-To-Talk Mic Gating
    //
    // With classic push-to-talk semantics the user HOLDS the hotkey
    // while speaking and RELEASES to commit. On press we resume mic
    // streaming; on release we stop streaming audio to Gemini but
    // keep the WebSocket + audio player alive so Gemini's response
    // plays back cleanly. This eliminates ambient-noise contamination
    // and gives Gemini an immediate end-of-speech signal (no waiting
    // for VAD to guess), cutting perceived response latency.

    /// Stop streaming mic audio to Gemini. The audio engine is torn
    /// down so no buffers are even captured — zero ambient noise
    /// leaks, zero CPU cost. Safe no-op when already paused.
    func pauseMicCaptureForPushToTalk() {
        guard isActive else { return }
        stopMicCapture()
        print("[GeminiLiveSession] 🎤 Mic paused (push-to-talk released)")
    }

    /// Restart mic streaming when the user holds the hotkey for a
    /// new utterance. Rebuilds the audio engine from scratch because
    /// the input device/sample-rate may have changed since last use.
    func resumeMicCaptureForPushToTalk() {
        guard isActive else { return }
        do {
            try startMicCapture()
            print("[GeminiLiveSession] 🎤 Mic resumed (push-to-talk pressed)")
        } catch {
            print("[GeminiLiveSession] ✗ Failed to resume mic for push-to-talk: \(error)")
        }
    }

    // MARK: - Periodic Screenshot Updates

    /// Start sending fresh screenshots every 1.5s so Gemini sees window
    /// changes, scrolls, new content, etc. throughout the conversation.
    ///
    /// Each tick does three things atomically against a single frame:
    ///   1. Send JPEG to Gemini (so it has fresh visual context)
    ///   2. Run YOLO+OCR detection on the same frame (populates cache)
    ///   3. Publish the CompanionScreenCapture as latestCapture
    ///
    /// This is the key to accurate pointing: when Gemini later emits
    /// box_2d coordinates in a tool call, those coords are relative to
    /// this exact frame, and the detector cache already has the label's
    /// true position in the same coordinate space.
    private func startPeriodicScreenshotUpdates() {
        screenshotUpdateTimer?.invalidate()
        screenshotUpdateTimer = Timer.scheduledTimer(withTimeInterval: Self.screenshotUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isActive else { return }
                await self.captureAndProcessFrameForGemini()
            }
        }
    }

    private func stopPeriodicScreenshotUpdates() {
        screenshotUpdateTimer?.invalidate()
        screenshotUpdateTimer = nil
    }

    func setScreenshotStreamingEnabled(_ enabled: Bool) {
        isScreenshotStreamingEnabled = enabled

        if enabled {
            print("[GeminiLiveSession] Screenshot streaming enabled")
            invalidateScreenshotHashCache()
            if isActive {
                Task { @MainActor in
                    await captureAndProcessFrameForGemini()
                }
            }
        } else {
            print("[GeminiLiveSession] Screenshot streaming disabled")
            latestCapture = nil
            lastSentScreenshotHashByScreenLabel.removeAll()
            if isActive {
                geminiClient.sendText("""
                Privacy mode is now active: screenshot streaming has been disabled. Stop using visual assumptions from previous frames. Continue from voice instructions, local accessibility labels, and tool results only.
                """)
            }
        }
    }

    /// Capture one frame and send it to Gemini for visual context.
    /// YOLO detection is NOT run here — it only runs on-demand when the
    /// AX tree lookup fails. Keeping this method lightweight is critical
    /// for audio stability: heavy periodic work starves Core Audio and
    /// causes Gemini's voice to stutter.
    ///
    /// Skips the WebSocket send when the new frame is perceptually
    /// identical to the last one we sent for the same screen — see
    /// ScreenshotPerceptualHash for the threshold rationale. We still
    /// publish `latestCapture` so local consumers (cursor coordinate
    /// mapping, YOLO cache lookups) keep seeing the freshest frame.
    ///
    /// Alongside each screenshot we also send a compact "set of marks"
    /// — a list of [role:label] tokens derived from the current app's
    /// AX tree. This gives Gemini ground-truth element labels to
    /// reference in tool calls instead of guessing from the screenshot.
    /// On apps without an AX tree (Blender/games/canvas) the walk
    /// returns nil and we just send the screenshot; Gemini falls back
    /// to its vision-only behavior for those.
    private func captureAndProcessFrameForGemini() async {
        guard isScreenshotStreamingEnabled else {
            return
        }

        guard let screenshots = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
              let primaryCapture = screenshots.first else {
            return
        }

        // Always update the local cache so cursor coordinate mapping
        // and YOLO cache stay fresh — these are local consumers, not
        // network sends.
        latestCapture = primaryCapture

        // After any successful CUA action plan, suppress screenshot
        // pushes until the
        // user speaks again. Without this, Gemini sees frames showing
        // "user hasn't acted yet" and re-emits the same tool call in
        // a tight loop. Mic stays live so the moment the user actually
        // speaks, the inputTranscript handler clears this flag and
        // screenshots resume.
        if areScreenshotsSuppressedUntilUserSpeaks {
            return
        }

        // Same idea, narrower trigger: while the on-device WorkflowRunner
        // is executing a plan, never push fresh screenshots regardless
        // of the suppression flag's state.
        if await MainActor.run(body: { WorkflowRunner.shared.activePlan != nil }) {
            return
        }

        let screenLabel = primaryCapture.label
        let newHash = ScreenshotPerceptualHash.perceptualHash(forJPEGData: primaryCapture.imageData)

        if let newHash = newHash,
           let lastHash = lastSentScreenshotHashByScreenLabel[screenLabel],
           ScreenshotPerceptualHash.isSameScene(lastHash, newHash) {
            // Scene hasn't meaningfully changed since we last sent it —
            // skip the upload. Bandwidth, JPEG decode on Gemini's side,
            // and per-image input tokens all saved.
            return
        }

        if let newHash = newHash {
            lastSentScreenshotHashByScreenLabel[screenLabel] = newHash
        }
        geminiClient.sendScreenshot(primaryCapture.imageData)

        guard hasReceivedUserSpeechThisSession else {
            return
        }

        // Marks walk runs off-main at background priority so the CoreML
        // / Audio threads always take precedence — the AX walk is
        // cheap (<200ms worst case) but we don't want it contending
        // with Gemini's real-time voice pipeline.
        let lastSentMarks = lastSentSetOfMarks
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let resolver = AccessibilityTreeResolver()
            let targetAppHint = AccessibilityTreeResolver.userTargetAppOverride?.localizedName
            guard let marks = resolver.setOfMarksForTargetApp(hint: targetAppHint), !marks.isEmpty else {
                return
            }
            let formatted = AccessibilityTreeResolver.formatMarks(marks)
            // Skip if identical to what we sent last time — keeps
            // Gemini's context lean during static screens and avoids
            // paying tokens to re-send the same mark list every 3s.
            if formatted == lastSentMarks {
                return
            }
            await MainActor.run { self.lastSentSetOfMarks = formatted }
            let preamble = "UI elements on screen (use these exact labels in tool calls):\n"
            self.geminiClient.sendText(preamble + formatted)
        }
    }

    /// The last set-of-marks string we sent to Gemini. Cached so we can
    /// skip re-sending unchanged marks — set-of-marks text is several
    /// KB and would otherwise bloat the conversation context on long
    /// sessions where the screen doesn't change much.
    private var lastSentSetOfMarks: String = ""

    /// Drop all cached perceptual hashes so the next periodic tick is
    /// guaranteed to send a fresh frame. CompanionManager calls this when
    /// a tool call fails ("can't find element") — Gemini might be working
    /// from a stale frame, so we want to force-resync its visual context.
    func invalidateScreenshotHashCache() {
        lastSentScreenshotHashByScreenLabel.removeAll()
    }

    /// Decode JPEG Data into a CGImage for detector input.
    private static func cgImage(from jpegData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    /// Send a fresh screenshot during the session — useful when the user
    /// mentions a new UI element and we want Gemini to see the current state.
    func sendScreenshot(_ jpegData: Data) {
        guard isActive, isScreenshotStreamingEnabled else { return }
        geminiClient.sendScreenshot(jpegData)
    }

    private func sendCurrentStateScreenshotForUserTurnIfNeeded() {
        guard isActive, isScreenshotStreamingEnabled else { return }
        guard !didSendStateSyncScreenshotForCurrentUserTurn else { return }

        didSendStateSyncScreenshotForCurrentUserTurn = true
        invalidateScreenshotHashCache()
        Task { @MainActor [weak self] in
            await self?.captureAndProcessFrameForGemini()
        }
    }

    // MARK: - API Key Fetch

    private func fetchAPIKey() async throws -> String {
        guard let key = KeychainStore.geminiAPIKey, !key.isEmpty else {
            throw NSError(domain: "GeminiLiveSession", code: -9, userInfo: [
                NSLocalizedDescriptionKey: "Paste your Gemini API key in Settings → Models to use realtime voice. A key saved by an older Cuse build must be pasted once more."
            ])
        }
        return key
    }

    // MARK: - Mic Capture

    private func startMicCapture() throws {
        // Rebuild the engine from scratch every session. This forces a
        // re-query of the current input device's format. If we reused a
        // cached engine after the user switched hardware (AirPods,
        // different sample rate, etc.), installTap would throw a format
        // mismatch fault and the session would be unrecoverable.
        audioEngine = AVAudioEngine()
        isAudioTapInstalled = false

        // Attach the model-audio player to this same engine BEFORE
        // enabling voice processing. AUVoiceIO is full-duplex — both
        // mic uplink and speaker downlink have to share an engine so
        // the AEC has a valid reference signal to subtract.
        audioPlayer.attach(to: audioEngine)

        let inputNode = audioEngine.inputNode

        // AUVoiceIO was tried here for hardware AEC but breaks audio
        // playback on macOS configurations with aggregate input devices
        // or virtual mics (`failed to run downlink DSP (state fault)`).
        // We rely on the session-level software echo guards instead.

        // Query the format fresh from the hardware AT THIS MOMENT.
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Sanity check: if the format is invalid (sample rate 0 or no
        // channels), the audio subsystem is in a weird state — bail out
        // rather than crash inside installTap.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "GeminiLiveSession", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "Mic input format invalid — sample rate \(inputFormat.sampleRate), channels \(inputFormat.channelCount)"])
        }
        print("[GeminiLiveSession] Mic input format: \(inputFormat)")

        installMicTap(inputNode: inputNode, inputFormat: inputFormat)

        audioEngine.prepare()
        try audioEngine.start()
        print("[GeminiLiveSession] Mic capture started")
    }

    /// Install the mic tap on the given input node.
    private func installMicTap(inputNode: AVAudioInputNode, inputFormat: AVAudioFormat) {
        // CRITICAL: this callback runs on a real-time audio thread ~40x/sec.
        // Never block it and never hop to the main actor from inside — both
        // will starve Core Audio and cause Gemini's voice to stutter.
        // All work here must be thread-safe and fast.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Skip work entirely while the model is speaking — macOS doesn't
            // do echo cancellation on AVAudioEngine by default, and sending
            // the speaker output back through the mic would trigger Gemini
            // to interrupt itself in an infinite feedback loop.
            let isSpeaking: Bool = self.modelSpeakingLock.withLock { self.modelSpeakingFlag }
            guard !isSpeaking else { return }

            // Compute on audio thread — both are thread-safe CPU work.
            let powerLevel = Self.audioPowerLevel(from: buffer)
            let pcm16Data = self.pcm16Converter.convertToPCM16Data(from: buffer)

            // Fire WebSocket send on a detached task (doesn't need main).
            if let pcm16Data {
                self.geminiClient.sendAudioChunk(pcm16Data)
            }

            // Publish power level to main with minimal overhead. We don't
            // await or block — just schedule the update and return.
            DispatchQueue.main.async { [weak self] in
                self?.currentAudioPowerLevel = powerLevel
            }
        }
        isAudioTapInstalled = true
    }

    private func stopMicCapture() {
        // Detach the player from this engine before tearing the engine
        // down. The next session re-attaches to a fresh engine in
        // startMicCapture.
        audioPlayer.detach()

        if isAudioTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isAudioTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        currentAudioPowerLevel = 0.0
        print("[GeminiLiveSession] Mic capture stopped")
    }

    /// Compute an RMS-style power level (0-1) from an audio buffer —
    /// used to drive the waveform animation.
    private static func audioPowerLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameLength))
        // Clamp to 0-1 range with some amplification so quiet speech still shows
        return CGFloat(min(1.0, rms * 5.0))
    }

    // MARK: - Gemini Event Handling

    private func handleGeminiEvent(_ event: GeminiLiveEvent) {
        switch event {
        case .setupComplete:
            // Already awaited in connect() — nothing to do here.
            break

        case .audioChunk(let pcm24kHzData):
            audioPlayer.enqueueAudioChunk(pcm24kHzData)
            isModelSpeaking = true

        case .inputTranscript(let text):
            // Gemini sends incremental transcripts — accumulate them so the
            // UI sees the full utterance as it builds up.
            inputTranscript += text
            hasReceivedUserSpeechThisSession = true
            onInputTranscriptUpdate?(inputTranscript)
            // Any user speech clears the post-tool-call screenshot
            // suppression — the user is asking something new and
            // Gemini should be able to see the screen again.
            if areScreenshotsSuppressedUntilUserSpeaks {
                areScreenshotsSuppressedUntilUserSpeaks = false
                if isScreenshotStreamingEnabled {
                    print("[GeminiLiveSession] 🔊 user spoke — screenshots resumed")
                } else {
                    print("[GeminiLiveSession] 🔊 user spoke — screenshot streaming remains disabled")
                }
            }
            sendCurrentStateScreenshotForUserTurnIfNeeded()

        case .outputTranscript:
            // Output transcript is only useful for debugging now that the
            // legacy [POINT:] tag fallback is gone — Gemini's computer
            // control intent comes through submit_workflow_plan, not
            // embedded markers in spoken text.
            // Discard the chunk; the audio player handles user-facing
            // narration directly.
            break

        case .turnComplete:
            isModelSpeaking = false
            onTurnComplete?()
            // Reset transcripts so the next turn starts fresh.
            inputTranscript = ""
            didSendStateSyncScreenshotForCurrentUserTurn = false
            toolCallsThisTurn = 0

        case .interrupted:
            // User started speaking while the model was still talking.
            // Drop queued audio without restarting the engine — the model
            // will start streaming new audio for its next response and the
            // player node is ready to accept it immediately.
            audioPlayer.clearQueuedAudio()
            isModelSpeaking = false
            onInterrupted?()

        case .toolCall(let id, let name, let args):
            handleToolCall(id: id, name: name, args: args)

        case .unexpectedDisconnect(let error):
            // Server/network closed the socket without us asking. Try to
            // reconnect rather than tearing the whole session down — the
            // user is probably mid-utterance and a brief gap is far less
            // disruptive than killing the overlay outright.
            print("[GeminiLiveSession] Unexpected disconnect — \(error.localizedDescription); attempting reconnect")
            guard isActive, !reconnectInFlight else { return }
            Task { await self.attemptReconnect(after: error) }

        case .error(let error):
            // Transparent reconnect before propagating: network blips and
            // the server's ~15min session ceiling otherwise force the user
            // to restart a live conversation. Only surface the error if
            // every retry fails or the session was already being torn
            // down deliberately (isActive == false).
            guard isActive, !reconnectInFlight else {
                onError?(error)
                stop()
                return
            }
            Task { await self.attemptReconnect(after: error) }
        }
    }

    /// Try to re-establish the WebSocket with exponential backoff. Keeps
    /// the audio player and published state intact so the user doesn't
    /// see a "session ended" flash — just a brief gap in mic streaming
    /// until the reconnect lands.
    private func attemptReconnect(after originalError: Error) async {
        reconnectInFlight = true
        defer { reconnectInFlight = false }

        // Tear down just the transport bits. Keep `isActive = true` so the
        // rest of the app treats this as a live session the whole time.
        stopPeriodicScreenshotUpdates()
        stopMicCapture()
        geminiClient.disconnect()

        while reconnectAttemptIndex < Self.maxReconnectAttempts {
            reconnectAttemptIndex += 1
            let backoffSeconds = pow(2.0, Double(reconnectAttemptIndex - 1)) * 0.5
            print("[GeminiLiveSession] 🔁 reconnect attempt \(reconnectAttemptIndex)/\(Self.maxReconnectAttempts) in \(backoffSeconds)s")
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

            // If the user explicitly stopped the session while we were
            // waiting, bail out silently.
            guard isActive else {
                print("[GeminiLiveSession] reconnect aborted — session no longer active")
                return
            }

            do {
                let apiKey = try await fetchAPIKey()
                try await geminiClient.connect(apiKey: apiKey, systemPrompt: systemPrompt)
                // Gemini's server-side context was lost — force the next
                // tick to send a fresh frame regardless of hash.
                lastSentScreenshotHashByScreenLabel.removeAll()
                await captureAndProcessFrameForGemini()
                try startMicCapture()
                audioPlayer.startPlaying()
                startPeriodicScreenshotUpdates()
                reconnectAttemptIndex = 0
                print("[GeminiLiveSession] ✅ reconnected successfully")
                return
            } catch {
                print("[GeminiLiveSession] reconnect attempt \(reconnectAttemptIndex) failed: \(error.localizedDescription)")
            }
        }

        // Exhausted all retries — now surface the original error.
        reconnectAttemptIndex = 0
        print("[GeminiLiveSession] ✗ reconnect exhausted — reporting error")
        onError?(originalError)
        stop()
    }

    // MARK: - Tool Call Dispatch

    /// Track tool calls within the current Gemini turn so we can detect
    /// and warn about duplicate calls (which would narrate twice).
    private var toolCallsThisTurn: Int = 0

    /// Gemini's turn is paused until we send a toolResponse back, so this
    /// runs the handler on a Task and replies as soon as we have a result.
    /// Handlers are resolved from CompanionManager via the onPoint/onWorkflow
    /// callbacks; if neither is set we send a benign empty response so the
    /// model can continue its turn instead of hanging.
    private func handleToolCall(id: String, name: String, args: [String: Any]) {
        toolCallsThisTurn += 1
        if toolCallsThisTurn > 1 {
            print("[GeminiLiveSession] ⚠️ Gemini called \(toolCallsThisTurn) tools in one turn — this will cause double narration. Prompt likely needs tightening.")
        }
        print("[GeminiLiveSession] ← toolCall #\(toolCallsThisTurn) \(name) id=\(id) args=\(args)")

        // Gemini often narrates a short intro ("sure, let me check...") BEFORE
        // emitting the tool call, then a proper response after the tool returns.
        // That reads as "speaking twice" to users. Drop whatever's queued the
        // moment a tool call arrives so only the post-response narration plays.
        audioPlayer.clearQueuedAudio()
        isModelSpeaking = false

        let screenshot = latestCapture?.imageData

        Task {
            var response: [String: Any] = ["ok": false, "error": "tool_unavailable"]

            switch name {
            case "point_at_element":
                let label = (args["label"] as? String) ?? ""
                let box2D = (args["box_2d"] as? [Int]).flatMap { $0.count == 4 ? $0 : nil }
                if !label.isEmpty, let handler = onPointAtElement {
                    response = await handler(id, label, box2D, screenshot)
                } else {
                    print("[GeminiLiveSession] point_at_element called with no handler or empty label")
                }

            case "submit_workflow_plan":
                let goal = (args["goal"] as? String) ?? ""
                let app = (args["app"] as? String) ?? ""
                let steps = (args["steps"] as? [[String: Any]]) ?? []
                if !goal.isEmpty, !steps.isEmpty, let handler = onSubmitWorkflowPlan {
                    response = await handler(id, goal, app, steps)
                } else {
                    print("[GeminiLiveSession] submit_workflow_plan called with no handler or empty steps")
                }

            case "create_note":
                let title = (args["title"] as? String)
                let body = (args["body"] as? String)
                    ?? (args["text"] as? String)
                    ?? (args["content"] as? String)
                    ?? ""
                if !body.isEmpty, let handler = onCreateNote {
                    response = await handler(id, title, body)
                } else {
                    print("[GeminiLiveSession] create_note called with no handler or empty body")
                }

            default:
                print("[GeminiLiveSession] unknown tool \(name) — ignoring")
                response = ["ok": false, "error": "unknown_tool"]
            }

            print("[GeminiLiveSession] → toolResponse \(name) id=\(id) response=\(response)")
            geminiClient.sendToolResponse(id: id, name: name, response: response)
        }
    }
}
