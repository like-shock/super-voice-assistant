import SwiftUI
import KeyboardShortcuts

/// Modifier combinations available for hold-to-record
enum HoldToRecordModifier: String, CaseIterable, Identifiable {
    case commandShift = "commandShift"
    case commandOption = "commandOption"
    case commandControl = "commandControl"
    case disabled = "disabled"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commandShift: return "⌘⇧ Command + Shift"
        case .commandOption: return "⌘⌥ Command + Option"
        case .commandControl: return "⌘⌃ Command + Control"
        case .disabled: return "Disabled"
        }
    }

    var flags: NSEvent.ModifierFlags? {
        switch self {
        case .commandShift: return [.command, .shift]
        case .commandOption: return [.command, .option]
        case .commandControl: return [.command, .control]
        case .disabled: return nil
        }
    }
}

struct ShortcutSettingsView: View {
    @AppStorage("holdToRecordModifier") private var holdModifier: String = HoldToRecordModifier.commandShift.rawValue

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
                            Divider()
                            holdToRecordRow()
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

    private func holdToRecordRow() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold-to-Record")
                    .fontWeight(.medium)
                Text("Hold to record, release to stop")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $holdModifier) {
                ForEach(HoldToRecordModifier.allCases) { mod in
                    Text(mod.label).tag(mod.rawValue)
                }
            }
            .frame(width: 220)
            .onChange(of: holdModifier) { _ in
                // Notify AppDelegate to re-setup hold-to-record monitor
                NotificationCenter.default.post(name: .holdToRecordModifierChanged, object: nil)
            }
        }
    }

    private func resetToDefaults() {
        KeyboardShortcuts.setShortcut(.init(.s, modifiers: [.command, .option]), for: .startRecording)
        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .option]), for: .geminiAudioRecording)
        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .option]), for: .showHistory)
        KeyboardShortcuts.setShortcut(.init(.z, modifiers: [.command, .option]), for: .readSelectedText)
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.command, .option]), for: .toggleScreenRecording)
        KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .option]), for: .pasteLastTranscription)
        holdModifier = HoldToRecordModifier.commandShift.rawValue
    }
}

extension Notification.Name {
    static let holdToRecordModifierChanged = Notification.Name("holdToRecordModifierChanged")
}
