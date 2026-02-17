import Foundation
import Logging
import OnnxRuntimeBindings

/// Swift 네이티브 Supertonic TTS 엔진
/// ONNX Runtime으로 인-프로세스 추론, Python 의존성 없음
@available(macOS 14.0, *)
public class SupertonicEngine: TTSAudioProvider {
    public var sampleRate: Double { Double(tts?.sampleRate ?? 44100) }
    private let logger = AppLogger.make("Supertonic")
    
    private var tts: TextToSpeech?
    private var style: Style?
    private var env: ORTEnv?
    
    private var voiceName: String
    private var lang: String
    private var speed: Float
    private var totalSteps: Int
    
    private let modelDir: String
    
    /// 동시 합성 요청 직렬화
    private let synthesisLock = SupertonicSynthesisLock()
    
    public private(set) var isLoaded: Bool = false
    
    /// 레거시 경로 (~/.cache/supertonic2)에서 앱 내부 경로로 마이그레이션
    private static func migrateIfNeeded(to newPath: String) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let legacyPath = "\(home)/.cache/supertonic2"
        
        // 새 경로에 이미 모델이 있으면 스킵
        guard !fm.fileExists(atPath: "\(newPath)/onnx/tts.json") else { return }
        // 레거시 경로에 모델이 없으면 스킵
        guard fm.fileExists(atPath: "\(legacyPath)/onnx/tts.json") else { return }
        
        do {
            try fm.createDirectory(atPath: newPath, withIntermediateDirectories: true)
            // onnx/ 와 voice_styles/ 복사
            for subdir in ["onnx", "voice_styles"] {
                let src = "\(legacyPath)/\(subdir)"
                let dst = "\(newPath)/\(subdir)"
                guard fm.fileExists(atPath: src) else { continue }
                if fm.fileExists(atPath: dst) { continue }
                try fm.copyItem(atPath: src, toPath: dst)
            }
            AppLogger.make("Supertonic").info("Migrated models from ~/.cache/supertonic2 to Application Support")
        } catch {
            AppLogger.make("Supertonic").warning("Migration failed: \(error)")
        }
    }
    
    /// 기본 모델 경로 (Application Support)
    public static func defaultModelDir() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("SuperVoiceAssistant")
            .appendingPathComponent("models")
            .appendingPathComponent("supertonic")
            .path
    }
    
    public init(
        modelDir: String? = nil,
        voiceName: String = "M1",
        lang: String = "ko",
        speed: Float = 1.05,
        totalSteps: Int = 5
    ) {
        if let dir = modelDir {
            self.modelDir = dir
        } else {
            let defaultPath = SupertonicEngine.defaultModelDir()
            SupertonicEngine.migrateIfNeeded(to: defaultPath)
            self.modelDir = defaultPath
        }
        
        self.voiceName = voiceName
        self.lang = lang
        self.speed = speed
        self.totalSteps = totalSteps
    }
    
    // MARK: - Lifecycle
    
    /// 모델 로딩 (1회, 이후 재사용)
    public func load() throws {
        guard !isLoaded else { return }
        
        let onnxDir = "\(modelDir)/onnx"
        let voiceStylePath = "\(modelDir)/voice_styles/\(voiceName).json"
        
        // 모델 파일 존재 확인
        guard FileManager.default.fileExists(atPath: "\(onnxDir)/tts.json") else {
            throw SupertonicEngineError.modelNotFound(
                "Model not found at \(onnxDir). Run 'pip install supertonic && supertonic info' to download models, or clone from HuggingFace."
            )
        }
        
        guard FileManager.default.fileExists(atPath: voiceStylePath) else {
            throw SupertonicEngineError.voiceStyleNotFound(voiceName)
        }
        
        logger.info("Loading model from \(onnxDir)...")
        let startTime = Date()
        
        env = try ORTEnv(loggingLevel: .warning)
        tts = try loadTextToSpeech(onnxDir, false, env!)
        style = try loadVoiceStyle([voiceStylePath], verbose: false)
        
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("Model loaded in \(String(format: "%.2f", elapsed))s (voice: \(voiceName), lang: \(lang), sampleRate: \(tts!.sampleRate))")
        
        isLoaded = true
    }
    
    /// 리소스 해제
    public func unload() {
        tts = nil
        style = nil
        env = nil
        isLoaded = false
        logger.info("Engine unloaded")
    }
    
    // MARK: - TTSAudioProvider
    
    /// 텍스트를 PCM 오디오 청크 스트림으로 변환 (문장 단위)
    public func collectAudioChunks(from text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // 자동 로드
                    if !self.isLoaded {
                        try self.load()
                    }
                    
                    let rawChunks = SmartSentenceSplitter.splitByLines(text)
                    let sentences = SmartSentenceSplitter.mergeShortChunks(rawChunks, minChars: 20, maxChars: 80)
                    self.logger.info("\(rawChunks.count) chunks → merged to \(sentences.count)")
                    for (i, s) in sentences.enumerated() {
                        self.logger.debug("  [\(i+1)] \(s)")
                    }
                    
                    for (index, sentence) in sentences.enumerated() {
                        try Task.checkCancellation()
                        
                        let pcmData = try await self.synthesize(sentence)
                        
                        if !pcmData.isEmpty {
                            self.logger.info("\(index+1)/\(sentences.count): \(pcmData.count) bytes (\(String(format: "%.1f", Double(pcmData.count) / 2.0 / self.sampleRate))s)")
                            continuation.yield(pcmData)
                        }
                        
                        // 문장 간 무음 (0.25초)
                        if index < sentences.count - 1 {
                            let silenceSamples = Int(self.sampleRate * 0.25)
                            let silenceData = Data(count: silenceSamples * 2)  // 16-bit = 2 bytes/sample
                            continuation.yield(silenceData)
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Synthesis
    
    /// 단일 텍스트 합성 → raw PCM Data (16-bit, 44100Hz, mono)
    public func synthesize(_ text: String) async throws -> Data {
        return try await synthesisLock.run {
            try self._synthesize(text)
        }
    }
    
    private func _synthesize(_ text: String) throws -> Data {
        guard let tts = tts, let style = style else {
            throw SupertonicEngineError.engineNotLoaded
        }
        
        let startTime = Date()
        
        // TextToSpeech.call()로 합성 (자동 chunking 포함)
        let result = try tts.call(text, lang, style, totalSteps, speed: speed, silenceDuration: 0.3)
        
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("Synthesized \(text.prefix(30))... → \(String(format: "%.2f", result.duration))s audio in \(String(format: "%.3f", elapsed))s")
        
        // Float → 16-bit PCM 변환
        let actualLen = Int(Float(tts.sampleRate) * result.duration)
        let wavSlice = Array(result.wav.prefix(actualLen))
        
        var pcmData = Data(capacity: wavSlice.count * 2)
        for sample in wavSlice {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            pcmData.append(Data(bytes: &int16, count: 2))
        }
        
        return pcmData
    }
    
    // MARK: - Configuration
    
    /// 음성 스타일 변경
    public func setVoice(_ name: String) throws {
        let voiceStylePath = "\(modelDir)/voice_styles/\(name).json"
        guard FileManager.default.fileExists(atPath: voiceStylePath) else {
            throw SupertonicEngineError.voiceStyleNotFound(name)
        }
        
        style = try loadVoiceStyle([voiceStylePath], verbose: false)
        voiceName = name
        logger.info("Voice changed to \(name)")
    }
    
    /// 언어 변경
    public func setLang(_ newLang: String) {
        lang = newLang
        logger.info("Language changed to \(newLang)")
    }
    
    /// 속도 변경
    public func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        logger.info("Speed changed to \(newSpeed)")
    }
    
    /// 현재 설정 정보
    public var info: String {
        "SupertonicEngine(voice=\(voiceName), lang=\(lang), speed=\(speed), loaded=\(isLoaded), sampleRate=\(sampleRate))"
    }
    
    /// 사용 가능한 음성 목록
    public var availableVoices: [String] {
        let voiceDir = "\(modelDir)/voice_styles"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: voiceDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}

// MARK: - SynthesisLock

private actor SupertonicSynthesisLock {
    func run<T>(_ body: () throws -> T) throws -> T {
        return try body()
    }
}

// MARK: - Errors

public enum SupertonicEngineError: Error, LocalizedError {
    case modelNotFound(String)
    case voiceStyleNotFound(String)
    case engineNotLoaded
    
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg):
            return msg
        case .voiceStyleNotFound(let name):
            return "Voice style '\(name)' not found in model directory"
        case .engineNotLoaded:
            return "Supertonic engine is not loaded. Call load() first."
        }
    }
}
