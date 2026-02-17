import Foundation

/// Common TTS engine interface
@available(macOS 14.0, *)
public protocol TTSAudioProvider {
    /// Convert text to a stream of PCM audio chunks
    /// - Returns: AsyncThrowingStream of raw PCM Data (16-bit, mono)
    func collectAudioChunks(from text: String) -> AsyncThrowingStream<Data, Error>
    
    /// Audio sample rate
    var sampleRate: Double { get }
}

public enum TTSEngine: String, CaseIterable {
    case gemini = "Gemini (Cloud)"
    case supertonic = "Supertonic (Local)"
    case edge = "Edge TTS (Cloud/Free)"
    
    public var displayName: String { rawValue }
    
    public var requiresAPIKey: Bool {
        switch self {
        case .gemini: return true
        case .supertonic, .edge: return false
        }
    }
}
