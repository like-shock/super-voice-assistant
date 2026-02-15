import AVFoundation
import CryptoKit
import Foundation
import Starscream

/// Edge TTS 스트리밍 엔진 — Microsoft Edge의 무료 TTS WebSocket API
/// Starscream WebSocket으로 커스텀 헤더 완전 제어
/// API 키 불필요, 400+ 신경망 음성, raw PCM 24kHz 스트리밍
@available(macOS 14.0, *)
public class EdgeTTSEngine: TTSAudioProvider {
    public let sampleRate: Double = 24000
    
    private var voiceName: String
    private var rate: String
    private var pitch: String
    private var volume: String
    
    /// Retain active WebSocket handler to prevent ARC deallocation
    private var activeHandler: AnyObject?
    
    // Edge TTS constants
    private static let chromiumFullVersion = "143.0.3650.75"
    private static let chromiumMajorVersion = "143"
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
    
    // MARK: - WebSocket Streaming via Starscream
    
    private func streamSpeech(
        text: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let token = Self.generateSecMsGecToken()
        let connectionId = Self.generateConnectionId()
        let muid = Self.generateMUID()
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(Self.trustedClientToken)&ConnectionId=\(connectionId)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=1-\(Self.chromiumFullVersion)"
        
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromiumMajorVersion).0.0.0 Safari/537.36 Edg/\(Self.chromiumMajorVersion).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")
        
        let voiceName = self.voiceName
        let rate = self.rate
        let pitch = self.pitch
        let volume = self.volume
        let sampleRate = self.sampleRate
        
        try await withCheckedThrowingContinuation { (outer: CheckedContinuation<Void, Error>) in
            let handler = EdgeTTSWebSocketHandler(
                request: request,
                voiceName: voiceName,
                text: text,
                rate: rate,
                pitch: pitch,
                volume: volume,
                sampleRate: sampleRate,
                audioContinuation: continuation,
                completionContinuation: outer,
                onComplete: { [weak self] in
                    self?.activeHandler = nil
                }
            )
            self.activeHandler = handler
            handler.connect()
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
    
    /// 문장 단위로 분할 → 각 문장 WebSocket 합성 → mp3 직접 재생 (Supertonic과 동일 패턴)
    public func playText(_ text: String) async throws {
        let sentences = SmartSentenceSplitter.splitByLines(text)
        print("📖 [EdgeTTS] Split into \(sentences.count) sentences")
        
        for (index, sentence) in sentences.enumerated() {
            try Task.checkCancellation()
            
            let mp3Data = try await synthesizeToMP3(sentence)
            guard !mp3Data.isEmpty else { continue }
            
            print("🎵 [EdgeTTS] Sentence \(index+1)/\(sentences.count): \(mp3Data.count) mp3 bytes")
            try await Self.playMP3Data(mp3Data)
        }
    }
    
    /// 단일 텍스트 → mp3 Data (WebSocket 1회)
    private func synthesizeToMP3(_ text: String) async throws -> Data {
        var mp3Data = Data()
        let stream = collectAudioChunks(from: text)
        for try await chunk in stream {
            mp3Data.append(chunk)
        }
        return mp3Data
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
        let token = generateSecMsGecToken()
        let muid = generateMUID()
        let urlString = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=\(trustedClientToken)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=1-\(chromiumFullVersion)"
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromiumMajorVersion).0.0.0 Safari/537.36 Edg/\(chromiumMajorVersion).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(muid);", forHTTPHeaderField: "Cookie")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([Voice].self, from: data)
    }
    
    /// 특정 언어의 음성 목록
    public static func fetchVoices(locale: String) async throws -> [Voice] {
        let all = try await fetchVoices()
        return all.filter { $0.locale.hasPrefix(locale) }
    }
    
    // MARK: - DRM Token
    
    private static var clockSkewSeconds: Double = 0.0
    
    private static func generateSecMsGecToken() -> String {
        var ticks = Date().timeIntervalSince1970 + clockSkewSeconds
        ticks += Double(windowsFileTimeEpoch)
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        ticks *= 1e9 / 100
        
        let strToHash = String(format: "%.0f%@", ticks, trustedClientToken)
        guard let data = strToHash.data(using: .ascii) else { return "" }
        
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02X", $0) }.joined()
    }
    
    private static func generateMUID() -> String {
        (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }
    
    private static func generateConnectionId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    
    // MARK: - MP3 Direct Playback (macOS native)
    
    /// mp3 Data를 AVAudioPlayer로 직접 재생 (PCM 변환 불필요)
    public static func playMP3Data(_ mp3Data: Data) async throws {
        let player = try AVAudioPlayer(data: mp3Data)
        player.prepareToPlay()
        player.play()
        print("✅ [EdgeTTS] Playing \(String(format: "%.1f", player.duration))s via AVAudioPlayer")
        try await Task.sleep(nanoseconds: UInt64(player.duration * 1_000_000_000) + 200_000_000)
    }
}

// MARK: - Starscream WebSocket Handler

@available(macOS 14.0, *)
private class EdgeTTSWebSocketHandler: WebSocketDelegate {
    private var socket: WebSocket?
    private let voiceName: String
    private let text: String
    private let rate: String
    private let pitch: String
    private let volume: String
    private let sampleRate: Double
    private let audioContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var completionContinuation: CheckedContinuation<Void, Error>?
    private var totalBytes = 0
    private var completed = false
    private let onComplete: () -> Void
    private var mp3Buffer = Data()
    
    init(
        request: URLRequest,
        voiceName: String,
        text: String,
        rate: String,
        pitch: String,
        volume: String,
        sampleRate: Double,
        audioContinuation: AsyncThrowingStream<Data, Error>.Continuation,
        completionContinuation: CheckedContinuation<Void, Error>,
        onComplete: @escaping () -> Void
    ) {
        self.voiceName = voiceName
        self.text = text
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.sampleRate = sampleRate
        self.audioContinuation = audioContinuation
        self.completionContinuation = completionContinuation
        self.onComplete = onComplete
        self.socket = WebSocket(request: request)
        self.socket?.delegate = self
    }
    
    func connect() {
        socket?.connect()
    }
    
    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected(_):
            sendConfig()
            
        case .text(let str):
            if str.contains("Path:turn.end") {
                print("✅ [EdgeTTS] Received \(totalBytes) mp3 bytes")
                // Yield mp3 data as single chunk — caller handles playback
                audioContinuation.yield(mp3Buffer)
                finish(nil)
            }
            
        case .binary(let data):
            // Binary message — accumulate mp3 audio after "Path:audio\r\n" header
            let headerTag = "Path:audio\r\n"
            if let headerData = headerTag.data(using: .utf8),
               let range = data.range(of: headerData) {
                let audioData = data.suffix(from: range.upperBound)
                if !audioData.isEmpty {
                    mp3Buffer.append(contentsOf: audioData)
                    totalBytes += audioData.count
                }
            }
            
        case .error(let error):
            print("❌ [EdgeTTS] WebSocket error: \(String(describing: error))")
            finish(error ?? EdgeTTSError.connectionFailed("Unknown error"))
            
        case .cancelled:
            finish(EdgeTTSError.connectionFailed("WebSocket cancelled"))
            
        case .disconnected(let reason, let code):
            if !completed {
                print("⚠️ [EdgeTTS] Disconnected: \(reason) (code: \(code))")
                finish(EdgeTTSError.connectionFailed("Disconnected: \(reason)"))
            }
            
        default:
            break
        }
    }
    
    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT'Z"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }
    
    private func sendConfig() {
        // Send speech config — mp3 format (raw PCM rejected via Starscream)
        let configMessage = "X-Timestamp:\(Self.timestamp())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
        socket?.write(string: configMessage)
        
        // Send SSML
        let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        
        let ssml = "X-RequestId:\(requestId)\r\nX-Timestamp:\(Self.timestamp())\r\nContent-Type:application/ssml+xml\r\nPath:ssml\r\n\r\n<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xmlns:mstts=\"https://www.w3.org/2001/mstts\" xml:lang=\"ko-KR\"><voice name=\"\(voiceName)\"><prosody rate=\"\(rate)\" pitch=\"\(pitch)\" volume=\"\(volume)\">\(escapedText)</prosody></voice></speak>"
        socket?.write(string: ssml)
    }
    
    private func finish(_ error: Error?) {
        guard !completed else { return }
        completed = true
        socket?.disconnect()
        
        if let error = error {
            audioContinuation.finish(throwing: error)
            completionContinuation?.resume(throwing: error)
        } else {
            audioContinuation.finish()
            completionContinuation?.resume()
        }
        completionContinuation = nil
        onComplete()
    }
}

// MARK: - Popular Korean Voices

public extension EdgeTTSEngine {
    enum KoreanVoice: String, CaseIterable {
        case sunHi = "ko-KR-SunHiNeural"
        case inJoon = "ko-KR-InJoonNeural"
        case hyunsu = "ko-KR-HyunsuMultilingualNeural"
        
        public var displayName: String {
            switch self {
            case .sunHi: return "선히 (여성)"
            case .inJoon: return "인준 (남성)"
            case .hyunsu: return "현수 (남성/다국어)"
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
