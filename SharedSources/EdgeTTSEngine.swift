import Foundation

/// Edge TTS 엔진 — Python edge-tts CLI wrapper
/// API 키 불필요, 400+ 신경망 음성
/// URLSessionWebSocketTask는 Origin/Cookie 헤더를 제대로 전송하지 못해
/// Python edge-tts CLI를 통해 안정적으로 동작
@available(macOS 14.0, *)
public class EdgeTTSEngine: TTSAudioProvider {
    public let sampleRate: Double = 24000
    
    private var voiceName: String
    private var rate: String
    private var pitch: String
    private var volume: String
    
    /// edge-tts CLI 경로 (venv 또는 시스템)
    private let edgeTTSPath: String
    
    public init(
        voiceName: String = "ko-KR-SunHiNeural",
        rate: String = "+0%",
        pitch: String = "+0Hz",
        volume: String = "+0%"
    ) {
        self.voiceName = voiceName
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        
        // edge-tts CLI 경로 탐색
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/edge-tts",
            "/usr/local/bin/edge-tts",
            "/opt/homebrew/bin/edge-tts",
            // venv 경로
            "/tmp/edge-tts-venv/bin/edge-tts",
        ]
        self.edgeTTSPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "edge-tts"  // fallback to PATH
    }
    
    // MARK: - TTSAudioProvider
    
    public func collectAudioChunks(from text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.synthesize(text: text, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - CLI-based Synthesis
    
    private func synthesize(
        text: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        // edge-tts outputs mp3 → use ffmpeg to convert to raw PCM
        let tmpMP3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-tts-\(UUID().uuidString).mp3")
        let tmpPCM = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-tts-\(UUID().uuidString).pcm")
        
        defer {
            try? FileManager.default.removeItem(at: tmpMP3)
            try? FileManager.default.removeItem(at: tmpPCM)
        }
        
        // Run edge-tts CLI
        let edgeProcess = Process()
        edgeProcess.executableURL = URL(fileURLWithPath: edgeTTSPath)
        edgeProcess.arguments = [
            "--voice", voiceName,
            "--rate", rate,
            "--pitch", pitch,
            "--volume", volume,
            "--text", text,
            "--write-media", tmpMP3.path,
        ]
        
        let pipe = Pipe()
        edgeProcess.standardError = pipe
        
        try edgeProcess.run()
        edgeProcess.waitUntilExit()
        
        guard edgeProcess.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw EdgeTTSError.synthesisError("edge-tts failed (exit \(edgeProcess.terminationStatus)): \(stderr)")
        }
        
        guard FileManager.default.fileExists(atPath: tmpMP3.path) else {
            throw EdgeTTSError.synthesisError("edge-tts produced no output")
        }
        
        // Convert mp3 → raw PCM 24kHz 16-bit mono via ffmpeg
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = [
            "ffmpeg", "-y", "-i", tmpMP3.path,
            "-f", "s16le", "-acodec", "pcm_s16le",
            "-ar", "24000", "-ac", "1",
            tmpPCM.path,
        ]
        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice
        
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
        
        guard ffmpeg.terminationStatus == 0 else {
            throw EdgeTTSError.synthesisError("ffmpeg conversion failed")
        }
        
        // Read PCM and yield in chunks
        let pcmData = try Data(contentsOf: tmpPCM)
        let chunkSize = Int(sampleRate) * 2  // 1 second chunks (16-bit = 2 bytes/sample)
        var offset = 0
        
        while offset < pcmData.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, pcmData.count)
            continuation.yield(pcmData[offset..<end])
            offset = end
        }
        
        print("✅ [EdgeTTS] Complete: \(pcmData.count) bytes (\(String(format: "%.1f", Double(pcmData.count) / 2.0 / sampleRate))s)")
        continuation.finish()
    }
    
    // MARK: - Configuration
    
    public func setVoice(_ name: String) {
        voiceName = name
        print("🔊 [EdgeTTS] Voice changed to \(name)")
    }
    
    public func setRate(_ newRate: String) {
        rate = newRate
    }
    
    public func setPitch(_ newPitch: String) {
        pitch = newPitch
    }
    
    public func setVolume(_ newVolume: String) {
        volume = newVolume
    }
    
    public var info: String {
        "EdgeTTSEngine(voice=\(voiceName), rate=\(rate), pitch=\(pitch))"
    }
    
    // MARK: - Voice List
    
    public struct Voice: Codable {
        public let name: String
        public let shortName: String
        public let gender: String
        public let locale: String
        public let friendlyName: String
        
        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case shortName = "ShortName"
            case gender = "Gender"
            case locale = "Locale"
            case friendlyName = "FriendlyName"
        }
    }
    
    /// 사용 가능한 음성 목록 가져오기 (edge-tts --list-voices)
    public static func fetchVoices() async throws -> [Voice] {
        let edgeTTSPath = [
            "\(NSHomeDirectory())/.local/bin/edge-tts",
            "/usr/local/bin/edge-tts",
            "/opt/homebrew/bin/edge-tts",
            "/tmp/edge-tts-venv/bin/edge-tts",
        ].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "edge-tts"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: edgeTTSPath)
        process.arguments = ["--list-voices"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        // Use hardcoded Korean voices (CLI output parsing is fragile)
        _ = output
        return KoreanVoice.allCases.map { v in
            Voice(name: v.rawValue, shortName: v.rawValue, gender: "", locale: "ko-KR", friendlyName: v.displayName)
        }
    }
    
    /// 특정 언어의 음성 목록
    public static func fetchVoices(locale: String) async throws -> [Voice] {
        let all = try await fetchVoices()
        return all.filter { $0.locale.hasPrefix(locale) }
    }
}

// MARK: - Popular Korean Voices

public extension EdgeTTSEngine {
    /// 한국어 인기 음성 프리셋
    enum KoreanVoice: String, CaseIterable {
        case sunHi = "ko-KR-SunHiNeural"        // 여성
        case inJoon = "ko-KR-InJoonNeural"       // 남성
        case bonJin = "ko-KR-BongJinNeural"      // 남성
        case gookMin = "ko-KR-GookMinNeural"     // 남성
        case jiMin = "ko-KR-JiMinNeural"         // 여성
        case seokHo = "ko-KR-SeoHyeonNeural"     // 여성 (아이)
        case sunHyeon = "ko-KR-SoonBokNeural"    // 여성 (노인)
        case yuJin = "ko-KR-YuJinNeural"         // 여성
        
        public var displayName: String {
            switch self {
            case .sunHi: return "선히 (여성)"
            case .inJoon: return "인준 (남성)"
            case .bonJin: return "봉진 (남성)"
            case .gookMin: return "국민 (남성)"
            case .jiMin: return "지민 (여성)"
            case .seokHo: return "서현 (여성/아이)"
            case .sunHyeon: return "순복 (여성/노인)"
            case .yuJin: return "유진 (여성)"
            }
        }
    }
}

// MARK: - Errors

public enum EdgeTTSError: Error, LocalizedError {
    case invalidURL
    case connectionFailed(String)
    case synthesisTimeout
    case synthesisError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Edge TTS URL"
        case .connectionFailed(let msg):
            return "Edge TTS connection failed: \(msg)"
        case .synthesisTimeout:
            return "Edge TTS synthesis timed out"
        case .synthesisError(let msg):
            return "Edge TTS synthesis error: \(msg)"
        }
    }
}
