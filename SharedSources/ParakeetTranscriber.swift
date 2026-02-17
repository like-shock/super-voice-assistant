import Foundation
import FluidAudio
import Logging

private let logger = AppLogger.make("Parakeet")

/// Available Parakeet model versions
public enum ParakeetVersion: String, CaseIterable {
    case v2 = "parakeet-v2"
    case v3 = "parakeet-v3"

    public var displayName: String {
        switch self {
        case .v2:
            return "Parakeet v2"
        case .v3:
            return "Parakeet v3"
        }
    }

    public var description: String {
        switch self {
        case .v2:
            return "Fast and accurate, English-optimized"
        case .v3:
            return "Latest version, 25 European languages"
        }
    }

    public var size: String {
        switch self {
        case .v2:
            return "~600MB"
        case .v3:
            return "~600MB"
        }
    }

    public var speed: String {
        switch self {
        case .v2:
            return "~110x RTF"
        case .v3:
            return "~210x RTF"
        }
    }

    public var accuracy: String {
        switch self {
        case .v2:
            return "1.69% WER"
        case .v3:
            return "1.93% WER"
        }
    }

    /// Accuracy as percentage (100 - WER) for display in AccuracyBar
    public var accuracyPercent: String {
        switch self {
        case .v2:
            return "98.31%"  // 100 - 1.69
        case .v3:
            return "98.07%"  // 100 - 1.93
        }
    }

    public var languages: String {
        switch self {
        case .v2:
            return "English"
        case .v3:
            return "25 languages"
        }
    }

    /// Convert to FluidAudio's AsrModelVersion
    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2:
            return .v2
        case .v3:
            return .v3
        }
    }
}

/// Loading state for Parakeet models
public enum ParakeetLoadingState: Equatable {
    case notDownloaded
    case downloading
    case downloaded
    case loading
    case loaded
}

/// Wrapper for FluidAudio Parakeet transcription
public class ParakeetTranscriber {

    /// Default FluidAudio model path (~/Library/Application Support/FluidAudio/Models/)
    /// FluidAudio SDK uses this path internally and stores downloaded models here
    public static func modelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FluidAudio")
            .appendingPathComponent("Models")
    }

    public enum TranscriptionError: Error, LocalizedError {
        case modelNotLoaded
        case transcriptionFailed(String)
        case loadingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Parakeet model not loaded"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .loadingFailed(let message):
                return "Model loading failed: \(message)"
            }
        }
    }

    private var asrManager: AsrManager?
    private(set) public var loadedVersion: ParakeetVersion?
    private(set) public var loadingState: ParakeetLoadingState = .notDownloaded

    public init() {}

    /// Load a Parakeet model
    /// - Parameter version: The version of the model to load
    public func loadModel(version: ParakeetVersion) async throws {
        loadingState = .downloading
        logger.info("Loading Parakeet model: \(version.displayName)")

        do {
            // Create an AsrManager instance
            let manager = AsrManager()

            loadingState = .loading

            // Load the models - FluidAudio will download them automatically if needed
            // Uses FluidAudio's default: ~/Library/Application Support/FluidAudio/Models/
            let modelsDirectory = ParakeetTranscriber.modelsDirectory()

            // Ensure the directory exists
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

            // Load ASR models (will download if not present)
            let asrModels = try await AsrModels.load(
                from: modelsDirectory,
                version: version.asrModelVersion
            )

            // Initialize the manager with loaded models
            try await manager.initialize(models: asrModels)

            asrManager = manager
            loadedVersion = version
            loadingState = .loaded
            logger.info("Parakeet model loaded successfully: \(version.displayName)")

        } catch {
            loadingState = .notDownloaded
            loadedVersion = nil
            logger.info("Failed to load Parakeet model: \(error)")
            throw TranscriptionError.loadingFailed(error.localizedDescription)
        }
    }

    /// Transcribe audio samples
    /// - Parameter audioSamples: Float array of audio samples at 16kHz mono
    /// - Returns: Transcribed text
    public func transcribe(audioSamples: [Float]) async throws -> String {
        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        do {
            logger.info("Transcribing \(audioSamples.count) samples with Parakeet...")
            let result = try await manager.transcribe(audioSamples)
            let text = result.text
            logger.info("Parakeet transcription complete: \(text)")
            return text
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Check if a model is loaded and ready
    public var isReady: Bool {
        return asrManager?.isAvailable ?? false && loadingState == .loaded
    }

    /// Unload the current model to free memory
    public func unloadModel() {
        asrManager = nil
        loadedVersion = nil
        loadingState = .notDownloaded
        logger.info("Parakeet model unloaded")
    }
}
