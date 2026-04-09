import Foundation
import GRDB
import FirebaseAuth
import os

/// Offline-first sync engine for iOS and macOS.
///
/// Access from MainActor for thread safety (same as Flutter's ChangeNotifier).
/// All async methods suspend — they never block the calling thread.
@Observable
public final class SyncBackend {

    // MARK: - Configuration

    private let constants: any SyncConstants
    private let migrations: any SyncMigrations
    private let meta: any SyncMetaEntity

    // MARK: - Database

    private var dbPool: DatabasePool?

    // MARK: - SSE

    private var sseTask: Task<Void, Never>?
    private let sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Sync Coordination (thread-safe via lock)

    private let syncLock = OSAllocatedUnfairLock(initialState: (started: false, needsRepeat: false))

    // MARK: - Observable State

    public private(set) var isInitialized = false
    public private(set) var sseConnected = false
    public private(set) var isSyncing = false
    public private(set) var initialSyncCompleted = false
    public private(set) var syncError: String?
    public private(set) var userId: String?

    // MARK: - Init

    public init(constants: any SyncConstants, migrations: any SyncMigrations, meta: any SyncMetaEntity) {
        self.constants = constants
        self.migrations = migrations
        self.meta = meta
    }

    // MARK: - Auth

    private func getAuthToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw SyncError.notAuthenticated
        }
        return try await user.getIDToken()
    }

    // MARK: - Database Lifecycle

    public func initDb(userId: String) async throws {
        self.userId = userId
        self.initialSyncCompleted = false

        let path = try getDatabasePath(userId: userId)
        let pool = try DatabasePool(path: path)

        try await pool.write { [migrations] db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS syncing_table (
                    entity_name TEXT PRIMARY KEY,
                    last_received_lts INTEGER
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS archive (
                    id TEXT PRIMARY KEY,
                    lts INTEGER,
                    is_unsynced INTEGER,
                    table_name TEXT,
                    data TEXT,
                    data_id TEXT
                )
            """)
            try migrations.migrate(db)
        }

        self.dbPool = pool
        self.isInitialized = true

        try await registerTable("archive")

        sseTask = Task { [weak self] in
            await self?.sseLoop()
        }
    }

    public func deinitDb() async {
        sseTask?.cancel()
        sseTask = nil
        sseConnected = false
        initialSyncCompleted = false

        if let dbPool {
            try? dbPool.close()
        }
        dbPool = nil
        isInitialized = false
    }

    public func recreateDatabase() async throws {
        guard let savedUserId = userId else {
            throw SyncError.noUser
        }

        await deinitDb()

        let path = try getDatabasePath(userId: savedUserId)
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let filePath = path + suffix
            if fm.fileExists(atPath: filePath) {
                try fm.removeItem(atPath: filePath)
                SyncLogger.info("Deleted database file", context: ["path": filePath])
            }
        }

        syncError = nil
        try await initDb(userId: savedUserId)
        SyncLogger.info("Database recreated successfully")
    }

    // MARK: - Database Path

    private func getDatabasePath(userId: String) throws -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown_app"
        let dir = appSupport
            .appendingPathComponent(bundleId)
            .appendingPathComponent(userId)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("helper_sync.db").path
    }

    // MARK: - Table Registration

    private func registerTable(_ tableName: String) async throws {
        guard let dbPool else { return }

        let existing = try await dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT last_received_lts FROM syncing_table WHERE entity_name = ?",
                             arguments: [tableName])
        }
        if existing != nil { return }

        var latestLts: Int?
        var retries = 3

        while retries > 0 && latestLts == nil {
            do {
                let token = try await getAuthToken()
                var components = URLComponents(string: "\(constants.serverUrl)/latest-lts")!
                components.queryItems = [
                    URLQueryItem(name: "name", value: tableName),
                    URLQueryItem(name: "app_id", value: constants.appId),
                ]

                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                if statusCode == 200 {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    latestLts = json?["lts"] as? Int
                } else if statusCode == 403 || statusCode == 404 {
                    latestLts = 0
                } else {
                    throw SyncError.httpError(statusCode)
                }
            } catch {
                retries -= 1
                SyncLogger.warn("Failed to get latest LTS for \(tableName), retries left: \(retries)")
                if retries > 0 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        let ltsToUse = latestLts ?? 0
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO syncing_table (entity_name, last_received_lts) VALUES (?, ?)",
                arguments: [tableName, ltsToUse]
            )
        }
        SyncLogger.debug("Registered table \(tableName) with initial LTS \(ltsToUse)")
    }

    // MARK: - Read

    public func getAll(sql: String, parameters: [any DatabaseValueConvertible] = []) async throws -> [Row] {
        guard let dbPool else { throw SyncError.notInitialized }
        return try await dbPool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(parameters))
        }
    }

    public func watch(sql: String) -> AsyncThrowingStream<[Row], Error> {
        guard let pool = dbPool else {
            return AsyncThrowingStream { $0.finish(throwing: SyncError.notInitialized) }
        }

        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: sql)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await rows in observation.values(in: pool) {
                        continuation.yield(rows)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Write

    public func write(table: String, data: [String: (any DatabaseValueConvertible)?]) async throws {
        guard let dbPool else { throw SyncError.notInitialized }

        var dataToWrite = data
        if dataToWrite["id"] == nil {
            dataToWrite["id"] = UUID().uuidString
        }
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
        let allValues = values + values

        try await dbPool.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(allValues))
        }

        await fullSync()
    }

    public func writeBatch(table: String, dataList: [[String: (any DatabaseValueConvertible)?]]) async throws {
        guard let dbPool else { throw SyncError.notInitialized }
        if dataList.isEmpty { return }

        try await dbPool.write { db in
            for data in dataList {
                var dataToWrite = data

                if dataToWrite["id"] == nil {
                    dataToWrite["id"] = UUID().uuidString
                }
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
        }

        await fullSync()
    }

    public func writeTransaction(_ block: (SafeWriteTransaction) throws -> Void) async throws {
        guard let dbPool else { throw SyncError.notInitialized }

        try await dbPool.write { db in
            try block(SafeWriteTransaction(db: db))
        }

        await fullSync()
    }

    // MARK: - Delete

    public func delete(table: String, id: String) async throws {
        guard let dbPool else { throw SyncError.notInitialized }

        try await dbPool.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM \"\(table)\" WHERE id = ?", arguments: [id])

            if let row {
                let archiveId = UUID().uuidString
                let jsonData = try JSONSerialization.data(
                    withJSONObject: Self.rowToJsonDict(row, columns: Array(row.columnNames))
                )
                let archiveData = String(data: jsonData, encoding: .utf8) ?? "{}"

                try db.execute(
                    sql: "INSERT INTO archive (id, table_name, data, data_id, is_unsynced) VALUES (?, ?, ?, ?, 1)",
                    arguments: [archiveId, table, archiveData, id]
                )
            }

            try db.execute(sql: "DELETE FROM \"\(table)\" WHERE id = ?", arguments: [id])
        }

        await fullSync()
    }

    // MARK: - Full Sync

    public func fullSync() async {
        let shouldRun = syncLock.withLock { state -> Bool in
            if state.started {
                state.needsRepeat = true
                return false
            }
            state.started = true
            return true
        }
        guard shouldRun else { return }

        isSyncing = true
        SyncLogger.debug("Starting full sync")

        do {
            try await sendUnsynced()
            try await pullChanges()
        } catch {
            SyncLogger.error("Error during full sync", error: error)
        }

        isSyncing = false

        let shouldRepeat = syncLock.withLock { state -> Bool in
            state.started = false
            let r = state.needsRepeat
            state.needsRepeat = false
            return r
        }

        if shouldRepeat {
            SyncLogger.debug("Need to repeat full sync")
            await fullSync()
        }

        SyncLogger.debug("Full sync completed")
    }

    // MARK: - Push Phase

    private func sendUnsynced() async throws {
        guard let dbPool else { return }

        let tables = try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM syncing_table")
        }

        let batchSize = 100
        var retry: Bool

        repeat {
            retry = false

            for table in tables {
                let tableName: String = table["entity_name"]
                guard let columnsString = meta.syncableColumnsString[tableName] else { continue }
                guard let columnsList = meta.syncableColumnsList[tableName] else { continue }

                var offset = 0
                var hasMoreData = true

                while hasMoreData && !retry {
                    let rows = try await dbPool.read { db in
                        try Row.fetchAll(db,
                            sql: "SELECT \(columnsString) FROM \"\(tableName)\" WHERE is_unsynced = 1 LIMIT ? OFFSET ?",
                            arguments: [batchSize, offset])
                    }

                    if rows.isEmpty {
                        hasMoreData = false
                        continue
                    }

                    // Capture sent rows for data-change detection
                    let sentRows: [[String: DatabaseValue]] = rows.map { row in
                        var dict: [String: DatabaseValue] = [:]
                        for col in columnsList { dict[col] = row[col] }
                        return dict
                    }

                    let rowDicts = rows.map { Self.rowToJsonDict($0, columns: columnsList) }

                    let token = try await getAuthToken()
                    var components = URLComponents(string: "\(constants.serverUrl)/data")!
                    components.queryItems = [URLQueryItem(name: "app_id", value: constants.appId)]

                    let jsonString = String(
                        data: try JSONSerialization.data(withJSONObject: rowDicts),
                        encoding: .utf8
                    )!
                    let body: [String: Any] = ["name": tableName, "data": jsonString]

                    var request = URLRequest(url: components.url!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (responseData, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        retry = true
                        break
                    }

                    guard let responseJson = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                          let results = responseJson["results"] as? [[String: Any]] else {
                        retry = true
                        break
                    }

                    // Process results
                    let dataColumns = columnsList.filter { $0 != "is_unsynced" && $0 != "lts" && $0 != "id" }

                    try await dbPool.write { db in
                        for result in results {
                            guard let rowId = result["id"] as? String,
                                  let status = result["status"] as? String else { continue }

                            if status == "accepted" {
                                guard let newLts = result["lts"] as? Int else { continue }

                                // Find the row we originally sent
                                let sentRow = sentRows.first { ($0["id"]?.description) == rowId }

                                // Get current DB state
                                let currentRow = try Row.fetchOne(db,
                                    sql: "SELECT * FROM \"\(tableName)\" WHERE id = ?",
                                    arguments: [rowId])

                                // Check if data changed since we sent the batch
                                var dataChanged = false
                                if let sentRow, let currentRow {
                                    for col in dataColumns {
                                        let sent: DatabaseValue = sentRow[col] ?? .null
                                        let current: DatabaseValue = currentRow[col]
                                        if sent != current {
                                            dataChanged = true
                                            break
                                        }
                                    }
                                }

                                if dataChanged {
                                    // Data changed during sync — keep is_unsynced=1, only update lts
                                    try db.execute(
                                        sql: "UPDATE \"\(tableName)\" SET lts = ? WHERE id = ?",
                                        arguments: [newLts, rowId]
                                    )
                                } else {
                                    try db.execute(
                                        sql: "UPDATE \"\(tableName)\" SET is_unsynced = 0, lts = ? WHERE id = ?",
                                        arguments: [newLts, rowId]
                                    )
                                }

                            } else if status == "rejected" {
                                try db.execute(
                                    sql: "UPDATE \"\(tableName)\" SET is_unsynced = 0 WHERE id = ?",
                                    arguments: [rowId]
                                )
                                SyncLogger.warn("Row rejected by server", context: [
                                    "id": rowId,
                                    "table": tableName,
                                    "reason": result["reason"] as? String ?? "unknown",
                                ])
                            }
                        }
                    }

                    if rows.count < batchSize {
                        hasMoreData = false
                    } else {
                        offset += batchSize
                    }
                }

                if retry { break }
            }
        } while retry
    }

    // MARK: - Pull Phase

    private func pullChanges() async throws {
        guard let dbPool else { return }

        let tables = try await dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM syncing_table")
        }

        let pageSize = 1000

        for table in tables {
            let tableName: String = table["entity_name"]
            var lts: Int? = table["last_received_lts"]
            var more = true

            while more, self.dbPool != nil {
                let responseJson = try await fetchData(name: tableName, lastReceivedLts: lts, pageSize: pageSize)

                try await self.dbPool!.write { [meta] db in
                    // Check for unsynced rows — skip pull if the table has pending writes
                    let unsynced = try Row.fetchAll(db,
                        sql: "SELECT id FROM \"\(tableName)\" WHERE is_unsynced = 1")
                    if !unsynced.isEmpty {
                        more = false
                        self.syncLock.withLock { $0.needsRepeat = true }
                        return
                    }

                    guard let data = responseJson["data"] as? [[String: Any]], !data.isEmpty else {
                        more = false
                        return
                    }

                    if tableName == "archive" {
                        // Handle archive: delete referenced rows
                        for row in data {
                            guard let targetTable = row["table_name"] as? String,
                                  let targetId = row["data_id"] as? String else { continue }

                            try db.execute(sql: "DELETE FROM \"\(targetTable)\" WHERE id = ?", arguments: [targetId])

                            if let archiveRowId = row["id"] as? String {
                                try db.execute(sql: "DELETE FROM archive WHERE id = ?", arguments: [archiveRowId])
                            }
                        }

                        let lastLts = data.last?["lts"] as? Int ?? 0
                        try db.execute(
                            sql: "UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?",
                            arguments: [lastLts, tableName]
                        )
                    } else {
                        // Regular table: upsert rows
                        guard let cols = meta.syncableColumnsList[tableName] else {
                            more = false
                            return
                        }

                        let placeholders = cols.map { _ in "?" }.joined(separator: ", ")
                        let updates = cols.filter { $0 != "id" }
                            .map { "\($0) = excluded.\($0)" }
                            .joined(separator: ", ")
                        let sql = """
                            INSERT INTO "\(tableName)" (\(cols.joined(separator: ", ")))
                            VALUES (\(placeholders))
                            ON CONFLICT(id) DO UPDATE SET \(updates)
                        """

                        for row in data {
                            let values: [DatabaseValue] = cols.map { Self.jsonValueToDatabase(row[$0]) }
                            try db.execute(sql: sql, arguments: StatementArguments(values))
                        }

                        let lastLts = data.last?["lts"] as? Int ?? 0
                        try db.execute(
                            sql: "UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?",
                            arguments: [lastLts, tableName]
                        )
                    }

                    if data.count < pageSize {
                        more = false
                    } else {
                        lts = data.last?["lts"] as? Int
                    }
                }
            }
        }
    }

    private func fetchData(name: String, lastReceivedLts: Int?, pageSize: Int) async throws -> [String: Any] {
        var components = URLComponents(string: "\(constants.serverUrl)/data")!
        var queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "pageSize", value: "\(pageSize)"),
            URLQueryItem(name: "app_id", value: constants.appId),
        ]
        if let lts = lastReceivedLts {
            queryItems.append(URLQueryItem(name: "lts", value: "\(lts)"))
        }
        components.queryItems = queryItems

        let token = try await getAuthToken()
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.httpError(code)
        }

        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - LTS Validation

    private func validateLtsOnConnect() async {
        guard let dbPool else { return }

        do {
            let token = try await getAuthToken()
            var request = URLRequest(url: URL(string: "\(constants.serverUrl)/max-sequence-lts")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ltsValue = json?["lts"]
            let serverMaxLts: Int
            if let v = ltsValue as? Int {
                serverMaxLts = v
            } else if let s = ltsValue as? String, let v = Int(s) {
                serverMaxLts = v
            } else {
                return
            }

            // Check local max LTS from syncing_table
            let localResult = try await dbPool.read { db in
                try Row.fetchOne(db, sql: "SELECT MAX(last_received_lts) as max_lts FROM syncing_table")
            }
            let localMaxLts = (localResult?["max_lts"] as Int?) ?? 0

            // Check max LTS in data tables
            let tables = try await dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT entity_name FROM syncing_table")
            }
            var maxDataLts = 0
            for table in tables {
                let name: String = table["entity_name"]
                if name == "syncing_table" { continue }
                if let result = try? await dbPool.read({ db in
                    try Row.fetchOne(db, sql: "SELECT MAX(lts) as max_lts FROM \"\(name)\"")
                }) {
                    let tableLts = (result["max_lts"] as Int?) ?? 0
                    maxDataLts = max(maxDataLts, tableLts)
                }
            }

            let clientMaxLts = max(localMaxLts, maxDataLts)

            if clientMaxLts > serverMaxLts {
                SyncLogger.warn("Client LTS exceeds server", context: [
                    "clientMaxLts": clientMaxLts,
                    "serverMaxLts": serverMaxLts,
                ])
                syncError = "Local data is ahead of server (LTS: \(clientMaxLts) > \(serverMaxLts)). Database may need reset."
            } else {
                syncError = nil
            }
        } catch {
            SyncLogger.error("LTS validation failed", error: error)
        }
    }

    // MARK: - SSE

    private func sseLoop() async {
        while !Task.isCancelled {
            do {
                try await connectSSE()
            } catch is CancellationError {
                break
            } catch {
                SyncLogger.warn("SSE connection error, retrying in 5s", context: ["error": "\(error)"])
            }
            sseConnected = false
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                break
            }
        }
    }

    private func connectSSE() async throws {
        var components = URLComponents(string: "\(constants.serverUrl)/events")!
        components.queryItems = [URLQueryItem(name: "app_id", value: constants.appId)]

        let token = try await getAuthToken()
        var request = URLRequest(url: components.url!)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await sseSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.httpError(code)
        }

        sseConnected = true

        await validateLtsOnConnect()
        await fullSync()

        if !initialSyncCompleted {
            initialSyncCompleted = true
        }

        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                await fullSync()
            }
        }
    }

    // MARK: - Helpers

    static func rowToJsonDict(_ row: Row, columns: [String]) -> [String: Any] {
        var dict: [String: Any] = [:]
        for col in columns {
            let dbValue: DatabaseValue = row[col]
            switch dbValue.storage {
            case .null:
                dict[col] = NSNull()
            case .int64(let v):
                dict[col] = v
            case .double(let v):
                dict[col] = v
            case .string(let v):
                dict[col] = v
            case .blob(let v):
                dict[col] = v.base64EncodedString()
            }
        }
        return dict
    }

    static func jsonValueToDatabase(_ value: Any?) -> DatabaseValue {
        guard let value else { return .null }
        switch value {
        case is NSNull:
            return .null
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                return (v.boolValue ? 1 : 0).databaseValue
            }
            if v.doubleValue == Double(v.int64Value) {
                return v.int64Value.databaseValue
            }
            return v.doubleValue.databaseValue
        case let v as String:
            return v.databaseValue
        default:
            return .null
        }
    }
}
