import Foundation
import SwiftUI
import WhisperKit
import SharedModels
import Logging

private let logger = AppLogger.make("ModelState")

/// Transcription engine selection
public enum TranscriptionEngine: String, CaseIterable {
    case whisperKit = "whisperKit"
    case parakeet = "parakeet"
    case qwen3ASR = "qwen3ASR"

    public var displayName: String {
        switch self {
        case .whisperKit:
            return "WhisperKit"
        case .parakeet:
            return "Parakeet"
        case .qwen3ASR:
            return "Qwen3-ASR"
        }
    }

    public var description: String {
        switch self {
        case .whisperKit:
            return "On-device transcription by Argmax"
        case .parakeet:
            return "Fast & accurate by FluidAudio"
        case .qwen3ASR:
            return "MLX-powered, 52 languages"
        }
    }
}

@MainActor
class ModelStateManager: ObservableObject {
    static let shared = ModelStateManager()

    enum ModelLoadingState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case validating
        case downloaded
        case loading
        case loaded
    }

    // MARK: - Engine Selection
    @Published var selectedEngine: TranscriptionEngine = .whisperKit {
        didSet {
            UserDefaults.standard.set(selectedEngine.rawValue, forKey: "selectedTranscriptionEngine")
        }
    }

    // MARK: - Parakeet State
    @Published var loadedParakeetTranscriber: ParakeetTranscriber? = nil
    @Published var parakeetVersion: ParakeetVersion = .v2 {
        didSet {
            UserDefaults.standard.set(parakeetVersion.rawValue, forKey: "selectedParakeetVersion")
        }
    }
    @Published var parakeetLoadingState: ParakeetLoadingState = .notDownloaded
    private var currentParakeetLoadingTask: Task<Void, Never>? = nil

    // MARK: - Qwen3-ASR State
    @Published var loadedQwen3ASRTranscriber: Qwen3ASRTranscriber? = nil
    @Published var qwen3ASRVariant: Qwen3ASRVariant = .small4bit {
        didSet {
            UserDefaults.standard.set(qwen3ASRVariant.rawValue, forKey: "selectedQwen3ASRVariant")
        }
    }
    @Published var qwen3ASRLoadingState: Qwen3ASRLoadingState = .notDownloaded
    private var currentQwen3ASRLoadingTask: Task<Void, Never>? = nil

    // MARK: - WhisperKit State
    @Published var downloadedModels: Set<String> = []
    @Published var isCheckingModels = true  // Start as true to prevent flash
    @Published var selectedModel: String? = nil {
        didSet {
            // Persist the selected model to UserDefaults
            if let model = selectedModel {
                UserDefaults.standard.set(model, forKey: "selectedWhisperModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedWhisperModel")
            }
        }
    }
    @Published var modelLoadingStates: [String: ModelLoadingState] = [:]
    @Published var loadedWhisperKit: WhisperKit? = nil
    private var currentLoadingTask: Task<WhisperKit?, Never>? = nil

    private init() {
        // Restore the selected engine from UserDefaults
        if let engineRaw = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine"),
           let engine = TranscriptionEngine(rawValue: engineRaw) {
            self.selectedEngine = engine
        }

        // Restore the selected Parakeet version from UserDefaults
        if let versionRaw = UserDefaults.standard.string(forKey: "selectedParakeetVersion"),
           let version = ParakeetVersion(rawValue: versionRaw) {
            self.parakeetVersion = version
        }

        // Restore the selected Qwen3-ASR variant from UserDefaults
        if let variantRaw = UserDefaults.standard.string(forKey: "selectedQwen3ASRVariant"),
           let variant = Qwen3ASRVariant(rawValue: variantRaw) {
            self.qwen3ASRVariant = variant
        }

        // Restore Qwen3-ASR download status from UserDefaults
        let downloadedVariants = UserDefaults.standard.stringArray(forKey: "qwen3ASRDownloadedVariants") ?? []
        if downloadedVariants.contains(self.qwen3ASRVariant.rawValue) {
            self.qwen3ASRLoadingState = .downloaded
        }

        // Restore the selected WhisperKit model from UserDefaults
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedWhisperModel")
    }
    
    func checkDownloadedModels() async {
        // Don't reset to empty - keep existing state until check completes
        var newDownloadedModels: Set<String> = []
        let modelManager = WhisperModelManager.shared
        
        // Process each model — file-based check only (no WhisperKit load)
        await withTaskGroup(of: (String, Bool).self) { group in
            for model in ModelData.availableModels {
                let whisperKitModelName = model.whisperKitModelName
                let modelPath = getModelPath(for: whisperKitModelName)
                
                group.addTask {
                    // First check if directory exists
                    if !FileManager.default.fileExists(atPath: modelPath.path) {
                        return (model.name, false)
                    }
                    
                    // Check if we have metadata marking it as complete
                    if modelManager.isModelDownloaded(whisperKitModelName) {
                        return (model.name, true)
                    }
                    
                    // No metadata — check for essential .mlmodelc files instead of full load
                    let essentialModels = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
                    let hasAllModels = essentialModels.allSatisfy { name in
                        FileManager.default.fileExists(atPath: modelPath.appendingPathComponent(name).path)
                    }
                    
                    if hasAllModels {
                        // Mark as downloaded so next check is instant
                        modelManager.markModelAsDownloaded(whisperKitModelName)
                        return (model.name, true)
                    }
                    
                    logger.info("Model \(model.name) exists but missing essential files")
                    return (model.name, false)
                }
            }
            
            // Collect results
            for await (modelName, isComplete) in group {
                if isComplete {
                    newDownloadedModels.insert(modelName)
                }
            }
        }
        
        // Update the published properties
        await MainActor.run {
            self.downloadedModels = newDownloadedModels
            
            // Update loading states for downloaded models
            for model in ModelData.availableModels {
                if newDownloadedModels.contains(model.name) {
                    // Only set to downloaded if not already loaded
                    if modelLoadingStates[model.name] != .loaded {
                        setLoadingState(for: model.name, state: .downloaded)
                    }
                } else {
                    setLoadingState(for: model.name, state: .notDownloaded)
                }
            }
            
            // If no model is selected but we have downloaded models, select the first one
            // Or if the selected model is no longer available, select the first one
            if let selected = self.selectedModel, !newDownloadedModels.contains(selected) {
                // Previously selected model is no longer available
                self.selectedModel = newDownloadedModels.first
            } else if self.selectedModel == nil && !newDownloadedModels.isEmpty {
                self.selectedModel = newDownloadedModels.first
            }
            
            self.isCheckingModels = false
        }
    }
    
    func markModelAsDownloaded(_ modelName: String) {
        downloadedModels.insert(modelName)
        setLoadingState(for: modelName, state: .downloaded)
        
        // If this is the first downloaded model and no model is selected, select it
        if selectedModel == nil {
            selectedModel = modelName
        }
        
        // Also mark in persistent storage
        if let model = ModelData.availableModels.first(where: { $0.name == modelName }) {
            WhisperModelManager.shared.markModelAsDownloaded(model.whisperKitModelName)
        }
    }
    
    func getModelPath(for whisperKitModelName: String) -> URL {
        return WhisperModelManager.shared.getModelsBasePath()
            .appendingPathComponent(whisperKitModelName)
    }
    
    func getLoadingState(for modelName: String) -> ModelLoadingState {
        // First check if this model is actually loaded in memory
        if selectedModel == modelName && loadedWhisperKit != nil {
            return .loaded
        }

        // Check for in-progress states (downloading, loading, validating)
        if let state = modelLoadingStates[modelName] {
            switch state {
            case .downloading, .loading, .validating:
                return state
            case .loaded:
                // Only return loaded if WhisperKit is actually loaded (checked above)
                return .downloaded
            case .downloaded, .notDownloaded:
                break
            }
        }

        // Determine state based on download status
        if downloadedModels.contains(modelName) {
            return .downloaded
        }

        return .notDownloaded
    }
    
    func setLoadingState(for modelName: String, state: ModelLoadingState) {
        modelLoadingStates[modelName] = state
    }
    
    /// Update state after WhisperKit loading completes (called from Task.detached)
    func setLoadedWhisperKit(_ whisperKit: WhisperKit, for modelName: String) {
        loadedWhisperKit = whisperKit
        setLoadingState(for: modelName, state: .loaded)
        for model in ModelData.availableModels where model.name != modelName {
            if modelLoadingStates[model.name] == .loaded || modelLoadingStates[model.name] == .loading {
                setLoadingState(for: model.name, state: .downloaded)
            }
        }
    }
    
    func loadModel(_ modelName: String) {
        // Cancel any existing loading task
        currentLoadingTask?.cancel()
        
        // Clear loading states for all models that were loading
        for model in ModelData.availableModels {
            if modelLoadingStates[model.name] == .loading {
                setLoadingState(for: model.name, state: .downloaded)
            }
        }
        
        guard let modelInfo = ModelData.availableModels.first(where: { $0.name == modelName }) else {
            logger.info("Model info not found for: \(modelName)")
            currentLoadingTask = nil
            return
        }

        let whisperKitModelName = modelInfo.whisperKitModelName
        let modelPath = getModelPath(for: whisperKitModelName)

        guard WhisperModelManager.shared.isModelDownloaded(whisperKitModelName) else {
            logger.info("Model \(modelName) is not downloaded")
            currentLoadingTask = nil
            return
        }
        
        setLoadingState(for: modelName, state: .loading)
        
        // Fire-and-forget: load off MainActor, update state when done.
        // MUST NOT await task.value on MainActor — CoreML dispatches to MainActor
        // internally during model compilation, which would deadlock.
        let task = Task.detached(priority: .userInitiated) { () -> WhisperKit? in
            if Task.isCancelled { return nil }
            
            do {
                logger.info("🎙️ [WhisperKit] Loading model: \(modelName) from \(modelPath.path)")
                // Use ANE for best inference performance.
                // Requires stable codesign identity for CoreML e5rt cache reuse
                // (run ./setup-codesign.sh + ./build-and-run.sh).
                let whisperKit = try await WhisperKit(
                    modelFolder: modelPath.path,
                    verbose: true,
                    logLevel: .info
                )
                
                if Task.isCancelled {
                    await ModelStateManager.shared.setLoadingState(for: modelName, state: .downloaded)
                    return nil
                }
                
                await ModelStateManager.shared.setLoadedWhisperKit(whisperKit, for: modelName)
                logger.info("[WhisperKit] Model loaded successfully")
                return whisperKit
            } catch {
                logger.error("[WhisperKit] Failed to load: \(error)")
                await ModelStateManager.shared.setLoadingState(for: modelName, state: .downloaded)
                return nil
            }
        }
        
        currentLoadingTask = task
        // Do NOT await task.value here — that would deadlock MainActor
    }

    /// Loads the model and waits for completion. Safe to call from @MainActor context.
    /// Internally awaits off MainActor to prevent CoreML deadlock.
    func loadModelAndWait(_ modelName: String) async {
        loadModel(modelName)
        guard let task = currentLoadingTask else { return }
        // Await off MainActor — CoreML dispatches to MainActor during compilation,
        // so we must yield MainActor while waiting.
        let _ = await Task.detached { await task.value }.value
    }

    // MARK: - Parakeet Model Loading

    func loadParakeetModel() async {
        // Skip if already downloading or loading
        guard parakeetLoadingState != .downloading && parakeetLoadingState != .loading else {
            logger.info("Parakeet model already downloading/loading, skipping...")
            return
        }

        // Cancel any existing loading task (shouldn't happen with guard above, but just in case)
        currentParakeetLoadingTask?.cancel()

        // Check if model is already cached - show "loading" vs "downloading"
        let modelName = parakeetVersion == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let modelPath = ParakeetTranscriber.modelsDirectory().appendingPathComponent(modelName)
        let isAlreadyDownloaded = FileManager.default.fileExists(atPath: modelPath.path)

        // Set appropriate state
        parakeetLoadingState = isAlreadyDownloaded ? .loading : .downloading
        logger.info("[Parakeet] Loading model: \(modelName) from \(modelPath.path)")

        // Load off MainActor to prevent CoreML deadlock — CoreML dispatches
        // to MainActor internally during model compilation.
        let version = parakeetVersion
        let task = Task.detached(priority: .userInitiated) { () -> Void in
            if Task.isCancelled {
                logger.info("Parakeet model loading cancelled")
                return
            }

            do {
                let transcriber = ParakeetTranscriber()
                try await transcriber.loadModel(version: version)

                if Task.isCancelled {
                    logger.info("Parakeet model loading cancelled after load")
                    await MainActor.run {
                        ModelStateManager.shared.parakeetLoadingState = .notDownloaded
                    }
                    return
                }

                await MainActor.run {
                    ModelStateManager.shared.loadedParakeetTranscriber = transcriber
                    ModelStateManager.shared.parakeetLoadingState = .loaded
                }

                logger.info("Parakeet model loaded successfully: \(version.displayName)")

            } catch {
                if Task.isCancelled {
                    logger.info("Parakeet model loading cancelled: \(error)")
                } else {
                    logger.info("Failed to load Parakeet model: \(error)")
                }

                await MainActor.run {
                    ModelStateManager.shared.parakeetLoadingState = .notDownloaded
                    ModelStateManager.shared.loadedParakeetTranscriber = nil
                }
            }
        }

        currentParakeetLoadingTask = task
        // Await off MainActor — yields MainActor so CoreML can use it freely
        let _ = await Task.detached { await task.value }.value
    }

    /// Unload Parakeet model to free memory
    func unloadParakeetModel() {
        loadedParakeetTranscriber?.unloadModel()
        loadedParakeetTranscriber = nil

        // Check if model files exist on disk before setting state
        let modelName = parakeetVersion == .v2 ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
        let modelPath = ParakeetTranscriber.modelsDirectory().appendingPathComponent(modelName)

        if FileManager.default.fileExists(atPath: modelPath.path) {
            parakeetLoadingState = .downloaded
        } else {
            parakeetLoadingState = .notDownloaded
        }
        logger.info("Parakeet model unloaded")
    }

    // MARK: - Qwen3-ASR Model Loading

    func loadQwen3ASRModel() async {
        // Skip if already downloading or loading
        guard qwen3ASRLoadingState != .downloading && qwen3ASRLoadingState != .loading else {
            logger.info("Qwen3-ASR model already downloading/loading, skipping...")
            return
        }

        // Cancel any existing loading task
        currentQwen3ASRLoadingTask?.cancel()

        // Show "Loading..." if files are cached, "Downloading..." if first time
        let downloaded = UserDefaults.standard.stringArray(forKey: "qwen3ASRDownloadedVariants") ?? []
        qwen3ASRLoadingState = downloaded.contains(qwen3ASRVariant.rawValue) ? .loading : .downloading
        logger.info("[Qwen3-ASR] Loading model: \(qwen3ASRVariant.displayName)")

        // Load off MainActor to prevent potential deadlock
        let variant = qwen3ASRVariant
        let task = Task.detached(priority: .userInitiated) { () -> Void in
            if Task.isCancelled {
                logger.info("Qwen3-ASR model loading cancelled")
                return
            }

            do {
                let transcriber = Qwen3ASRTranscriber()
                try await transcriber.loadModel(variant: variant)

                if Task.isCancelled {
                    logger.info("Qwen3-ASR model loading cancelled after load")
                    await MainActor.run {
                        ModelStateManager.shared.qwen3ASRLoadingState = .notDownloaded
                    }
                    return
                }

                await MainActor.run {
                    ModelStateManager.shared.loadedQwen3ASRTranscriber = transcriber
                    ModelStateManager.shared.qwen3ASRLoadingState = .loaded
                    // Persist download status so we know files are cached on next launch
                    var downloaded = UserDefaults.standard.stringArray(forKey: "qwen3ASRDownloadedVariants") ?? []
                    if !downloaded.contains(variant.rawValue) {
                        downloaded.append(variant.rawValue)
                        UserDefaults.standard.set(downloaded, forKey: "qwen3ASRDownloadedVariants")
                    }
                }

                logger.info("Qwen3-ASR model loaded successfully: \(variant.displayName)")

            } catch {
                if Task.isCancelled {
                    logger.info("Qwen3-ASR model loading cancelled: \(error)")
                } else {
                    logger.info("Failed to load Qwen3-ASR model: \(error)")
                }

                await MainActor.run {
                    ModelStateManager.shared.qwen3ASRLoadingState = .notDownloaded
                    ModelStateManager.shared.loadedQwen3ASRTranscriber = nil
                }
            }
        }

        currentQwen3ASRLoadingTask = task
        // Await off MainActor — yields MainActor so MLX can use it freely
        let _ = await Task.detached { await task.value }.value
    }

    /// Unload Qwen3-ASR model to free memory
    func unloadQwen3ASRModel() {
        let wasLoaded = loadedQwen3ASRTranscriber != nil
        loadedQwen3ASRTranscriber?.unloadModel()
        loadedQwen3ASRTranscriber = nil
        // Keep .downloaded state if model was previously loaded (files cached by HF Hub)
        qwen3ASRLoadingState = wasLoaded ? .downloaded : qwen3ASRLoadingState
        logger.info("Qwen3-ASR model unloaded")
    }

    /// Unload WhisperKit model to free memory
    func unloadWhisperKitModel() {
        loadedWhisperKit = nil
        // Reset loading states to downloaded for all downloaded models
        for model in ModelData.availableModels where downloadedModels.contains(model.name) {
            setLoadingState(for: model.name, state: .downloaded)
        }
        logger.info("WhisperKit model unloaded")
    }
}