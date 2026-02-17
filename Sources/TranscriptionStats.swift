import Foundation
import Logging
import SharedModels
import SharedModels

private let logger = AppLogger.make("Stats")

class TranscriptionStats {
    static let shared = TranscriptionStats()
    private var totalTranscriptions: Int = 0
    
    private var statsFileURL: URL {
        let appSupportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSupportDir = appSupportBase.appendingPathComponent("SuperVoiceAssistant", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        return appSupportDir.appendingPathComponent("transcription_stats.json")
    }
    
    private init() {
        migrateFromDocuments()
        loadStats()
    }
    
    private func migrateFromDocuments() {
        let fm = FileManager.default
        let oldFile = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SuperVoiceAssistant")
            .appendingPathComponent("transcription_stats.json")
        guard fm.fileExists(atPath: oldFile.path), !fm.fileExists(atPath: statsFileURL.path) else { return }
        do {
            try fm.moveItem(at: oldFile, to: statsFileURL)
            logger.info("Migrated stats from Documents to Application Support")
        } catch {
            logger.warning("Stats migration failed: \(error)")
        }
    }
    
    private func loadStats() {
        guard FileManager.default.fileExists(atPath: statsFileURL.path) else {
            logger.info("No stats file found, starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: statsFileURL)
            if let stats = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let count = stats["totalTranscriptions"] as? Int {
                totalTranscriptions = count
                logger.info("Loaded stats: \(totalTranscriptions) total transcriptions")
            }
        } catch {
            logger.info("Failed to load stats: \(error)")
        }
    }
    
    private func saveStats() {
        do {
            let stats: [String: Any] = ["totalTranscriptions": totalTranscriptions]
            let data = try JSONSerialization.data(withJSONObject: stats, options: .prettyPrinted)
            try data.write(to: statsFileURL)
        } catch {
            logger.info("Failed to save stats: \(error)")
        }
    }
    
    func incrementTranscriptionCount() {
        totalTranscriptions += 1
        saveStats()
        logger.info("Total transcriptions: \(totalTranscriptions)")
    }
    
    func getTotalTranscriptions() -> Int {
        return totalTranscriptions
    }
}