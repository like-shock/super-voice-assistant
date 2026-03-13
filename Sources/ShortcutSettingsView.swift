import SwiftUI
import KeyboardShortcuts

struct ShortcutSettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Click a shortcut to record a new key combination")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // STT Shortcuts
                    GroupBox {
                        VStack(spacing: 12) {
                            shortcutRow(
                                label: "Audio Recording (toggle)",
                                name: .startRecording,
                                description: "WhisperKit / Parakeet"
                            )
                            Divider()
                            shortcutRow(
                                label: "Gemini Audio Recording",
                                name: .geminiAudioRecording,
                                description: "Cloud transcription"
                            )
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Speech-to-Text", systemImage: "mic.fill")
                            .font(.headline)
                    }

                    // TTS Shortcuts
                    GroupBox {
                        VStack(spacing: 12) {
                            shortcutRow(
                                label: "Read Selected Text",
                                name: .readSelectedText,
                                description: "TTS playback / Cancel"
                            )
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Text-to-Speech", systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                    }

                    // Utility Shortcuts
                    GroupBox {
                        VStack(spacing: 12) {
                            shortcutRow(
                                label: "Show History",
                                name: .showHistory,
                                description: "Transcription history window"
                            )
                            Divider()
                            shortcutRow(
                                label: "Paste Last Transcription",
                                name: .pasteLastTranscription,
                                description: "Insert at cursor position"
                            )
                            Divider()
                            shortcutRow(
                                label: "Screen Recording",
                                name: .toggleScreenRecording,
                                description: "Video capture & transcription"
                            )
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Utilities", systemImage: "command")
                            .font(.headline)
                    }

                    // Hold-to-record info (not configurable via Recorder)
                    GroupBox {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hold-to-Record")
                                    .fontWeight(.medium)
                                Text("Hold Command+Shift to record, release to stop")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("⌘⇧")
                                .font(.system(.body, design: .rounded))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Fixed Shortcuts", systemImage: "lock.fill")
                            .font(.headline)
                    }

                    // Reset button
                    Button(action: resetToDefaults) {
                        Label("Reset All to Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.link)
                    .padding(.top, 8)
                }
                .padding()
            }
        }
    }

    private func shortcutRow(label: String, name: KeyboardShortcuts.Name, description: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private func resetToDefaults() {
        KeyboardShortcuts.setShortcut(.init(.s, modifiers: [.command, .option]), for: .startRecording)
        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .option]), for: .geminiAudioRecording)
        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .option]), for: .showHistory)
        KeyboardShortcuts.setShortcut(.init(.z, modifiers: [.command, .option]), for: .readSelectedText)
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.command, .option]), for: .toggleScreenRecording)
        KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .option]), for: .pasteLastTranscription)
    }
}
