//
//  PCM16AudioConverter.swift
//  Cuse
//
//  Converts AVAudioPCMBuffers (whatever the mic produces) into PCM16 mono
//  Data at a target sample rate. Used by GeminiLiveSession to feed the
//  Gemini Live WebSocket, which expects 16kHz mono PCM16.
//

import AVFoundation
import Foundation

final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat
    private var monoFloatInputFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var currentMonoInputSampleRate: Double?
    private var conversionFailureCount = 0

    init(targetSampleRate: Double) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        guard let monoFloatBuffer = makeMonoFloatBuffer(from: audioBuffer) else {
            logConversionFailure("could not downmix \(audioBuffer.format)")
            return nil
        }

        let inputSampleRate = monoFloatBuffer.format.sampleRate
        if currentMonoInputSampleRate != inputSampleRate {
            audioConverter = AVAudioConverter(from: monoFloatBuffer.format, to: targetAudioFormat)
            currentMonoInputSampleRate = inputSampleRate
        }

        guard let audioConverter else {
            logConversionFailure("could not create converter from \(monoFloatBuffer.format) to \(targetAudioFormat)")
            return nil
        }

        let sampleRateRatio = targetAudioFormat.sampleRate / monoFloatBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(monoFloatBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            logConversionFailure("could not allocate output buffer")
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return monoFloatBuffer
        }

        guard conversionStatus != .error else {
            logConversionFailure(conversionError?.localizedDescription ?? "converter returned error")
            return nil
        }
        guard let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            logConversionFailure("missing output data")
            return nil
        }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else {
            logConversionFailure("empty output buffer")
            return nil
        }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }

    private func makeMonoFloatBuffer(from audioBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard audioBuffer.frameLength > 0 else { return nil }

        let inputSampleRate = audioBuffer.format.sampleRate
        guard inputSampleRate > 0 else { return nil }

        if monoFloatInputFormat?.sampleRate != inputSampleRate {
            monoFloatInputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputSampleRate,
                channels: 1,
                interleaved: false
            )
        }
        guard let monoFloatInputFormat,
              let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFloatInputFormat,
                frameCapacity: audioBuffer.frameLength
              ),
              let monoChannel = monoBuffer.floatChannelData?[0] else {
            return nil
        }

        monoBuffer.frameLength = audioBuffer.frameLength
        let frameCount = Int(audioBuffer.frameLength)
        let channelCount = Int(audioBuffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        if let floatChannels = audioBuffer.floatChannelData {
            for frameIndex in 0..<frameCount {
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += floatChannels[channelIndex][frameIndex]
                }
                monoChannel[frameIndex] = sum / Float(channelCount)
            }
            return monoBuffer
        }

        if let int16Channels = audioBuffer.int16ChannelData {
            for frameIndex in 0..<frameCount {
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += Float(int16Channels[channelIndex][frameIndex]) / Float(Int16.max)
                }
                monoChannel[frameIndex] = sum / Float(channelCount)
            }
            return monoBuffer
        }

        return nil
    }

    private func logConversionFailure(_ reason: String) {
        conversionFailureCount += 1
        if conversionFailureCount <= 3 || conversionFailureCount % 100 == 0 {
            print("[GeminiLiveAudio] mic PCM conversion failed #\(conversionFailureCount): \(reason)")
        }
    }
}
