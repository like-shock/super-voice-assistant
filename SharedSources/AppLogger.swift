import Foundation
import Logging
import Puppy

/// 앱 전역 로거 설정
/// 사용: `let logger = AppLogger.make("EdgeTTS")`
public enum AppLogger {
    private static var isBootstrapped = false
    
    /// 초기화 — 앱 시작 시 1회 호출
    public static func bootstrap() {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        
        // Puppy console logger
        let console = ConsoleLogger("com.likeshock.SuperVoiceAssistant.console",
                                     logFormat: AppLogFormatter())
        
        var puppy = Puppy()
        puppy.add(console)
        
        // swift-log 백엔드로 Puppy 등록
        LoggingSystem.bootstrap { label in
            var handler = PuppyLogHandler(label: label, puppy: puppy)
            handler.logLevel = Self.defaultLogLevel
            return handler
        }
    }
    
    /// 카테고리별 Logger 생성
    public static func make(_ category: String) -> Logger {
        bootstrap()  // 자동 초기화
        return Logger(label: category)
    }
    
    /// 환경변수 LOG_LEVEL로 기본 레벨 설정 (기본: info)
    private static var defaultLogLevel: Logger.Level {
        if let env = ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() {
            switch env {
            case "trace": return .trace
            case "debug": return .debug
            case "info": return .info
            case "warning", "warn": return .warning
            case "error": return .error
            default: return .info
            }
        }
        return .info
    }
}

// MARK: - Custom Log Formatter

struct AppLogFormatter: LogFormattable {
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    
    func formatMessage(
        _ level: LogLevel,
        message: String,
        tag: String,
        function: String,
        file: String,
        line: UInt,
        swiftLogInfo: [String: String],
        label: String,
        date: Date,
        threadID: UInt64
    ) -> String {
        let time = dateFormatter.string(from: date)
        let lvl = levelString(level)
        let category = swiftLogInfo["label"] ?? label
        return "\(time) \(lvl) [\(category)] \(message)"
    }
    
    private func levelString(_ level: LogLevel) -> String {
        switch level {
        case .trace:    return "[TRACE]"
        case .verbose:  return "[VERB]"
        case .debug:    return "[DEBUG]"
        case .info:     return "[INFO]"
        case .notice:   return "[NOTE]"
        case .warning:  return "[WARN]"
        case .error:    return "[ERROR]"
        case .critical: return "[CRIT]"
        }
    }
}
