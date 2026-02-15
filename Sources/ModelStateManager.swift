import Foundation
import SwiftUI
import WhisperKit
import SharedModels

/// Transcription engine selection
public enum TranscriptionEngine: String, CaseIterable {
    case whisperKit = "whisperKit"
    case parakeet = "parakeet"

    public var displayName: String {
        switch self {
        case .whisperKit:
            return "WhisperKit"
        case .parakeet:
            return "Parakeet"
        }
    }

    public var description: String {
        switch self {
        case .whisperKit:
            return "On-device transcription by Argmax"
        case .parakeet:
            return "Fast & accurate by FluidAudio"
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

        // Restore the selected WhisperKit model from UserDefaults
        self.selectedModel = UserDefaults.standard.string(forKey: "selectedWhisperModel")
    }
    
    func checkDownloadedModels() async {
        // Don't reset to empty - keep existing state until check completes
        var newDownloadedModels: Set<String> = []
        let modelManager = WhisperModelManager.shared
        
        // Process each model in parallel for faster checking
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
                        // Trust our metadata if it says complete
                        return (model.name, true)
                    }
                    
                    // Try to load the model with WhisperKit to validate it's complete
                    do {
                        let _ = try await WhisperKit(
                            modelFolder: modelPath.path,
                            verbose: false,
                            logLevel: .error,
                            load: true
                        )
                        
                        // If loading succeeded, mark it in our manager
                        modelManager.markModelAsDownloaded(whisperKitModelName)
                        return (model.name, true)
                    } catch {
                        // Model exists but is incomplete or corrupted
                        print("Model \(model.name) exists but is incomplete")
                        return (model.name, false)
                    }
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
    
    /// WhisperKit 로딩 완료 후 상태 업데이트 (Task.detached에서 호출용)
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
            print("Model info not found for: \(modelName)")
            currentLoadingTask = nil
            return
        }

        let whisperKitModelName = modelInfo.whisperKitModelName
        let modelPath = getModelPath(for: whisperKitModelName)

        guard WhisperModelManager.shared.isModelDownloaded(whisperKitModelName) else {
            print("Model \(modelName) is not downloaded")
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
                print("🎙️ [WhisperKit] Loading model: \(modelName) from \(modelPath.path)")
                let whisperKit = try await WhisperKit(
                    modelFolder: modelPath.path,
                    verbose: false,
                    logLevel: .error
                )
                
                if Task.isCancelled {
                    await ModelStateManager.shared.setLoadingState(for: modelName, state: .downloaded)
                    return nil
                }
                
                await ModelStateManager.shared.setLoadedWhisperKit(whisperKit, for: modelName)
                print("✅ [WhisperKit] Model loaded successfully")
                return whisperKit
            } catch {
                print("❌ [WhisperKit] Failed to load: \(error)")
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
            print("Parakeet model already downloading/loading, skipping...")
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
        print("🦜 [Parakeet] Loading model: \(modelName) from \(modelPath.path)")

        // Load off MainActor to prevent CoreML deadlock — CoreML dispatches
        // to MainActor internally during model compilation.
        let version = parakeetVersion
        let task = Task.detached(priority: .userInitiated) { () -> Void in
            if Task.isCancelled {
                print("Parakeet model loading cancelled")
                return
            }

            do {
                let transcriber = ParakeetTranscriber()
                try await transcriber.loadModel(version: version)

                if Task.isCancelled {
                    print("Parakeet model loading cancelled after load")
                    await MainActor.run {
                        ModelStateManager.shared.parakeetLoadingState = .notDownloaded
                    }
                    return
                }

                await MainActor.run {
                    ModelStateManager.shared.loadedParakeetTranscriber = transcriber
                    ModelStateManager.shared.parakeetLoadingState = .loaded
                }

                print("Parakeet model loaded successfully: \(version.displayName)")

            } catch {
                if Task.isCancelled {
                    print("Parakeet model loading cancelled: \(error)")
                } else {
                    print("Failed to load Parakeet model: \(error)")
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
        print("Parakeet model unloaded")
    }

    /// Unload WhisperKit model to free memory
    func unloadWhisperKitModel() {
        loadedWhisperKit = nil
        // Reset loading states to downloaded for all downloaded models
        for model in ModelData.availableModels where downloadedModels.contains(model.name) {
            setLoadingState(for: model.name, state: .downloaded)
        }
        print("WhisperKit model unloaded")
    }
}