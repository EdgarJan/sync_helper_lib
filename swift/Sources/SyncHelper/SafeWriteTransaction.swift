import Foundation
import GRDB

/// Wraps a GRDB Database context to protect sync-critical fields.
///
/// Automatically:
/// - Removes `lts` field (server-managed)
/// - Sets `is_unsynced = 1`
/// - Generates UUID for `id` if missing
public struct SafeWriteTransaction {
    let db: Database

    public func write(_ table: String, _ data: [String: (any DatabaseValueConvertible)?]) throws {
        var dataToWrite = data

        if dataToWrite["id"] == nil {
            dataToWrite["id"] = UUID().uuidString
        }

        // CRITICAL: lts is managed exclusively by the server
        dataToWrite.removeValue(forKey: "lts")

        let columns = Array(dataToWrite.keys)
        let values = columns.map { col -> DatabaseValue in
            guard let optValue = dataToWrite[col], let value = optValue else { return .null }
            return value.databaseValue
        }

        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let updateClauses = columns.map { "\($0) = ?" }.joined(separator: ", ")
        let sql = """
            INSERT INTO "\(table)" (\(columns.joined(separator: ", ")), is_unsynced)
            VALUES (\(placeholders), 1)
            ON CONFLICT(id) DO UPDATE SET \(updateClauses), is_unsynced = 1
        """

        try db.execute(sql: sql, arguments: StatementArguments(values + values))
    }

    public func execute(_ sql: String, _ parameters: [any DatabaseValueConvertible] = []) throws {
        try db.execute(sql: sql, arguments: StatementArguments(parameters))
    }

    public func getOptional(_ sql: String, _ parameters: [any DatabaseValueConvertible] = []) throws -> Row? {
        try Row.fetchOne(db, sql: sql, arguments: StatementArguments(parameters))
    }

    public func getAll(_ sql: String, _ parameters: [any DatabaseValueConvertible] = []) throws -> [Row] {
        try Row.fetchAll(db, sql: sql, arguments: StatementArguments(parameters))
    }
}
