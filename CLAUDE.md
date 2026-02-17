# Claude Development Notes for Super Voice Assistant

## Project Guidelines

- Follow the roadmap and tech choices outlined in README.md

## Background Process Management

- When developing and testing changes, run the app in background using: `swift build && swift run SuperVoiceAssistant` with `run_in_background: true`
- Keep the app running in background while the user tests functionality
- Only kill and restart the background instance when making code changes that require a fresh build
- Allow the user to continue using the running instance between agent sessions
- The user prefers to keep the app running for continuous testing

## Git Commit Guidelines

- Never include Claude attribution or Co-Author information in git commits
- Keep commit messages clean and professional without AI-related references

## Architecture Notes

### MainActor / CoreML Deadlock Prevention

**Critical**: `ModelStateManager` is `@MainActor`. CoreML model compilation internally dispatches to MainActor. If model loading awaits results on MainActor → **deadlock**.

Rules:
- `loadModel()` must be **fire-and-forget** (synchronous, starts `Task.detached`, returns immediately)
- **Never** `await task.value` for model loading tasks on MainActor
- State updates flow through `@Published` properties
- Startup model loading in `main.swift` uses `Task.detached` to avoid MainActor inheritance
- Supertonic ONNX Runtime loading also uses `Task.detached`

### Model Storage Paths

All models stored under `~/Library/Application Support/`:
- **WhisperKit**: `~/Library/Application Support/SuperVoiceAssistant/models/whisperkit/{model_name}/`
- **Supertonic**: `~/Library/Application Support/SuperVoiceAssistant/models/supertonic/` (onnx/, voice_styles/)
- **Parakeet**: `~/Library/Application Support/FluidAudio/Models/` (FluidAudio SDK default, cannot customize)

Auto-migration from legacy paths on first launch:
- WhisperKit: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` → Application Support
- Supertonic: `~/.cache/supertonic2/` → Application Support

## Completed Features

### TTS Engine (Pluggable: Gemini / Supertonic / Edge TTS)

**Status**: ✅ Complete — triple engine support with TTSAudioProvider protocol
**Key Files**:
- `SharedSources/TTSProvider.swift` - TTSAudioProvider protocol + TTSEngine enum
- `SharedSources/GeminiStreamingPlayer.swift` - Streaming TTS playback engine (shared by all engines)
- `SharedSources/GeminiAudioCollector.swift` - Gemini Live WebSocket TTS (cloud)
- `SharedSources/SupertonicEngine.swift` - Supertonic native TTS engine (local, ONNX Runtime)
- `SharedSources/SupertonicCore.swift` - Supertonic ONNX inference core (from supertone-inc/supertonic)
- `SharedSources/EdgeTTSEngine.swift` - Edge TTS engine (cloud, free, Starscream WebSocket)
- `SharedSources/SmartSentenceSplitter.swift` - Text processing for optimal speech
- `Sources/TTSSettingsView.swift` - TTS engine selection UI

**Architecture**:
- `TTSAudioProvider` protocol abstracts TTS engines → `AsyncThrowingStream<Data, Error>`
- `GeminiAudioCollector` (cloud, 24kHz), `SupertonicEngine` (local, 44.1kHz), and `EdgeTTSEngine` (cloud, MP3) all conform
- `GeminiStreamingPlayer` accepts any provider, sample rate is configurable
- Edge TTS returns MP3 data chunks → played directly via AVAudioPlayer (not PCM streaming)
- Engine selection persisted via UserDefaults (`ttsEngine` key)
- Engine switching via Settings UI or programmatic `switchTTSEngine(to:)`

**Supertonic (Local)**:
- Swift-native ONNX Runtime inference, zero Python dependency
- 66M parameter model, ~160ms per sentence on M1
- Korean, English, Spanish, Portuguese, French support
- 10 voice styles (M1-M5, F1-F5) with configurable speed
- Models at `~/Library/Application Support/SuperVoiceAssistant/models/supertonic/`
- Auto-migrated from `~/.cache/supertonic2/` (pip package path) on first launch

**Edge TTS (Cloud, Free)**:
- Microsoft Edge TTS via WebSocket (no API key required)
- Starscream WebSocket library for full header control (Apple URLSessionWebSocketTask drops Origin/Cookie)
- DRM token generation: SHA256 HMAC with 300s-rounded timestamp
- MP3 output format (`audio-24khz-48kbitrate-mono-mp3`), sentence-level streaming
- Korean voices: SunHi (여성), InJoon (남성), HyunsuMultilingual (남성/다국어)
- Direct MP3 playback via AVAudioPlayer per sentence
- Prefetch pipeline: next sentence synthesized during current playback (max 2 concurrent WebSocket connections)
- AVAudioPlayer retained in instance to prevent ARC deallocation, immediate stop on cancel

**Smart Text Processing (shared by Edge TTS & Supertonic)**:
- `SmartSentenceSplitter.mergeShortChunks()` combines short lines (min 20, max 80 chars) to reduce WebSocket/synthesis round-trips
- Paragraph boundaries (blank lines) block merging across sections
- Heading patterns (`A.`, `1.`, `#`, `-`, `•`) are never merged — emitted as standalone chunks
- Period auto-inserted between merged chunks for natural TTS pauses

**Notification API**:
- Uses deprecated `NSUserNotification` (not `UNUserNotificationCenter`)
- Reason: bare binary from `swift build` has no `.app` bundle → `UNUserNotificationCenter.current()` crashes with `bundleProxyForCurrentProcess is nil`
- See `docs/migrate-to-UNUserNotification.md` for future migration plan

**Features**:
- ✅ Cmd+Opt+S keyboard shortcut for reading selected text aloud
- ✅ Triple engine: Gemini (cloud) / Supertonic (local/offline) / Edge TTS (cloud, free)
- ✅ Settings UI for engine selection, voice style, language, speed
- ✅ Sequential streaming for smooth, natural speech with minimal latency
- ✅ Smart sentence splitting with short chunk merging for optimal speech flow
- ✅ Prefetch pipeline for Edge TTS (near-zero inter-sentence gap)
- ✅ Immediate playback stop on cancel (AVAudioPlayer.stop())
- ✅ Automatic fallback to Supertonic when GEMINI_API_KEY is missing

### STT Engines (WhisperKit / Parakeet / Gemini)

**Status**: ✅ Complete — three engines via ModelStateManager
**Key Files**:
- `Sources/AudioTranscriptionManager.swift` - Audio recording + transcription routing (WhisperKit/Parakeet)
- `Sources/GeminiAudioRecordingManager.swift` - Gemini cloud transcription recording
- `Sources/ModelStateManager.swift` - Engine selection + model lifecycle (fire-and-forget loading)
- `SharedSources/ParakeetTranscriber.swift` - FluidAudio Parakeet wrapper
- `SharedSources/GeminiAudioTranscriber.swift` - Gemini API transcription

**Features**:
- ✅ Cmd+Opt+Z: WhisperKit/Parakeet recording (offline)
- ✅ Cmd+Opt+X: Gemini audio recording (cloud)
- ✅ Multiple WhisperKit models (distil-large-v3, large-v3-turbo, large-v3)
- ✅ Parakeet v2/v3 support via FluidAudio SDK
- ✅ Mutual exclusion between recording modes

### Screen Recording & Video Transcription

**Status**: ✅ Complete
**Key Files**:
- `Sources/ScreenRecorder.swift` - Screen capture via ffmpeg
- `SharedSources/VideoTranscriber.swift` - Gemini API video transcription

### TTS Test Harness

**File**: `tests/test-tts-engines/main.swift` (SPM target: `TestTTSEngines`)
```bash
swift run TestTTSEngines edge "테스트 문장"
swift run TestTTSEngines supertonic "테스트 문장"
```

### Structured Logging

**Status**: ✅ Complete — swift-log + Puppy backend
**Key Files**:
- `SharedSources/AppLogger.swift` — `AppLogger.make("Category")` factory, Puppy console backend

**Architecture**:
- All `print()` replaced with categorized `Logger` instances via `AppLogger.make("Category")`
- Categories: App, Settings, ModelState, AudioTranscription, GeminiRecording, GeminiPlayer, GeminiCollector, EdgeTTS, EdgeTTS.WS, Supertonic, Parakeet, WhisperDownload, WhisperModel, ScreenRecorder, History, Stats, TextReplace, TTSSettings
- Log level controlled via `LOG_LEVEL` env var (trace/debug/info/warning/error, default: info)
- Format: `HH:mm:ss.SSS [LEVEL] [Category] message`
- Dependencies: `apple/swift-log`, `sushichop/Puppy`

### Codesign Setup (for ANE Cache)

CoreML ANE specialization cache keys depend on codesign identity. Ad-hoc signed SPM binaries get different cache keys per build → ANE re-specialization (~5min) every time.

**Solution**: Self-signed certificate "SuperVoiceAssistant Dev"
```bash
./setup-codesign.sh   # Creates cert in login keychain (one-time)
./build-and-run.sh    # Builds + signs + runs with stable identity
```
Config: `.codesign.env` (CERT_NAME, BINARY, BUNDLE_ID)

### Keyboard Shortcuts

- **Cmd+Opt+Z**: WhisperKit/Parakeet audio recording (offline)
- **Cmd+Opt+X**: Gemini audio recording (cloud)
- **Cmd+Opt+S**: Text-to-speech / Cancel TTS playback
- **Cmd+Opt+C**: Screen recording with video transcription
- **Cmd+Opt+A**: Show transcription history
- **Cmd+Opt+V**: Paste last transcription at cursor
- **Escape**: Cancel recording
