import GRDB

public protocol SyncConstants: Sendable {
    var appId: String { get }
    var serverUrl: String { get }
}

public protocol SyncMigrations: Sendable {
    func migrate(_ db: Database) throws
}

public protocol SyncMetaEntity: Sendable {
    /// e.g. ["tasks": "id,lts,is_unsynced,name,priority"]
    var syncableColumnsString: [String: String] { get }
    /// e.g. ["tasks": ["id", "lts", "is_unsynced", "name", "priority"]]
    var syncableColumnsList: [String: [String]] { get }
}
