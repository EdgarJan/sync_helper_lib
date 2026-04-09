import Foundation

public enum SyncError: Error, LocalizedError {
    case notInitialized
    case notAuthenticated
    case noUser
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .notInitialized: "Database not initialized"
        case .notAuthenticated: "User not authenticated with Firebase"
        case .noUser: "No user logged in"
        case .httpError(let code): "HTTP error: \(code)"
        }
    }
}
