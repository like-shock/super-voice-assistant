import Foundation

/// TTS 엔진 공통 인터페이스
@available(macOS 14.0, *)
public protocol TTSAudioProvider {
    /// 텍스트를 PCM 오디오 청크 스트림으로 변환
    /// - Returns: AsyncThrowingStream of raw PCM Data (16-bit, mono)
    func collectAudioChunks(from text: String) -> AsyncThrowingStream<Data, Error>
    
    /// 오디오 샘플레이트
    var sampleRate: Double { get }
}

public enum TTSEngine: String, CaseIterable {
    case gemini = "Gemini (Cloud)"
    case supertonic = "Supertonic (Local)"
    
    public var displayName: String { rawValue }
    
    public var requiresAPIKey: Bool {
        switch self {
        case .gemini: return true
        case .supertonic: return false
        }
    }
}
