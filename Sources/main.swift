import Cocoa
import SwiftUI
import KeyboardShortcuts
import AVFoundation
import WhisperKit
import SharedModels
import Combine
import ApplicationServices
import Foundation
import Logging
import UserNotifications
private var logger = AppLogger.make("App")

// Environment variable loading
func loadEnvironmentVariables() {
    let fileManager = FileManager.default
    
    // Search .env in bundle Resources first, then cwd
    let candidatePaths = [
        Bundle.main.resourcePath.map { "\($0)/.env" },
        Optional("\(fileManager.currentDirectoryPath)/.env")
    ].compactMap { $0 }
    
    guard let envPath = candidatePaths.first(where: { fileManager.fileExists(atPath: $0) }),
          let envContent = try? String(contentsOfFile: envPath) else {
        return
    }
    
    for line in envContent.components(separatedBy: .newlines) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty && !trimmedLine.hasPrefix("#") else { continue }
        
        let parts = trimmedLine.components(separatedBy: "=")
        guard parts.count == 2 else { continue }
        
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        setenv(key, value, 1)
    }
}

// MARK: - Notification Helper

func sendNotification(title: String, subtitle: String? = nil, body: String, sound: Bool = false) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    
    let content = UNMutableNotificationContent()
    content.title = title
    if let subtitle = subtitle { content.subtitle = subtitle }
    content.body = body
    if sound { content.sound = .default }
    
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(request)
}

extension KeyboardShortcuts.Name {
    static let startRecording = Self("startRecording")
    static let showHistory = Self("showHistory")
    static let readSelectedText = Self("readSelectedText")
    static let toggleScreenRecording = Self("toggleScreenRecording")
    static let geminiAudioRecording = Self("geminiAudioRecording")
    static let pasteLastTranscription = Self("pasteLastTranscription")
}

class AppDelegate: NSObject, NSApplicationDelegate, AudioTranscriptionManagerDelegate, GeminiAudioRecordingManagerDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: SettingsWindowController?
    private var unifiedWindow: UnifiedManagerWindow?

    private var displayTimer: Timer?
    private var modelCancellable: AnyCancellable?
    private var engineCancellable: AnyCancellable?
    private var parakeetVersionCancellable: AnyCancellable?
    private var transcriptionTimer: Timer?
    private var videoProcessingTimer: Timer?
    private var audioManager: AudioTranscriptionManager!
    private var geminiAudioManager: GeminiAudioRecordingManager!
    var streamingPlayer: GeminiStreamingPlayer?
    private var audioCollector: GeminiAudioCollector?
    var supertonicEngine: SupertonicEngine?
    var edgeTTSEngine: EdgeTTSEngine?
    var currentTTSEngine: TTSEngine = .gemini
    private var isCurrentlyPlaying = false
    var currentStreamingTask: Task<Void, Never>?
    private var screenRecorder = ScreenRecorder()
    private var currentVideoURL: URL?
    private var videoTranscriber = VideoTranscriber()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load environment variables (LOG_LEVEL etc. from .env file)
        loadEnvironmentVariables()
        
        // Reapply log level after .env loading
        logger.logLevel = AppLogger.resolveLogLevel()
        
        // Migrate WhisperKit models from legacy ~/Documents path
        WhisperModelManager.shared.migrateIfNeeded()
        
        // Initialize TTS engine
        let savedEngine = UserDefaults.standard.string(forKey: "ttsEngine")
            .flatMap { TTSEngine(rawValue: $0) } ?? .gemini
        currentTTSEngine = savedEngine
        
        if #available(macOS 14.0, *) {
            switch currentTTSEngine {
            case .gemini:
                if let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty {
                    streamingPlayer = GeminiStreamingPlayer(sampleRate: 24000, playbackSpeed: 1.15)
                    audioCollector = GeminiAudioCollector(apiKey: apiKey)
                    logger.info("Gemini TTS initialized")
                } else {
                    logger.warning("GEMINI_API_KEY not found, falling back to Supertonic")
                    currentTTSEngine = .supertonic
                    initSupertonic()
                }
            case .supertonic:
                initSupertonic()
            case .edge:
                initEdgeTTS()
            }
        } else {
            logger.warning("Streaming TTS requires macOS 14.0 or later")
        }
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Set the waveform icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
        }
        
        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Recording: Press Command+Option+Z", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Gemini Audio Recording: Press Command+Option+X", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "History: Press Command+Option+A", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Read Selected Text: Press Command+Option+S", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Screen Recording: Press Command+Option+C", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste Last Transcription: Press Command+Option+V", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "View History...", action: #selector(showTranscriptionHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Statistics...", action: #selector(showStats), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Set default keyboard shortcuts
        KeyboardShortcuts.setShortcut(.init(.z, modifiers: [.command, .option]), for: .startRecording)
        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .option]), for: .geminiAudioRecording)
        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .option]), for: .showHistory)
        KeyboardShortcuts.setShortcut(.init(.s, modifiers: [.command, .option]), for: .readSelectedText)
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.command, .option]), for: .toggleScreenRecording)
        KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .option]), for: .pasteLastTranscription)
        
        // Set up keyboard shortcut handlers
        KeyboardShortcuts.onKeyUp(for: .startRecording) { [weak self] in
            guard let self = self else { return }

            // Prevent starting audio recording if screen recording is active
            if self.screenRecorder.recording {
                sendNotification(title: "Cannot Start Audio Recording", body: "Screen recording is currently active. Stop it first with Cmd+Option+C")
                logger.warning("Blocked audio recording - screen recording is active")
                return
            }

            // Prevent starting audio recording if Gemini audio recording is active
            if self.geminiAudioManager.isRecording {
                sendNotification(title: "Cannot Start Audio Recording", body: "Gemini audio recording is currently active. Stop it first with Cmd+Option+X")
                logger.warning("Blocked audio recording - Gemini audio recording is active")
                return
            }

            // If about to start a fresh recording, make sure any previous
            // processing indicator is stopped and UI is reset.
            if !self.audioManager.isRecording {
                self.stopTranscriptionIndicator()
            }
            self.audioManager.toggleRecording()
        }
        
        KeyboardShortcuts.onKeyUp(for: .showHistory) { [weak self] in
            self?.showTranscriptionHistory()
        }
        
        KeyboardShortcuts.onKeyUp(for: .readSelectedText) { [weak self] in
            self?.handleReadSelectedTextToggle()
        }

        KeyboardShortcuts.onKeyUp(for: .geminiAudioRecording) { [weak self] in
            guard let self = self else { return }

            // Prevent starting Gemini audio recording if screen recording is active
            if self.screenRecorder.recording {
                sendNotification(title: "Cannot Start Gemini Audio Recording", body: "Screen recording is currently active. Stop it first with Cmd+Option+C")
                logger.warning("Blocked Gemini audio recording - screen recording is active")
                return
            }

            // Prevent starting Gemini audio recording if WhisperKit recording is active
            if self.audioManager.isRecording {
                sendNotification(title: "Cannot Start Gemini Audio Recording", body: "WhisperKit recording is currently active. Stop it first with Cmd+Option+Z")
                logger.warning("Blocked Gemini audio recording - WhisperKit recording is active")
                return
            }

            // If about to start a fresh recording, make sure any previous
            // processing indicator is stopped and UI is reset.
            if !self.geminiAudioManager.isRecording {
                self.stopTranscriptionIndicator()
            }
            self.geminiAudioManager.toggleRecording()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleScreenRecording) { [weak self] in
            self?.toggleScreenRecording()
        }

        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscription) { [weak self] in
            self?.pasteLastTranscription()
        }

        // Set up audio manager
        audioManager = AudioTranscriptionManager()
        audioManager.delegate = self

        // Set up Gemini audio manager
        geminiAudioManager = GeminiAudioRecordingManager()
        geminiAudioManager.delegate = self
        
        // Check downloaded models at startup (off MainActor to prevent CoreML deadlock)
        Task.detached(priority: .userInitiated) {
            await ModelStateManager.shared.checkDownloadedModels()
            logger.info("Model check completed at startup")

            // Load the initially selected model based on engine
            let engine = await ModelStateManager.shared.selectedEngine
            switch engine {
            case .whisperKit:
                if let selectedModel = await ModelStateManager.shared.selectedModel {
                    await ModelStateManager.shared.loadModel(selectedModel)
                }
            case .parakeet:
                await ModelStateManager.shared.loadParakeetModel()
            }
        }

        // Observe WhisperKit model selection changes
        modelCancellable = ModelStateManager.shared.$selectedModel
            .dropFirst() // Skip the initial value
            .sink { selectedModel in
                guard let selectedModel = selectedModel else { return }
                // Only load if WhisperKit is the selected engine
                guard ModelStateManager.shared.selectedEngine == .whisperKit else { return }
                // Load the new model (fire-and-forget, state updates via @Published)
                ModelStateManager.shared.loadModel(selectedModel)
            }

        // Observe engine changes - only handle memory management, not loading
        // Loading is triggered by user actions (selecting/downloading models)
        engineCancellable = ModelStateManager.shared.$selectedEngine
            .dropFirst() // Skip the initial value
            .sink { engine in
                switch engine {
                case .whisperKit:
                    // Unload Parakeet to free memory
                    ModelStateManager.shared.unloadParakeetModel()
                case .parakeet:
                    // Unload WhisperKit to free memory
                    ModelStateManager.shared.unloadWhisperKitModel()
                }
            }

        // Note: Parakeet version changes don't auto-load
        // User must click to download/select a specific version
    }
    

    
    @objc func openSettings() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .settings)
    }
    
    @objc func showTranscriptionHistory() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .history)
    }
    
    // MARK: - TTS Engine Helpers
    
    /// Currently active TTS provider
    @available(macOS 14.0, *)
    var currentTTSProvider: TTSAudioProvider? {
        switch currentTTSEngine {
        case .gemini:
            return audioCollector
        case .supertonic:
            return supertonicEngine
        case .edge:
            return edgeTTSEngine
        }
    }
    
    /// Initialize Supertonic native engine
    func initSupertonic() {
        let voice = UserDefaults.standard.string(forKey: "supertonicVoice") ?? "M1"
        let lang = UserDefaults.standard.string(forKey: "supertonicLang") ?? "ko"
        let speed = UserDefaults.standard.double(forKey: "supertonicSpeed")
        let actualSpeed = speed > 0 ? Float(speed) : Float(1.05)
        
        supertonicEngine = SupertonicEngine(voiceName: voice, lang: lang, speed: actualSpeed)
        streamingPlayer = GeminiStreamingPlayer(sampleRate: 44100, playbackSpeed: 1.0)  // Supertonic handles its own speed control
        
        // Load ONNX Runtime model in background (avoid blocking main thread)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try self?.supertonicEngine?.load()
                logger.info("Supertonic native TTS initialized")
            } catch {
                logger.error("Supertonic init failed: \(error)")
            }
        }
    }
    
    /// Initialize Edge TTS engine
    func initEdgeTTS() {
        let voice = UserDefaults.standard.string(forKey: "edgeTTSVoice") ?? "ko-KR-SunHiNeural"
        let rateInt = UserDefaults.standard.integer(forKey: "edgeTTSRate")  // defaults to 0
        let rate = "\(rateInt > 0 ? "+" : "")\(rateInt)%"
        
        if #available(macOS 14.0, *) {
            edgeTTSEngine = EdgeTTSEngine(voiceName: voice, rate: rate)
            streamingPlayer = GeminiStreamingPlayer(sampleRate: 24000, playbackSpeed: 1.0)
            logger.info("Edge TTS initialized (voice: \(voice))")
        }
    }
    
    /// Switch TTS engine
    func switchTTSEngine(to engine: TTSEngine) {
        guard engine != currentTTSEngine else { return }
        
        // Clean up existing engine
        switch currentTTSEngine {
        case .gemini:
            if #available(macOS 14.0, *) {
                audioCollector?.closeConnection()
            }
        case .supertonic:
            supertonicEngine?.unload()
            supertonicEngine = nil
        case .edge:
            edgeTTSEngine = nil
        }
        
        currentTTSEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: "ttsEngine")
        
        // Initialize new engine
        if #available(macOS 14.0, *) {
            switch engine {
            case .gemini:
                if let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty {
                    streamingPlayer = GeminiStreamingPlayer(sampleRate: 24000, playbackSpeed: 1.15)
                    audioCollector = GeminiAudioCollector(apiKey: apiKey)
                    logger.info("Switched to Gemini TTS")
                }
            case .supertonic:
                initSupertonic()
            case .edge:
                initEdgeTTS()
            }
        }
    }
    
    @objc func showStats() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .statistics)
    }
    
    func handleReadSelectedTextToggle() {
        // If currently playing, stop the audio
        if isCurrentlyPlaying {
            stopCurrentPlayback()
            return
        }

        // Otherwise, start reading selected text
        readSelectedText()
    }

    func toggleScreenRecording() {
        // Prevent starting screen recording if audio recording is active
        if !screenRecorder.recording && audioManager.isRecording {
            sendNotification(title: "Cannot Start Screen Recording", body: "Audio recording is currently active. Stop it first with Cmd+Option+Z")
            logger.warning("Blocked screen recording - audio recording is active")
            return
        }

        // Prevent starting screen recording if Gemini audio recording is active
        if !screenRecorder.recording && geminiAudioManager.isRecording {
            sendNotification(title: "Cannot Start Screen Recording", body: "Gemini audio recording is currently active. Stop it first with Cmd+Option+X")
            logger.warning("Blocked screen recording - Gemini audio recording is active")
            return
        }

        if screenRecorder.recording {
            // Stop recording
            screenRecorder.stopRecording { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let videoURL):
                    self.currentVideoURL = videoURL

                    // Start video processing indicator
                    self.startVideoProcessingIndicator()

                    // Transcribe the video
                    logger.info("Starting transcription for: \(videoURL.lastPathComponent)")
                    self.videoTranscriber.transcribe(videoURL: videoURL) { result in
                        DispatchQueue.main.async {
                            self.stopVideoProcessingIndicator()

                            switch result {
                            case .success(var transcription):
                                // Apply text replacements from config
                                transcription = TextReplacements.shared.processText(transcription)

                                // Save to history
                                TranscriptionHistory.shared.addEntry(transcription)

                                // Paste transcription at cursor
                                self.pasteTextAtCursor(transcription)

                                // Delete the video file after successful transcription
                                if let videoURL = self.currentVideoURL {
                                    do {
                                        try FileManager.default.removeItem(at: videoURL)
                                        logger.info("Deleted video file: \(videoURL.lastPathComponent)")
                                    } catch {
                                        logger.warning("Failed to delete video file: \(error.localizedDescription)")
                                    }
                                }

                                // Show completion notification with transcription
                                sendNotification(title: "Video Transcribed", subtitle: "Pasted at cursor", body: transcription.prefix(100) + (transcription.count > 100 ? "..." : ""))

                                logger.info("Transcription complete:")
                                // (separator line removed)
                                logger.info("\(transcription)")
                                // (separator line removed)

                            case .failure(let error):
                                // Show error notification
                                sendNotification(title: "Transcription Failed", body: error.localizedDescription)

                                logger.error("Transcription failed: \(error.localizedDescription)")
                            }
                        }
                    }

                case .failure(let error):
                    logger.error("Screen recording failed: \(error.localizedDescription)")

                    sendNotification(title: "Recording Failed", body: error.localizedDescription)

                    // Reset status bar
                    if let button = self.statusItem.button {
                        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
                        button.title = ""
                    }
                }
            }

            // Show stopping notification
            sendNotification(title: "Screen Recording Stopped", body: "Saving video...")
            logger.info("Screen recording STOPPED")

        } else {
            // Start recording
            screenRecorder.startRecording { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let videoURL):
                    self.currentVideoURL = videoURL

                    // Update status bar to show recording indicator
                    if let button = self.statusItem.button {
                        button.image = nil
                        button.title = "🎥 REC"
                    }

                    // Show success notification
                    sendNotification(title: "Screen Recording Started", body: "Press Cmd+Option+C again to stop")
                    logger.info("Screen recording STARTED")

                case .failure(let error):
                    logger.error("Failed to start recording: \(error.localizedDescription)")

                    sendNotification(title: "Recording Failed", body: error.localizedDescription)
                }
            }
        }
    }

    func pasteLastTranscription() {
        // Get the most recent transcription from history
        guard let lastEntry = TranscriptionHistory.shared.getEntries().first else {
            sendNotification(title: "No Transcription Available", body: "No transcription history found")
            logger.warning("No transcription history to paste")
            return
        }

        // Paste the last transcription at cursor
        pasteTextAtCursor(lastEntry.text)

        sendNotification(title: "Pasted Last Transcription", body: lastEntry.text.prefix(100) + (lastEntry.text.count > 100 ? "..." : ""))
        logger.info("Pasted last transcription: \(lastEntry.text.prefix(50))...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        supertonicEngine?.unload()
    }
    
    func stopCurrentPlayback() {
        logger.info("Stopping audio playback")
        
        // Cancel the current streaming task
        currentStreamingTask?.cancel()
        currentStreamingTask = nil
        
        // Stop the audio players
        streamingPlayer?.stopAudioEngine()
        edgeTTSEngine?.stopPlayback()
        
        // Reset playing state
        isCurrentlyPlaying = false
        
        sendNotification(title: "Audio Stopped", body: "Text-to-speech playback stopped")
    }
    
    func readSelectedText() {
        // Save current clipboard contents first
        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types ?? []
        var savedItems: [NSPasteboard.PasteboardType: Data] = [:]
        
        for type in savedTypes {
            if let data = pasteboard.data(forType: type) {
                savedItems[type] = data
            }
        }
        
        logger.info("Saved \(savedItems.count) clipboard types before reading selection")
        
        // Simulate Cmd+C to copy selected text
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDownC = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'c' key
        let keyUpC = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        
        // Set Cmd modifier
        keyDownC?.flags = .maskCommand
        keyUpC?.flags = .maskCommand
        
        // Post the events
        keyDownC?.post(tap: .cghidEventTap)
        keyUpC?.post(tap: .cghidEventTap)
        
        // Give system a moment to process the copy command
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Read from clipboard
            let copiedText = pasteboard.string(forType: .string) ?? ""
            
            if !copiedText.isEmpty {
                logger.info("Selected text for streaming TTS: \(copiedText)")
                
                // Try to stream speech with current TTS provider
                if #available(macOS 14.0, *),
                   let provider = self?.currentTTSProvider,
                   let streamingPlayer = self?.streamingPlayer {
                    self?.isCurrentlyPlaying = true
                    let engineName = self?.currentTTSEngine.displayName ?? "TTS"
                    
                    self?.currentStreamingTask = Task {
                        do {
                            sendNotification(title: "\(engineName) TTS", body: "Starting synthesis: \(copiedText.prefix(50))\(copiedText.count > 50 ? "..." : "")")
                            
                            // Edge TTS: mp3 direct playback, others: PCM streaming
                            if let edgeEngine = self?.edgeTTSEngine, self?.currentTTSEngine == .edge {
                                try await edgeEngine.playText(copiedText)
                            } else {
                                try await streamingPlayer.playText(copiedText, provider: provider)
                            }
                            
                            // Check if task was cancelled
                            if Task.isCancelled {
                                return
                            }
                            
                            sendNotification(title: "Streaming TTS Complete", body: "Finished streaming selected text")
                            
                        } catch is CancellationError {
                            logger.info("Audio streaming was cancelled")
                        } catch where Task.isCancelled || "\(error)".contains("CancellationError") {
                            // CancellationError wrapped in another error (e.g. playbackError)
                            logger.info("Audio streaming was cancelled (wrapped)")
                        } catch {
                            logger.error("Streaming TTS Error: \(error)")
                            
                            sendNotification(title: "Streaming TTS Error", body: "Failed to stream text: \(error.localizedDescription)")
                            
                            // Note: Text is already in clipboard from Cmd+C, no need to copy again
                            sendNotification(title: "Text Ready in Clipboard", body: "Streaming failed, selected text copied via Cmd+C")
                        }
                        
                        // Reset playing state when task completes (normally or via cancellation)
                        DispatchQueue.main.async { [weak self] in
                            self?.isCurrentlyPlaying = false
                            self?.currentStreamingTask = nil
                        }
                        
                        // Restore original clipboard contents after streaming
                        nonisolated(unsafe) let pb = pasteboard
                        let items = savedItems
                        DispatchQueue.main.async {
                            pb.clearContents()
                            for (type, data) in items {
                                pb.setData(data, forType: type)
                            }
                            logger.info("Restored original clipboard contents")
                        }
                    }
                } else {
                    sendNotification(title: "Selected Text Copied", body: "Streaming TTS not available, text copied to clipboard: \(copiedText.prefix(100))\(copiedText.count > 100 ? "..." : "")")
                    
                    // Don't restore clipboard in this case since user might want the copied text
                }
            } else {
                logger.warning("No text was copied - nothing selected or copy failed")
                
                sendNotification(title: "No Text Selected", body: "Please select some text first before using TTS")
                
                // Restore clipboard since copy attempt failed
                pasteboard.clearContents()
                for (type, data) in savedItems {
                    pasteboard.setData(data, forType: type)
                }
                logger.info("Restored clipboard after failed copy")
            }
        }
    }
    
    func updateStatusBarWithLevel(db: Float) {
        // Don't update status bar if screen recording is active
        if screenRecorder.recording {
            return
        }

        if let button = statusItem.button {
            button.image = nil

            // Convert dB to a 0-1 range (assuming -55dB to -20dB for normal speech)
            let normalizedLevel = max(0, min(1, (db + 55) / 35))

            // Create a visual bar using Unicode block characters
            let barLength = 8
            let filledLength = Int(normalizedLevel * Float(barLength))

            var bar = ""
            for i in 0..<barLength {
                if i < filledLength {
                    bar += "█"
                } else {
                    bar += "▁"
                }
            }

            button.title = "● " + bar
        }
    }
    
    func startTranscriptionIndicator() {
        // Don't update status bar if screen recording is active
        if screenRecorder.recording {
            return
        }

        // Show initial indicator
        if let button = statusItem.button {
            button.image = nil
            button.title = "⚙️ Processing..."
        }

        // Animate the indicator
        var dotCount = 0
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else {
                self?.transcriptionTimer?.invalidate()
                return
            }

            // Don't update if screen recording is active
            if self.screenRecorder.recording {
                return
            }

            if let button = self.statusItem.button {
                dotCount = (dotCount + 1) % 4
                let dots = String(repeating: ".", count: dotCount)
                let spaces = String(repeating: " ", count: 3 - dotCount)
                button.title = "⚙️ Processing" + dots + spaces
            }
        }
    }
    
    func stopTranscriptionIndicator() {
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil

        // Don't update status bar if screen recording is active
        if screenRecorder.recording {
            return
        }

        // If not currently recording, reset to default icon.
        // When recording, the live level updates will take over UI shortly.
        if audioManager?.isRecording != true {
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
                button.title = ""
            }
        }
    }

    func startVideoProcessingIndicator() {
        // Show initial indicator
        if let button = statusItem.button {
            button.image = nil
            button.title = "🎬 Processing..."
        }

        // Animate the indicator
        var dotCount = 0
        videoProcessingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else {
                self?.videoProcessingTimer?.invalidate()
                return
            }

            if let button = self.statusItem.button {
                dotCount = (dotCount + 1) % 4
                let dots = String(repeating: ".", count: dotCount)
                let spaces = String(repeating: " ", count: 3 - dotCount)
                button.title = "🎬 Processing" + dots + spaces
            }
        }
    }

    func stopVideoProcessingIndicator() {
        videoProcessingTimer?.invalidate()
        videoProcessingTimer = nil

        // Reset to default icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }
    }
    

    
    func showTranscriptionNotification(_ text: String) {
        sendNotification(title: "Transcription Complete", subtitle: "Pasted at cursor", body: text, sound: true)
    }
    
    func showTranscriptionError(_ message: String) {
        sendNotification(title: "Transcription Error", body: message, sound: true)
    }
    
    func pasteTextAtCursor(_ text: String) {
        // Save current clipboard contents first
        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types ?? []
        var savedItems: [NSPasteboard.PasteboardType: Data] = [:]
        
        for type in savedTypes {
            if let data = pasteboard.data(forType: type) {
                savedItems[type] = data
            }
        }
        
        logger.info("Saved \(savedItems.count) clipboard types")
        
        // Set our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Try to paste
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Create paste event
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
        
        logger.info("Paste command sent")
        
        // After a short delay, check if paste might have failed
        // and show history window for easy manual copying
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // Get the frontmost app to see where we tried to paste
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let appName = frontmostApp?.localizedName ?? "Unknown"
            let bundleId = frontmostApp?.bundleIdentifier ?? ""
            
            logger.info("Attempted paste in: \(appName) (\(bundleId))")
            
            // Apps where paste typically fails or doesn't make sense
            let problematicApps = [
                "com.apple.finder",
                "com.apple.dock", 
                "com.apple.systempreferences"
            ]
            
            // Check if the app is known to not accept pastes well
            // OR if the user is in an unusual context
            if problematicApps.contains(bundleId) {
                logger.warning("Detected potential paste failure - showing history window")
                self?.showHistoryForPasteFailure()
            }
            
            // Restore clipboard
            pasteboard.clearContents()
            for (type, data) in savedItems {
                pasteboard.setData(data, forType: type)
            }
            logger.info("Restored clipboard")
        }
    }
    
    func showHistoryForPasteFailure() {
        // When paste fails in certain apps, show the history window
        // by simulating the Command+Option+A keyboard shortcut
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key code for 'A' is 0x00
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true) {
            keyDown.flags = [.maskCommand, .maskAlternate]
            keyDown.post(tap: .cghidEventTap)
        }
        
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false) {
            keyUp.flags = [.maskCommand, .maskAlternate]
            keyUp.post(tap: .cghidEventTap)
        }
        
        logger.info("Showing history window for paste failure recovery")
    }
    
    // MARK: - AudioTranscriptionManagerDelegate
    
    func audioLevelDidUpdate(db: Float) {
        updateStatusBarWithLevel(db: db)
    }
    
    func transcriptionDidStart() {
        startTranscriptionIndicator()
    }
    
    func transcriptionDidComplete(text: String) {
        stopTranscriptionIndicator()
        pasteTextAtCursor(text)
        showTranscriptionNotification(text)
    }
    
    func transcriptionDidFail(error: String) {
        stopTranscriptionIndicator()
        showTranscriptionError(error)
    }
    
    func recordingWasCancelled() {
        // Ensure any processing indicator is stopped
        stopTranscriptionIndicator()
        // Reset the status bar icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }
        
        // Show notification
        sendNotification(title: "Recording Cancelled", body: "Recording was cancelled")
    }
    
    func recordingWasSkippedDueToSilence() {
        // Ensure any processing indicator is stopped
        stopTranscriptionIndicator()
        // Reset the status bar icon
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Assistant")
            button.title = ""
        }
        
        // Optionally show a subtle notification
        sendNotification(title: "Recording Skipped", body: "Audio was too quiet to transcribe")
    }
    
}

// Create and run the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only, no dock icon

// Set the app icon from our custom ICNS file
if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
   let iconImage = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = iconImage
}

app.run()
