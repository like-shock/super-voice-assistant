import SwiftUI
import SharedModels
import Logging

private let logger = AppLogger.make("TTSSettings")

// MARK: - TTS Settings Section

@available(macOS 14.0, *)
struct TTSSettingsSection: View {
    @AppStorage("ttsEngine") private var selectedEngine: String = TTSEngine.supertonic.rawValue
    @AppStorage("supertonicVoice") private var voiceName: String = "M1"
    @AppStorage("supertonicLang") private var lang: String = "ko"
    @AppStorage("supertonicSpeed") private var speed: Double = 1.05
    
    private var currentEngine: TTSEngine {
        TTSEngine(rawValue: selectedEngine) ?? .supertonic
    }
    
    private var hasGeminiKey: Bool {
        if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty {
            return true
        }
        return false
    }
    
    private var modelExists: Bool {
        let modelDir = SupertonicEngine.defaultModelDir()
        return FileManager.default.fileExists(atPath: "\(modelDir)/onnx/tts.json")
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Text("Text-to-Speech")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)
            
            // Supertonic card
            supertonicCard
            
            // Edge TTS card
            edgeTTSCard
            
            // Gemini card
            geminiCard
        }
    }
    
    // MARK: - Supertonic Card
    
    private var supertonicCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Supertonic (Local)")
                        .font(.system(.body, design: .default, weight: .semibold))
                    Text("Offline · ONNX Runtime · ~160ms/sentence")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if currentEngine == .supertonic {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            
            // Model status
            if !modelExists {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Model not downloaded. Run: pip install supertonic && supertonic info")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Options (shown when selected)
            if currentEngine == .supertonic {
                Divider()
                
                HStack(spacing: 16) {
                    // Voice picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $voiceName) {
                            ForEach(["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"], id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        .onChange(of: voiceName) { _, newValue in
                            applyVoiceChange(newValue)
                        }
                    }
                    
                    // Language picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Language")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $lang) {
                            Text("한국어").tag("ko")
                            Text("English").tag("en")
                            Text("Español").tag("es")
                            Text("Português").tag("pt")
                            Text("Français").tag("fr")
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .onChange(of: lang) { _, newValue in
                            applyLangChange(newValue)
                        }
                    }
                    
                    // Speed slider
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speed: \(String(format: "%.2f", speed))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $speed, in: 0.7...2.0, step: 0.05)
                            .frame(minWidth: 120)
                            .onChange(of: speed) { _, newValue in
                                applySpeedChange(Float(newValue))
                            }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(currentEngine == .supertonic ? Color.blue.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(currentEngine == .supertonic ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            switchEngine(to: .supertonic)
        }
    }
    
    // MARK: - Edge TTS Card
    
    @AppStorage("edgeTTSVoice") private var edgeVoice: String = "ko-KR-SunHiNeural"
    @AppStorage("edgeTTSRate") private var edgeRate: Int = 0  // -50 ~ +100 percent
    
    private static let edgeVoicePresets: [(name: String, id: String)] = [
        ("선히 (여성)", "ko-KR-SunHiNeural"),
        ("인준 (남성)", "ko-KR-InJoonNeural"),
        ("현수 (남성/다국어)", "ko-KR-HyunsuMultilingualNeural"),
        ("Ava (여성/다국어)", "en-US-AvaMultilingualNeural"),
        ("Emma (여성/다국어)", "en-US-EmmaMultilingualNeural"),
        ("Jenny (EN-F)", "en-US-JennyNeural"),
        ("Aria (EN-F)", "en-US-AriaNeural"),
        ("Guy (EN-M)", "en-US-GuyNeural"),
        ("Xiaoxiao (ZH-F)", "zh-CN-XiaoxiaoNeural"),
    ]
    
    private var edgeTTSCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edge TTS (Cloud/Free)")
                        .font(.system(.body, design: .default, weight: .semibold))
                    Text("Microsoft Edge · No API Key · 400+ voices")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if currentEngine == .edge {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.purple)
                }
            }
            
            if currentEngine == .edge {
                Divider()
                
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $edgeVoice) {
                            ForEach(Self.edgeVoicePresets, id: \.id) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: edgeVoice) { _, newValue in
                            applyEdgeVoiceChange(newValue)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rate: \(edgeRate > 0 ? "+" : "")\(edgeRate)%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: Binding(
                            get: { Double(edgeRate) },
                            set: { edgeRate = Int($0) }
                        ), in: -50...100, step: 5)
                            .frame(minWidth: 120)
                            .onChange(of: edgeRate) { _, newValue in
                                applyEdgeRateChange(newValue)
                            }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(currentEngine == .edge ? Color.purple.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(currentEngine == .edge ? Color.purple.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            switchEngine(to: .edge)
        }
    }
    
    private func applyEdgeVoiceChange(_ voice: String) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let engine = appDelegate.edgeTTSEngine {
            engine.setVoice(voice)
            previewEdgeVoice()
        }
    }
    
    private func applyEdgeRateChange(_ rate: Int) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let engine = appDelegate.edgeTTSEngine {
            engine.setRate("\(rate > 0 ? "+" : "")\(rate)%")
        }
    }
    
    private func previewEdgeVoice() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let engine = appDelegate.edgeTTSEngine else { return }
        
        let sampleText: String
        if edgeVoice.hasPrefix("ko-") {
            sampleText = "안녕하세요, 이 목소리는 어떤가요?"
        } else if edgeVoice.hasPrefix("zh-") {
            sampleText = "你好，这个声音怎么样？"
        } else {
            sampleText = "Hello, how does this voice sound?"
        }
        
        appDelegate.stopCurrentPlayback()
        
        appDelegate.currentStreamingTask?.cancel()
        appDelegate.currentStreamingTask = Task {
            do {
                try await engine.playText(sampleText)
            } catch is CancellationError {
            } catch {
                logger.warning("Edge TTS preview failed: \(error)")
            }
        }
    }
    
    // MARK: - Gemini Card
    
    private var geminiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cloud")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini Live (Cloud)")
                        .font(.system(.body, design: .default, weight: .semibold))
                    Text("Streaming WebSocket · Requires API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if currentEngine == .gemini {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            
            // API key status
            HStack(spacing: 4) {
                if hasGeminiKey {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("API Key configured")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Set GEMINI_API_KEY in .env")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(currentEngine == .gemini ? Color.green.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(currentEngine == .gemini ? Color.green.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasGeminiKey {
                switchEngine(to: .gemini)
            }
        }
        .opacity(hasGeminiKey ? 1.0 : 0.6)
    }
    
    // MARK: - Actions
    
    private func switchEngine(to engine: TTSEngine) {
        guard engine.rawValue != selectedEngine else { return }
        selectedEngine = engine.rawValue
        
        // Notify AppDelegate
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.switchTTSEngine(to: engine)
        }
    }
    
    private func applyVoiceChange(_ voice: String) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let engine = appDelegate.supertonicEngine {
            try? engine.setVoice(voice)
            previewVoice()
        }
    }
    
    /// 현재 설정으로 짧은 샘플 재생
    private func previewVoice() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let engine = appDelegate.supertonicEngine,
              engine.isLoaded else { return }
        
        let sampleText: String
        switch lang {
        case "ko": sampleText = "안녕하세요, 이 목소리는 어떤가요?"
        case "en": sampleText = "Hello, how does this voice sound?"
        case "es": sampleText = "Hola, ¿cómo suena esta voz?"
        case "pt": sampleText = "Olá, como soa esta voz?"
        case "fr": sampleText = "Bonjour, comment trouvez-vous cette voix?"
        default: sampleText = "Hello, how does this voice sound?"
        }
        
        // Cancel previous preview if playing
        appDelegate.stopCurrentPlayback()
        
        if let player = appDelegate.streamingPlayer {
            appDelegate.currentStreamingTask?.cancel()
            appDelegate.currentStreamingTask = Task {
                do {
                    try await player.playText(sampleText, provider: engine)
                } catch is CancellationError {
                    // Cancelled, ignore
                } catch {
                    logger.warning("Voice preview failed: \(error)")
                }
            }
        }
    }
    
    private func applyLangChange(_ newLang: String) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let engine = appDelegate.supertonicEngine {
            engine.setLang(newLang)
        }
    }
    
    private func applySpeedChange(_ newSpeed: Float) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let engine = appDelegate.supertonicEngine {
            engine.setSpeed(newSpeed)
        }
    }
}
