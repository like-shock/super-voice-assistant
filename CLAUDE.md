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

**Architecture**:
- `TTSAudioProvider` protocol abstracts TTS engines → `AsyncThrowingStream<Data, Error>`
- `GeminiAudioCollector` (cloud, 24kHz) and `SupertonicEngine` (local, 44.1kHz) both conform
- `GeminiStreamingPlayer` accepts any provider, sample rate is configurable
- Engine selection persisted via UserDefaults (`ttsEngine` key)

**Supertonic (Local)**:
- Swift-native ONNX Runtime inference, zero Python dependency
- 66M parameter model, ~160ms per sentence on M1
- Korean, English, Spanish, Portuguese, French support
- 10 voice styles (M1-M5, F1-F5)
- Models at `~/.cache/supertonic2/` (shared with pip package)
- First run requires model download (~305MB from HuggingFace)

**Features**:
- ✅ Cmd+Opt+S keyboard shortcut for reading selected text aloud
- ✅ Dual engine: Gemini (cloud) or Supertonic (local/offline)
- ✅ Sequential streaming for smooth, natural speech with minimal latency
- ✅ Smart sentence splitting for optimal speech flow
- ✅ Automatic fallback to Supertonic when GEMINI_API_KEY is missing

### Gemini Audio Transcription

**Status**: ✅ Complete and integrated into main app
**Branch**: `gemini-audio-feature`
**Key Files**:
- `SharedSources/GeminiAudioTranscriber.swift` - Gemini API audio transcription
- `Sources/GeminiAudioRecordingManager.swift` - Audio recording manager for Gemini

**Features**:
- ✅ Cmd+Opt+X keyboard shortcut for Gemini audio recording and transcription
- ✅ Cloud-based transcription using Gemini 2.5 Flash API
- ✅ WAV audio conversion and base64 encoding
- ✅ Silence detection and automatic filtering
- ✅ Mutual exclusion with WhisperKit recording and screen recording
- ✅ Transcription history integration

**Keyboard Shortcuts**:
- **Cmd+Opt+Z**: WhisperKit audio recording (offline)
- **Cmd+Opt+X**: Gemini audio recording (cloud)
- **Cmd+Opt+S**: Text-to-speech with Gemini
- **Cmd+Opt+C**: Screen recording with video transcription
- **Cmd+Opt+A**: Show transcription history
- **Cmd+Opt+V**: Paste last transcription at cursor

