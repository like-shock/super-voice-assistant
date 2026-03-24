import Foundation
import Qwen3ASR
import Logging

private let logger = AppLogger.make("Qwen3ASR")

/// Available Qwen3-ASR model variants
/// Named "Variant" to avoid conflict with Qwen3ASRModel from the library
public enum Qwen3ASRVariant: String, CaseIterable {
    case small4bit = "qwen3-asr-0.6b-4bit"
    case small8bit = "qwen3-asr-0.6b-8bit"

    public var displayName: String {
        switch self {
        case .small4bit: return "Qwen3-ASR 0.6B (4-bit)"
        case .small8bit: return "Qwen3-ASR 0.6B (8-bit)"
        }
    }

    public var description: String {
        switch self {
        case .small4bit: return "Fast, compact, 52 languages"
        case .small8bit: return "Better accuracy, 52 languages"
        }
    }

    public var size: String {
        switch self {
        case .small4bit: return "~680MB"
        case .small8bit: return "~1.1GB"
        }
    }

    public var speed: String {
        switch self {
        case .small4bit: return "Fastest"
        case .small8bit: return "Fast"
        }
    }

    public var languages: String {
        return "52 languages"
    }

    public var huggingFaceId: String {
        switch self {
        case .small4bit: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .small8bit: return "aufklarer/Qwen3-ASR-0.6B-MLX-8bit"
        }
    }
}

/// Loading state for Qwen3-ASR models
public enum Qwen3ASRLoadingState: Equatable {
    case notDownloaded
    case downloading
    case downloaded
    case loading
    case loaded
}

/// Wrapper around qwen3-asr-swift for integration with Super Voice Assistant
public class Qwen3ASRTranscriber {
    /// The loaded Qwen3ASRModel from the library
    private var model: Qwen3ASRModel?
    private(set) public var loadedVariant: Qwen3ASRVariant?
    private(set) public var loadingState: Qwen3ASRLoadingState = .notDownloaded

    public init() {}

    public var isReady: Bool {
        return model != nil && loadingState == .loaded
    }

    /// Model storage directory
    public static func modelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SuperVoiceAssistant/models/qwen3-asr")
    }

    /// Load a Qwen3-ASR model variant
    public func loadModel(variant: Qwen3ASRVariant) async throws {
        loadingState = .downloading
        logger.info("Loading Qwen3-ASR model: \(variant.displayName)")

        do {
            let loaded = try await Qwen3ASRModel.fromPretrained(
                modelId: variant.huggingFaceId,
                progressHandler: { progress, status in
                    logger.info("Qwen3-ASR download: \(Int(progress * 100))% - \(status)")
                }
            )

            self.model = loaded
            self.loadedVariant = variant
            self.loadingState = .loaded
            logger.info("Qwen3-ASR model loaded: \(variant.displayName)")
        } catch {
            self.loadingState = .notDownloaded
            logger.error("Failed to load Qwen3-ASR: \(error)")
            throw error
        }
    }

    /// Transcribe audio samples (16kHz Float32 mono)
    /// Note: Qwen3ASRModel.transcribe() is synchronous, so we wrap in Task for async context
    public func transcribe(audioSamples: [Float], language: String? = nil) throws -> String {
        guard let model = model else {
            throw Qwen3ASRError.modelNotLoaded
        }

        let result = model.transcribe(
            audio: audioSamples,
            sampleRate: 16000,
            language: language
        )

        return result
    }

    /// Unload model to free memory
    public func unloadModel() {
        model = nil
        loadedVariant = nil
        loadingState = .notDownloaded
        logger.info("Qwen3-ASR model unloaded")
    }
}

public enum Qwen3ASRError: Error, LocalizedError {
    case modelNotLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Qwen3-ASR model is not loaded"
        }
    }
}
