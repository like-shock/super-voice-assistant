import Foundation
import AVFoundation
import Logging

private let logger = AppLogger.make("GeminiPlayer")

@available(macOS 14.0, *)
public class GeminiStreamingPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchEffect = AVAudioUnitTimePitch()
    private let audioFormat: AVAudioFormat
    
    /// 현재 오디오 포맷의 샘플레이트
    public var currentSampleRate: Double { audioFormat.sampleRate }
    
    public init(sampleRate: Double = 24000, playbackSpeed: Float = 1.2) {
        self.audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Setup audio processing chain (same as GeminiTTS)
        timePitchEffect.rate = playbackSpeed
        timePitchEffect.pitch = 0 // Keep pitch unchanged

        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchEffect)
        audioEngine.connect(playerNode, to: timePitchEffect, format: audioFormat)
        audioEngine.connect(timePitchEffect, to: audioEngine.mainMixerNode, format: audioFormat)

        // Don't configure on init to avoid crashes, will configure when starting engine
    }

    deinit {
        stopAudioEngine()
    }

    /// Reset player state to free scheduled buffers
    public func reset() {
        playerNode.stop()
        playerNode.reset()
    }
    
    private func configureOutputDevice() {
        let deviceManager = AudioDeviceManager.shared
        
        guard !deviceManager.useSystemDefaultOutput,
              let device = deviceManager.getCurrentOutputDevice(),
              let deviceID = deviceManager.getAudioDeviceID(for: device.uid) else {
            return
        }
        
        do {
            try audioEngine.outputNode.auAudioUnit.setDeviceID(deviceID)
            logger.info("Set output device to: \(device.name)")
        } catch {
            logger.error("Failed to set output device: \(error)")
        }
    }
    
    private func startAudioEngine() throws {
        // Reconfigure output device in case settings changed
        configureOutputDevice()
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }
    
    public func stopAudioEngine() {
        logger.info("Stopping audio engine and player")
        playerNode.stop()
        playerNode.reset()  // Clear any scheduled buffers to free memory
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
    
    public func playAudioStream(_ audioStream: AsyncThrowingStream<Data, Error>) async throws {
        try startAudioEngine()
        
        var isFirstChunk = true
        var totalBytesPlayed = 0
        
        do {
            for try await audioChunk in audioStream {
                // Check for cancellation
                try Task.checkCancellation()
                
                logger.info("Playing chunk: \(audioChunk.count) bytes")
                
                // Convert raw PCM data to AVAudioPCMBuffer
                let buffer = try createPCMBuffer(from: audioChunk)
                
                if isFirstChunk {
                    logger.info("Starting playback with first chunk")
                    playerNode.play()
                    isFirstChunk = false
                }
                
                // Schedule buffer for immediate playback
                await playerNode.scheduleBuffer(buffer)
                totalBytesPlayed += audioChunk.count
                
                logger.info("Total audio scheduled: \(totalBytesPlayed) bytes")
                
                // Small delay to prevent overwhelming the audio system
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            
            logger.info("All audio chunks scheduled for playback")

            // Wait for playback to complete
            let totalDurationSeconds = Double(totalBytesPlayed) / Double(audioFormat.sampleRate * 2) // 16-bit = 2 bytes per sample
            logger.info("Waiting \(String(format: "%.1f", totalDurationSeconds))s for playback completion")
            try await Task.sleep(nanoseconds: UInt64(totalDurationSeconds * 1_000_000_000))

            // Clean up after playback
            reset()

        } catch {
            reset()  // Clean up on error too
            throw GeminiStreamingPlayerError.playbackError(error)
        }
    }
    
    /// TTSAudioProvider 기반 재생 (Gemini, Supertonic 등 모든 엔진 공용)
    public func playText(_ text: String, provider: TTSAudioProvider) async throws {
        // 샘플레이트가 다르면 리샘플링이 필요하지만,
        // 현재는 엔진 초기화 시 올바른 샘플레이트로 생성한다고 가정
        let audioStream = provider.collectAudioChunks(from: text)
        try await playAudioStream(audioStream)
    }
    
    public func playText(_ text: String, audioCollector: GeminiAudioCollector, maxRetries: Int = 3) async throws {
        try startAudioEngine()

        // Split text into sentences and rejoin with line breaks for natural pauses
        let sentences = SmartSentenceSplitter.splitIntoSentences(text)
        logger.info("Split text into \(sentences.count) sentences")

        // Join sentences with triple line breaks to encourage model to add longer pauses
        let formattedText = sentences.joined(separator: "\n\n\n")
        logger.info("Formatted text with line breaks between sentences")

        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try await playTextAttempt(formattedText, audioCollector: audioCollector)
                return // Success
            } catch {
                lastError = error

                // Check if it's a network error worth retrying
                let nsError = error as NSError
                let isNetworkError = nsError.domain == NSURLErrorDomain ||
                    (error as? GeminiAudioCollectorError) != nil

                if isNetworkError && attempt < maxRetries {
                    logger.warning("TTS attempt \(attempt) failed, retrying in 1s... Error: \(error.localizedDescription)")
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                    reset() // Reset player state before retry
                } else {
                    throw error
                }
            }
        }

        // Should not reach here, but just in case
        if let error = lastError {
            throw error
        }
    }

    private func playTextAttempt(_ formattedText: String, audioCollector: GeminiAudioCollector) async throws {
        var isFirstChunk = true
        var totalBytesPlayed = 0

        // Start collection for the formatted text (all at once)
        let audioStream = audioCollector.collectAudioChunks(from: formattedText) { result in
            switch result {
            case .success:
                logger.info("Audio collection complete")
            case .failure(let error):
                logger.error("Audio collection failed: \(error)")
            }
        }

        // Stream and play audio chunks as they arrive
        for try await chunk in audioStream {
            try Task.checkCancellation()

            let buffer = try createPCMBuffer(from: chunk)

            if isFirstChunk {
                logger.info("Starting playback")
                playerNode.play()
                isFirstChunk = false
            }

            await playerNode.scheduleBuffer(buffer)
            totalBytesPlayed += chunk.count

            // Small pacing to avoid overwhelming scheduling
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms between chunks
        }

        logger.info("Playback complete: \(totalBytesPlayed) bytes")
        logger.info("Full text streaming completed")

        // Clean up after playback
        reset()
    }
    
    private func createPCMBuffer(from audioData: Data) throws -> AVAudioPCMBuffer {
        let frameCount = audioData.count / 2 // 16-bit samples = 2 bytes per frame
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: UInt32(frameCount)) else {
            throw GeminiStreamingPlayerError.bufferCreationFailed
        }
        
        buffer.frameLength = UInt32(frameCount)
        
        // Copy audio data into buffer
        audioData.withUnsafeBytes { bytes in
            let int16Pointer = bytes.bindMemory(to: Int16.self)
            let floatPointer = buffer.floatChannelData![0]
            
            // Convert Int16 samples to Float samples (normalized to -1.0 to 1.0)
            for i in 0..<frameCount {
                floatPointer[i] = Float(int16Pointer[i]) / Float(Int16.max)
            }
        }
        
        return buffer
    }
}

public enum GeminiStreamingPlayerError: Error, LocalizedError {
    case bufferCreationFailed
    case playbackError(Error)
    
    public var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .playbackError(let error):
            return "Playback error: \(error.localizedDescription)"
        }
    }
}
