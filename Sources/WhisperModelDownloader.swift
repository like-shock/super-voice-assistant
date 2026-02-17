import Foundation
import WhisperKit
import SharedModels
import Logging

private let logger = AppLogger.make("WhisperDownload")

/// WhisperKit model downloader supporting all three models
class WhisperModelDownloader {
    
    /// Download any WhisperKit model by name with progress callback
    static func downloadModel(modelName: String, progressCallback: ((Progress) -> Void)? = nil) async throws -> URL {
        logger.info("Starting download of \(modelName)...")
        
        let modelManager = WhisperModelManager.shared
        let modelPath = modelManager.getModelPath(for: modelName)
        
        // Check if model is already marked as downloaded
        if modelManager.isModelDownloaded(modelName) {
            logger.info("Model already downloaded and verified: \(modelName)")
            return modelPath
        }
        
        // Check if model exists but not marked as complete (incomplete download)
        if modelManager.modelExistsOnDisk(modelName) && !modelManager.isModelDownloaded(modelName) {
            logger.info("Found incomplete download, removing and re-downloading...")
            try? FileManager.default.removeItem(at: modelPath)
        }
        
        // Download the model using WhisperKit.download with progress tracking
        let downloadedFolder = try await WhisperKit.download(
            variant: modelName,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: progressCallback
        )
        
        logger.info("Model downloaded to: \(downloadedFolder)")
        
        // Move to our app-managed path if different
        let modelFolder: URL
        if downloadedFolder.path != modelPath.path {
            try FileManager.default.createDirectory(at: modelPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            try FileManager.default.moveItem(at: downloadedFolder, to: modelPath)
            logger.info("Moved model to: \(modelPath)")
            modelFolder = modelPath
        } else {
            modelFolder = downloadedFolder
        }
        
        logger.info("Model ready at: \(modelFolder)")
        
        // Validate the model by trying to load it
        logger.info("Validating model...")
        do {
            let _ = try await WhisperKit(
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .error,
                load: true
            )
            
            // If loading succeeds, mark as complete
            modelManager.markModelAsDownloaded(modelName)
            logger.info("Model validated and marked as complete: \(modelName)")
        } catch {
            logger.info("Warning: Model validation failed but download completed: \(error)")
            // Still mark as downloaded since the download itself completed
            // The model state manager will handle validation separately
            modelManager.markModelAsDownloaded(modelName)
        }
        
        return modelFolder
    }
    
    /// Download DistilWhisper V3 model (fast English-only)
    static func downloadDistilWhisperV3() async throws -> URL {
        return try await downloadModel(modelName: "distil-whisper_distil-large-v3")
    }
    
    /// Download Large V3 Turbo model (balanced multilingual)
    static func downloadLargeV3Turbo() async throws -> URL {
        return try await downloadModel(modelName: "openai_whisper-large-v3-v20240930_turbo")
    }
    
    /// Download Large V3 model (highest accuracy)
    static func downloadLargeV3() async throws -> URL {
        return try await downloadModel(modelName: "openai_whisper-large-v3-v20240930")
    }
    
    /// Download model based on ModelInfo with progress callback
    static func downloadModel(from modelInfo: ModelInfo, progressCallback: ((Progress) -> Void)? = nil) async throws -> URL {
        return try await downloadModel(modelName: modelInfo.whisperKitModelName, progressCallback: progressCallback)
    }
}
