# Super Voice Assistant

macOS voice assistant with global hotkeys — transcribe speech to text with offline models (WhisperKit or Parakeet) or cloud-based Gemini API, capture and transcribe screen recordings with visual context, and read selected text aloud with Supertonic (local), Edge TTS (cloud, free), or Gemini Live (cloud). Fast, accurate, and simple.

## Demo

**Parakeet transcription (fast and accurate):**

https://github.com/user-attachments/assets/163e6484-a3b1-49ef-b5e1-d9887d1f65d0

**Instant text-to-speech:**

https://github.com/user-attachments/assets/c961f0c6-f3b3-49d9-9b42-7a7d93ee6bc8

**Visual disambiguation for names:**

https://github.com/user-attachments/assets/0b7f481f-4fec-4811-87ef-13737e0efac4

## Features

**Voice-to-Text Transcription**
- Press Command+Option+Z for local offline transcription (WhisperKit or Parakeet)
- Press Command+Option+X for cloud transcription with Gemini API
- Choose your engine in Settings: WhisperKit models or Parakeet (faster, more accurate)
- Automatic text pasting at cursor position
- Transcription history with Command+Option+A

**Streaming Text-to-Speech**
- Press Command+Option+S to read selected text aloud
- Press Command+Option+S again while reading to instantly cancel playback
- **Triple engine support:**
  - **Supertonic (Local)** — offline, no API key, ~160ms/sentence on Apple Silicon via ONNX Runtime
  - **Edge TTS (Cloud)** — free, no API key, high-quality Microsoft neural voices
  - **Gemini Live (Cloud)** — streaming WebSocket, requires GEMINI_API_KEY
- **Smart text processing** — short lines merged to reduce synthesis overhead; paragraph boundaries and headings preserved for natural reading flow
- **Prefetch pipeline** (Edge TTS) — next sentence synthesized during current playback for near-zero gaps
- Korean, English, and more languages supported
- Multiple voice styles per engine with configurable speed
- Engine selection in Settings UI
- Automatic fallback to Supertonic when Gemini API key is not available

**Screen Recording & Video Transcription**
- Press Command+Option+C to start/stop screen recording
- Automatic video transcription using Gemini 2.5 Flash API with visual context
- Better accuracy for programming terms, code, technical jargon, and ambiguous words
- Transcribed text automatically pastes at cursor position

## Requirements

- macOS 14.0 or later
- Xcode 15+ or Xcode Command Line Tools (for Swift 5.9+)
- Gemini API key (optional — needed for cloud TTS/STT and video transcription; local engines work without it)
- ffmpeg (for screen recording functionality)

## System Permissions Setup

This app requires specific system permissions to function properly:

### 1. Microphone Access
The app will automatically request microphone permission on first launch. If denied, grant it manually:
- Go to **System Settings > Privacy & Security > Microphone**
- Enable access for **Super Voice Assistant**

### 2. Accessibility Access (Required for Global Hotkeys & Auto-Paste)
You must manually grant accessibility permissions for the app to:
- Monitor global keyboard shortcuts (Command+Option+Z/S/X/A/V/C, Escape)
- Automatically paste transcribed text at cursor position

**To enable:**
1. Go to **System Settings > Privacy & Security > Accessibility**
2. Click the lock icon to make changes (enter your password)
3. Click the **+** button to add an application
4. Navigate to the app location:
   - If running via `swift run`: Add **Terminal** or your terminal app (iTerm2, etc.)
   - If running the built binary directly: Add the **SuperVoiceAssistant** executable
5. Ensure the checkbox next to the app is checked

### 3. Screen Recording Access (Required for Video Transcription)
The app requires screen recording permission to capture screen content:
- Go to **System Settings > Privacy & Security > Screen Recording**
- Enable access for **Terminal** (if running via `swift run`) or **SuperVoiceAssistant**

## Installation & Running

```bash
# Clone the repository
git clone https://github.com/yourusername/super-voice-assistant.git
cd super-voice-assistant

# Install ffmpeg (required for screen recording)
brew install ffmpeg

# Set up environment (for cloud TTS and video transcription)
cp .env.example .env
# Edit .env and add your GEMINI_API_KEY

# Build the app
swift build

# Run the main app
swift run SuperVoiceAssistant
```

The app will appear in your menu bar as a waveform icon.

## Model Storage

All models are stored in `~/Library/Application Support/`:

| Engine | Path | Size |
|--------|------|------|
| WhisperKit | `~/Library/Application Support/SuperVoiceAssistant/models/whisperkit/` | ~300MB–1.6GB per model |
| Supertonic TTS | `~/Library/Application Support/SuperVoiceAssistant/models/supertonic/` | ~305MB |
| Parakeet | `~/Library/Application Support/FluidAudio/Models/` | ~600MB per version |

Models are automatically downloaded on first use. Legacy paths (`~/Documents/huggingface/`, `~/.cache/supertonic2/`) are auto-migrated on app launch.

## Configuration

### Text Replacements

You can configure automatic text replacements for transcriptions by editing `config.json` in the project root:

```json
{
  "textReplacements": {
    "Cloud Code": "Claude Code",
    "cloud code": "claude code",
    "cloud.md": "CLAUDE.md"
  }
}
```

This is useful for correcting common speech-to-text misrecognitions, especially for proper nouns, brand names, or technical terms. Replacements are case-sensitive and applied to all transcriptions.

## Usage

### Voice-to-Text Transcription

**Local (Cmd+Option+Z):**
1. Launch the app — it appears in the menu bar
2. Open Settings to select and download a model (Parakeet or WhisperKit)
3. Press **Command+Option+Z** to start recording
4. Press **Command+Option+Z** again to stop and transcribe
5. Text automatically pastes at cursor
6. Press **Escape** to cancel

**Cloud (Cmd+Option+X):**
1. Set GEMINI_API_KEY in your .env file
2. Press **Command+Option+X** to start/stop recording
3. Text automatically pastes at cursor

**Transcription engines:**
- **Parakeet v2**: ~110x realtime, 1.69% WER, English — recommended for speed
- **Parakeet v3**: ~210x realtime, 1.8% WER, 25 languages
- **WhisperKit**: Various model sizes, good accuracy, more language options
- **Gemini**: Cloud-based, best for complex audio, requires internet

### Text-to-Speech
1. Select any text in any application
2. Press **Command+Option+S** to read the selected text aloud
3. Press **Command+Option+S** again while reading to cancel the operation
4. Default engine: **Supertonic** (local, no API key needed), **Edge TTS** (cloud, free), or **Gemini Live** (cloud)
5. Configure engine, voice, language, and speed in Settings → Text-to-Speech
6. Configure audio output device in Settings for optimal playback

### Screen Recording & Video Transcription
1. Press **Command+Option+C** to start screen recording
2. The menu bar shows "🎥 REC" while recording
3. Press **Command+Option+C** again to stop recording
4. The app automatically transcribes the video using Gemini 2.5 Flash
5. Visual context improves accuracy for code, technical terms, and homophones
6. Transcribed text pastes at your cursor position
7. Video file is automatically deleted after successful transcription

**Note:** Audio recording and screen recording are mutually exclusive — you cannot run both simultaneously.

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **Cmd+Opt+Z** | Start/stop audio recording (WhisperKit/Parakeet — offline) |
| **Cmd+Opt+X** | Start/stop audio recording (Gemini — cloud) |
| **Cmd+Opt+S** | Read selected text aloud / Cancel TTS playback |
| **Cmd+Opt+C** | Start/stop screen recording and transcribe |
| **Cmd+Opt+A** | Show transcription history window |
| **Cmd+Opt+V** | Paste last transcription at cursor |
| **Escape** | Cancel audio recording |

## Available Commands

```bash
# Run the main app
swift run SuperVoiceAssistant

# Run with debug logging
LOG_LEVEL=debug swift run SuperVoiceAssistant

# List all available WhisperKit models
swift run ListModels

# Test downloading a model
swift run TestDownload

# Validate downloaded models are complete
swift run ValidateModels

# Delete all downloaded models
swift run DeleteModels

# Delete a specific model
swift run DeleteModel <model-name>

# Test transcription with a sample audio file
swift run TestTranscription

# Test live transcription with microphone input
swift run TestLiveTranscription

# Test streaming TTS functionality
swift run TestStreamingTTS

# Test audio collection for TTS
swift run TestAudioCollector

# Test sentence splitting for TTS
swift run TestSentenceSplitter

# Test TTS engines (Edge TTS / Supertonic)
swift run TestTTSEngines edge "테스트 문장"
swift run TestTTSEngines supertonic "테스트 문장"

# Test screen recording (3-second capture)
swift run RecordScreen

# Test video transcription with Gemini API
swift run TranscribeVideo <path-to-video-file>
```

## Project Structure

```
Sources/                          # Main app code
├── main.swift                    # App entry, keyboard shortcuts, TTS engine management
├── ModelStateManager.swift       # STT engine/model selection + lifecycle
├── AudioTranscriptionManager.swift  # Audio recording + transcription routing
├── GeminiAudioRecordingManager.swift # Gemini cloud recording
├── SettingsWindow.swift          # Unified settings UI
├── TTSSettingsView.swift         # TTS engine selection UI
├── ScreenRecorder.swift          # Screen recording via ffmpeg
├── WhisperModelDownloader.swift  # WhisperKit model download management
└── ...

SharedSources/                    # Shared components (no AppKit dependency)
├── AppLogger.swift               # Structured logging (swift-log + Puppy)
├── TTSProvider.swift             # TTSAudioProvider protocol + TTSEngine enum
├── SupertonicEngine.swift        # Supertonic local TTS (ONNX Runtime)
├── SupertonicCore.swift          # Supertonic ONNX inference core
├── GeminiStreamingPlayer.swift   # Streaming TTS playback (all engines)
├── EdgeTTSEngine.swift           # Edge TTS (free cloud, Starscream WebSocket)
├── GeminiAudioCollector.swift    # Gemini Live WebSocket TTS
├── GeminiAudioTranscriber.swift  # Gemini API transcription
├── ParakeetTranscriber.swift     # FluidAudio Parakeet wrapper
├── WhisperModelManager.swift     # WhisperKit model path + migration
├── SmartSentenceSplitter.swift   # Text splitting + short chunk merging for TTS
├── VideoTranscriber.swift        # Gemini API video transcription
└── ...

tests/                            # Test utilities
tools/                            # Model management utilities
```

## License

See [LICENSE](LICENSE) for details.
