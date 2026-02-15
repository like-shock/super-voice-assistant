import CryptoKit
import Foundation

/// Edge TTS 스트리밍 엔진 — Microsoft Edge의 무료 TTS WebSocket API
/// API 키 불필요, 400+ 신경망 음성, raw PCM 24kHz 스트리밍
@available(macOS 14.0, *)
public class EdgeTTSEngine: TTSAudioProvider {
    public let sampleRate: Double = 24000
    
    private var voiceName: String
    private var rate: String
    private var pitch: String
    private var volume: String
    
    // Edge TTS constants
    private static let chromiumVersion = "130.0.2849.68"
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let windowsFileTimeEpoch: Int64 = 11_644_473_600
    
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
    }
    
    // MARK: - TTSAudioProvider
    
    public func collectAudioChunks(from text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.streamSpeech(text: text, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - WebSocket Streaming
    
    private func streamSpeech(
        text: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let token = Self.generateSecMsGecToken()
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(Self.trustedClientToken)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=1-\(Self.chromiumVersion)"
        
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }
        
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromiumVersion) Safari/537.36 Edg/\(Self.chromiumVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            forHTTPHeaderField: "Origin"
        )
        
        let ws = session.webSocketTask(with: request)
        ws.resume()
        
        defer { ws.cancel(with: .goingAway, reason: nil) }
        
        // Send config — request raw PCM 24kHz 16-bit mono
        let configMessage = """
        Content-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n
        {
            "context": {
                "synthesis": {
                    "audio": {
                        "metadataoptions": {
                            "sentenceBoundaryEnabled": "false",
                            "wordBoundaryEnabled": "false"
                        },
                        "outputFormat": "raw-24khz-16bit-mono-pcm"
                    }
                }
            }
        }
        """
        try await ws.send(.string(configMessage))
        
        // Send SSML
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        
        let ssml = """
        X-RequestId:\(requestId)\r\nContent-Type:application/ssml+xml\r\nPath:ssml\r\n\r\n
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="ko-KR">
            <voice name="\(voiceName)">
                <prosody rate="\(rate)" pitch="\(pitch)" volume="\(volume)">
                    \(escapedText)
                </prosody>
            </voice>
        </speak>
        """
        try await ws.send(.string(ssml))
        
        // Receive audio chunks
        var totalBytes = 0
        let headerSeparator = "Path:audio\r\n"
        
        while true {
            try Task.checkCancellation()
            
            let message = try await ws.receive()
            
            switch message {
            case .data(let data):
                // Binary message — extract audio after header
                if let str = String(data: data, encoding: .utf8),
                   let range = str.range(of: headerSeparator) {
                    let offset = range.upperBound.utf16Offset(in: str)
                    let audioData = data.suffix(from: data.startIndex + offset)
                    if !audioData.isEmpty {
                        continuation.yield(Data(audioData))
                        totalBytes += audioData.count
                    }
                } else {
                    // Pure binary audio data
                    if !data.isEmpty {
                        continuation.yield(data)
                        totalBytes += data.count
                    }
                }
                
            case .string(let str):
                if str.contains("Path:turn.end") {
                    print("✅ [EdgeTTS] Complete: \(totalBytes) bytes (\(String(format: "%.1f", Double(totalBytes) / 2.0 / sampleRate))s)")
                    continuation.finish()
                    return
                }
                // Ignore metadata messages
                
            @unknown default:
                break
            }
        }
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
    
    /// 사용 가능한 음성 목록 가져오기
    public static func fetchVoices() async throws -> [Voice] {
        let urlString = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=\(trustedClientToken)"
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([Voice].self, from: data)
    }
    
    /// 특정 언어의 음성 목록
    public static func fetchVoices(locale: String) async throws -> [Voice] {
        let all = try await fetchVoices()
        return all.filter { $0.locale.hasPrefix(locale) }
    }
    
    // MARK: - DRM Token
    
    private static func generateSecMsGecToken() -> String {
        let currentTime = Int64(Date().timeIntervalSince1970)
        let ticks = (currentTime + windowsFileTimeEpoch) * 10_000_000
        let roundedTicks = ticks - (ticks % 3_000_000_000)
        
        let strToHash = "\(roundedTicks)\(trustedClientToken)"
        guard let data = strToHash.data(using: .ascii) else { return "" }
        
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02X", $0) }.joined()
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
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Edge TTS WebSocket URL"
        case .connectionFailed(let msg):
            return "Edge TTS connection failed: \(msg)"
        case .synthesisTimeout:
            return "Edge TTS synthesis timed out"
        }
    }
}
