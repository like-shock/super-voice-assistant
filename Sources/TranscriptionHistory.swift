import Foundation
import Logging
import SharedModels
import SharedModels

private let logger = AppLogger.make("History")

struct TranscriptionEntry: Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    
    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
    }
}

class TranscriptionHistory {
    static let shared = TranscriptionHistory()
    private let maxEntries = 100
    private var entries: [TranscriptionEntry] = []
    
    private var historyFileURL: URL {
        let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSupportDir = appSupportBase.appendingPathComponent("SuperVoiceAssistant", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        return appSupportDir.appendingPathComponent("transcription_history.json")
    }
    
    private init() {
        migrateFromDocuments()
        loadHistory()
    }
    
    /// ~/Documents/SuperVoiceAssistant/ → ~/Library/Application Support/SuperVoiceAssistant/ 마이그레이션
    private func migrateFromDocuments() {
        let fm = FileManager.default
        let oldDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SuperVoiceAssistant")
        let oldFile = oldDir.appendingPathComponent("transcription_history.json")
        guard fm.fileExists(atPath: oldFile.path), !fm.fileExists(atPath: historyFileURL.path) else { return }
        do {
            try fm.moveItem(at: oldFile, to: historyFileURL)
            logger.info("Migrated history from Documents to Application Support")
        } catch {
            logger.warning("History migration failed: \(error)")
        }
    }
    
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else {
            logger.info("No history file found")
            return
        }
        
        do {
            let data = try Data(contentsOf: historyFileURL)
            entries = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            logger.info("Loaded \(entries.count) history entries")
        } catch {
            logger.info("Failed to load history: \(error)")
        }
    }
    
    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL)
        } catch {
            logger.info("Failed to save history: \(error)")
        }
    }
    
    func addEntry(_ text: String) {
        let entry = TranscriptionEntry(text: text)
        entries.insert(entry, at: 0) // Add at beginning for most recent first
        
        // Limit entries
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        
        saveHistory()
        
        // Update stats
        TranscriptionStats.shared.incrementTranscriptionCount()
        
        logger.info("Added transcription to history: \(text)")
    }
    
    func getEntries() -> [TranscriptionEntry] {
        return entries
    }
    
    func clearHistory() {
        entries.removeAll()
        saveHistory()
    }
    
    func deleteEntry(at index: Int) {
        guard index >= 0 && index < entries.count else { return }
        entries.remove(at: index)
        saveHistory()
    }
}