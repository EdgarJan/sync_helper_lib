import Foundation
import Sentry

public enum SyncLogger {
    public static func debug(_ message: String, context: [String: Any]? = nil) {
        log(.debug, message, context: context)
    }

    public static func info(_ message: String, context: [String: Any]? = nil) {
        log(.info, message, context: context)
    }

    public static func warn(_ message: String, context: [String: Any]? = nil) {
        log(.warning, message, context: context)
    }

    public static func error(_ message: String, context: [String: Any]? = nil, error: Error? = nil) {
        log(.error, message, context: context)
        if let error {
            SentrySDK.capture(error: error)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func log(_ level: SentryLevel, _ message: String, context: [String: Any]?) {
        let timestamp = isoFormatter.string(from: Date())
        let levelStr: String = switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .fatal: "FATAL"
        @unknown default: "UNKNOWN"
        }

        var logLine = "[\(timestamp)] [\(levelStr)] \(message)"
        if let context, !context.isEmpty {
            let contextStr = context.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            logLine += " {\(contextStr)}"
        }

        let breadcrumb = Breadcrumb(level: level, category: "sync_helper")
        breadcrumb.message = message
        if let context {
            breadcrumb.data = context.mapValues { "\($0)" }
        }
        SentrySDK.addBreadcrumb(breadcrumb)

        #if DEBUG
        print(logLine)
        #endif
    }
}
