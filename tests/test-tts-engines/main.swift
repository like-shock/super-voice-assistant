import Foundation
import SharedModels

@main
struct TestTTSEngines {
    static func main() async {
        let args = CommandLine.arguments
        let engine = args.count > 1 ? args[1] : "all"
        let testText = args.count > 2 ? args[2] : "안녕하세요, 음성 합성 테스트입니다."
        
        print("🧪 TTS Engine Test")
        print("📝 Text: \(testText)")
        print("---")
        
        switch engine {
        case "supertonic":
            await testSupertonic(text: testText)
        case "edge":
            await testEdgeTTS(text: testText)
        case "all":
            await testSupertonic(text: testText)
            print("\n---\n")
            await testEdgeTTS(text: testText)
        default:
            print("Usage: TestTTSEngines [supertonic|edge|all] [text]")
        }
    }
    
    static func testSupertonic(text: String) async {
        print("🔊 Testing Supertonic...")
        
        let engine = SupertonicEngine(voiceName: "M1", lang: "ko", speed: 1.05)
        do {
            try engine.load()
            print("✅ Supertonic model loaded")
        } catch {
            print("❌ Supertonic load failed: \(error)")
            return
        }
        
        let player = GeminiStreamingPlayer(sampleRate: 44100, playbackSpeed: 1.0)
        
        do {
            let stream = engine.collectAudioChunks(from: text)
            try await player.playAudioStream(stream)
            print("✅ Supertonic playback complete")
        } catch {
            print("❌ Supertonic playback failed: \(error)")
        }
        
        player.stopAudioEngine()
        engine.unload()
    }
    
    @available(macOS 14.0, *)
    static func testEdgeTTS(text: String) async {
        print("🌐 Testing Edge TTS...")
        
        let voices = ["ko-KR-SunHiNeural", "ko-KR-InJoonNeural", "ko-KR-HyunsuMultilingualNeural"]
        
        for voice in voices {
            print("\n🎤 Voice: \(voice)")
            let engine = EdgeTTSEngine(voiceName: voice)
            let player = GeminiStreamingPlayer(sampleRate: 24000, playbackSpeed: 1.0)
            
            do {
                let stream = engine.collectAudioChunks(from: text)
                try await player.playAudioStream(stream)
                print("✅ \(voice) playback complete")
            } catch {
                print("❌ \(voice) failed: \(error)")
            }
            
            player.stopAudioEngine()
            
            // Brief pause between voices
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
