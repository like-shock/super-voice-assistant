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

### TTS Engine (Pluggable: Gemini / Supertonic)

**Status**: ✅ Complete — dual engine support with TTSAudioProvider protocol
**Key Files**:
- `SharedSources/TTSProvider.swift` - TTSAudioProvider protocol + TTSEngine enum
- `SharedSources/GeminiStreamingPlayer.swift` - Streaming TTS playback engine (shared by all engines)
- `SharedSources/GeminiAudioCollector.swift` - Gemini Live WebSocket TTS (cloud)
- `SharedSources/SupertonicEngine.swift` - Supertonic native TTS engine (local, ONNX Runtime)
- `SharedSources/SupertonicCore.swift` - Supertonic ONNX inference core (from supertone-inc/supertonic)
- `SharedSources/SmartSentenceSplitter.swift` - Text processing for optimal speech
- `Sources/TTSSettingsView.swift` - TTS engine selection UI

**Architecture**:
- `TTSAudioProvider` protocol abstracts TTS engines → `AsyncThrowingStream<Data, Error>`
- `GeminiAudioCollector` (cloud, 24kHz) and `SupertonicEngine` (local, 44.1kHz) both conform
- `GeminiStreamingPlayer` accepts any provider, sample rate is configurable
- Engine selection persisted via UserDefaults (`ttsEngine` key)
- Engine switching via Settings UI or programmatic `switchTTSEngine(to:)`

**Supertonic (Local)**:
- Swift-native ONNX Runtime inference, zero Python dependency
- 66M parameter model, ~160ms per sentence on M1
- Korean, English, Spanish, Portuguese, French support
- 10 voice styles (M1-M5, F1-F5) with configurable speed
- Models at `~/Library/Application Support/SuperVoiceAssistant/models/supertonic/`
- Auto-migrated from `~/.cache/supertonic2/` (pip package path) on first launch

**Features**:
- ✅ Cmd+Opt+S keyboard shortcut for reading selected text aloud
- ✅ Dual engine: Gemini (cloud) or Supertonic (local/offline)
- ✅ Settings UI for engine selection, voice style, language, speed
- ✅ Sequential streaming for smooth, natural speech with minimal latency
- ✅ Smart sentence splitting for optimal speech flow
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

### Keyboard Shortcuts

- **Cmd+Opt+Z**: WhisperKit/Parakeet audio recording (offline)
- **Cmd+Opt+X**: Gemini audio recording (cloud)
- **Cmd+Opt+S**: Text-to-speech / Cancel TTS playback
- **Cmd+Opt+C**: Screen recording with video transcription
- **Cmd+Opt+A**: Show transcription history
- **Cmd+Opt+V**: Paste last transcription at cursor
- **Escape**: Cancel recording
