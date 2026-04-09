# Swift Sync Helper Library - Design Spec

## Overview

Rewrite of `sync_helper_flutter` as a Swift Package targeting iOS 15+ and macOS 12+. The library implements the same offline-first bidirectional sync protocol, same server API, same conflict resolution — just in Swift instead of Dart.

## Architecture

### Package Structure

```
swift/
├── Package.swift
├── Sources/
│   └── SyncHelper/
│       ├── SyncBackend.swift          # Core sync engine (@Observable)
│       ├── SyncProtocols.swift        # Public API contracts (protocols)
│       ├── SyncDatabase.swift         # GRDB database wrapper
│       ├── SyncHTTPClient.swift       # HTTP + SSE client
│       ├── SyncLogger.swift           # Structured logging (Sentry)
│       └── SafeWriteTransaction.swift # Write wrapper with field protection
└── Tests/
    └── SyncHelperTests/
        └── SyncHelperTests.swift
```

### Dependencies

| Dependency | Purpose | Flutter Equivalent |
|---|---|---|
| GRDB.swift | SQLite with reactive queries | sqlite_async |
| FirebaseAuth | Authentication tokens | firebase_auth |
| Sentry | Error tracking & logging | sentry_flutter |

URLSession, UUID, FileManager, JSONSerialization are all built-in — no extra packages needed for networking, IDs, paths, or JSON.

## Public API

### Protocols (equivalent to Flutter abstract classes)

```swift
protocol SyncConstants {
    var appId: String { get }
    var serverUrl: String { get }
}

protocol SyncMigrations {
    func migrate(_ db: GRDB.Database) throws
}

protocol SyncMetaEntity {
    /// e.g. ["tasks": "id,lts,is_unsynced,name,priority"]
    var syncableColumnsString: [String: String] { get }
    /// e.g. ["tasks": ["id", "lts", "is_unsynced", "name", "priority"]]
    var syncableColumnsList: [String: [String]] { get }
}
```

### SyncBackend (core engine)

```swift
@Observable
class SyncBackend {
    // Init
    init(constants: SyncConstants, migrations: SyncMigrations, meta: SyncMetaEntity)

    // Lifecycle
    func initDb(userId: String) async throws
    func deinitDb() async
    func recreateDatabase() async throws

    // Read
    func getAll(sql: String, parameters: [any DatabaseValueConvertible]) async throws -> [Row]
    func watch(sql: String, tables: [String]) -> AsyncStream<[Row]>

    // Write
    func write(table: String, data: [String: any DatabaseValueConvertible]) async throws
    func writeBatch(table: String, dataList: [[String: any DatabaseValueConvertible]]) async throws
    func writeTransaction(_ block: @Sendable (SafeWriteTransaction) async throws -> Void) async throws

    // Delete
    func delete(table: String, id: String) async throws

    // Sync
    func fullSync() async

    // Status (all @Observable)
    var isInitialized: Bool { get }
    var sseConnected: Bool { get }
    var isSyncing: Bool { get }
    var initialSyncCompleted: Bool { get }
    var syncError: String? { get }
    var userId: String? { get }
}
```

### SafeWriteTransaction

```swift
struct SafeWriteTransaction {
    func write(_ table: String, _ data: [String: any DatabaseValueConvertible]) throws
    func execute(_ sql: String, _ parameters: [any DatabaseValueConvertible]) throws
    func getOptional(_ sql: String, _ parameters: [any DatabaseValueConvertible]) throws -> Row?
    func getAll(_ sql: String, _ parameters: [any DatabaseValueConvertible]) throws -> [Row]
}
```

## Sync Protocol

Identical to Flutter version — no changes to server interaction:

1. **Push**: Query `is_unsynced = 1`, batch 100 rows, POST to `/data`, process per-row accepted/rejected responses
2. **Pull**: For each table, GET `/data?name=X&lts=Y&pageSize=1000`, upsert locally, advance `last_received_lts`
3. **SSE**: Connect to `/events`, trigger `fullSync()` on data events, auto-reconnect after 5s
4. **Archive deletes**: `delete()` creates archive entry, syncs it, other clients process deletion
5. **LTS validation**: On SSE connect, check local max LTS doesn't exceed server's
6. **Conflict resolution**: Server-wins, same as Flutter
7. **Field protection**: Strip `lts` from all writes, always set `is_unsynced = 1`, auto-generate UUID

### Server Endpoints Used

- `GET /data` — fetch rows (with lts, pageSize, name, app_id params)
- `POST /data` — upload unsynced rows (with app_id param)
- `GET /events` — SSE stream (with app_id param)
- `GET /latest-lts` — get latest LTS for table registration
- `GET /max-sequence-lts` — validate LTS on connect

All requests include `Authorization: Bearer <firebase_token>` header.

## Database

### Location

```
iOS:   <AppSupport>/<bundleId>/<userId>/helper_sync.db
macOS: <AppSupport>/<bundleId>/<userId>/helper_sync.db
```

Using `FileManager.default.urls(for: .applicationSupportDirectory)` — standard for both platforms.

### System Tables

Created by the library (not by consumer migrations):

```sql
CREATE TABLE IF NOT EXISTS syncing_table (
    entity_name TEXT PRIMARY KEY,
    last_received_lts INTEGER
);

CREATE TABLE IF NOT EXISTS archive (
    id TEXT PRIMARY KEY,
    lts INTEGER,
    is_unsynced INTEGER,
    table_name TEXT,
    data TEXT,
    data_id TEXT
);
```

### Reactive Queries

GRDB's `ValueObservation` tracks which tables a query touches and automatically re-emits when those tables change. Exposed as `AsyncStream<[Row]>` via the `watch()` method — SwiftUI views can consume this directly with `.task {}` or wrapper.

## Logging

Same structured format as Flutter version. Uses Sentry SDK for Swift:

```swift
enum SyncLogger {
    static func debug(_ message: String, context: [String: Any]? = nil)
    static func info(_ message: String, context: [String: Any]? = nil)
    static func warn(_ message: String, context: [String: Any]? = nil)
    static func error(_ message: String, context: [String: Any]? = nil, error: Error? = nil)
}
```

Prints to console in DEBUG builds, sends to Sentry in all builds.

## Consumer Usage Example

```swift
// 1. Implement protocols
struct MyConstants: SyncConstants {
    let appId = "lt.helper.hard_app"
    let serverUrl = "https://sync.helper.lt"
}

struct MyMigrations: SyncMigrations {
    func migrate(_ db: GRDB.Database) throws {
        try db.create(table: "tasks", ifNotExists: true) { t in
            t.primaryKey("id", .text)
            t.column("lts", .integer)
            t.column("is_unsynced", .integer)
            t.column("priority", .integer)
            t.column("name", .text)
            t.column("cts", .text)
        }
    }
}

struct MyMeta: SyncMetaEntity {
    let syncableColumnsString = ["tasks": "id,lts,is_unsynced,priority,name,cts"]
    let syncableColumnsList = ["tasks": ["id", "lts", "is_unsynced", "priority", "name", "cts"]]
}

// 2. Create backend
let backend = SyncBackend(constants: MyConstants(), migrations: MyMigrations(), meta: MyMeta())

// 3. Init on login
try await backend.initDb(userId: firebaseUser.uid)

// 4. Use
try await backend.write(table: "tasks", data: ["name": "Buy milk", "priority": 0])
```

## What's NOT Included

- **Code generator** — out of scope for initial version. Consumer writes protocols manually.
- **Mock server** — out of scope. Can reuse the Flutter version's mock server for testing.
- **BackendWrapper (InheritedWidget equivalent)** — not needed. SwiftUI uses `@Observable` directly via `@State` or `@Environment`.
- **Device info collection** — Sentry Swift SDK handles this automatically, no manual collection needed.
