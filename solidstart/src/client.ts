import initSqlJs, { type Database as SqlJsDatabase } from "sql.js";
import { createSignal, createMemo, batch, type Accessor } from "solid-js";
import { createStore } from "solid-js/store";
import { getAuth } from "firebase/auth";
import type { SyncConfig, SyncClient, SyncStatus, Row } from "./types";

// --- IndexedDB helpers ---

const IDB_NAME = "sync_helper";
const IDB_STORE = "databases";

function openIdb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(IDB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(IDB_STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbSave(key: string, data: Uint8Array): Promise<void> {
  const idb = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = idb.transaction(IDB_STORE, "readwrite");
    tx.objectStore(IDB_STORE).put(data, key);
    tx.oncomplete = () => {
      idb.close();
      resolve();
    };
    tx.onerror = () => {
      idb.close();
      reject(tx.error);
    };
  });
}

async function idbLoad(key: string): Promise<Uint8Array | null> {
  const idb = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = idb.transaction(IDB_STORE, "readonly");
    const req = tx.objectStore(IDB_STORE).get(key);
    req.onsuccess = () => {
      idb.close();
      resolve(req.result ?? null);
    };
    req.onerror = () => {
      idb.close();
      reject(req.error);
    };
  });
}

async function idbDelete(key: string): Promise<void> {
  const idb = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = idb.transaction(IDB_STORE, "readwrite");
    tx.objectStore(IDB_STORE).delete(key);
    tx.oncomplete = () => {
      idb.close();
      resolve();
    };
    tx.onerror = () => {
      idb.close();
      reject(tx.error);
    };
  });
}

// --- Sync client ---

const ARCHIVE_COLUMNS = "id,lts,is_unsynced,table_name,data,data_id";

export function createSyncClient(config: SyncConfig): SyncClient {
  let db: SqlJsDatabase | null = null;

  // Reactivity: version signal per table — bumped on data changes
  const allTableNames = [...Object.keys(config.tables), "archive"];
  const tableSignals: Record<
    string,
    [Accessor<number>, (v: number | ((prev: number) => number)) => void]
  > = {};
  for (const name of allTableNames) {
    tableSignals[name] = createSignal(0);
  }

  function bumpTable(name: string) {
    tableSignals[name]?.[1]((v) => v + 1);
  }

  function bumpAllTables() {
    for (const name of allTableNames) {
      bumpTable(name);
    }
  }

  // Status store
  const [status, setStatus] = createStore<SyncStatus>({
    sseConnected: false,
    isSyncing: false,
    initialSyncCompleted: false,
    syncError: null,
    userId: null,
  });

  // Internal state
  let abortController: AbortController | null = null;
  let fullSyncStarted = false;
  let repeatSync = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let saveTimer: ReturnType<typeof setTimeout> | null = null;

  // --- Internal helpers ---

  function idbKey(): string {
    return `${config.appId}_${status.userId}`;
  }

  function scheduleSave() {
    if (!config.persist) return;
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(async () => {
      if (!db) return;
      try {
        await idbSave(idbKey(), db.export());
      } catch (e) {
        console.error("Failed to persist database:", e);
      }
    }, 500);
  }

  function forceSave() {
    if (!config.persist) return;
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = null;
    if (!db) return;
    idbSave(idbKey(), db.export()).catch((e) =>
      console.error("Failed to persist database:", e),
    );
  }

  function query(sql: string, params?: any[]): Row[] {
    if (!db) return [];
    const stmt = db.prepare(sql);
    if (params) stmt.bind(params);
    const results: Row[] = [];
    while (stmt.step()) {
      results.push(stmt.getAsObject() as unknown as Row);
    }
    stmt.free();
    return results;
  }

  function run(sql: string, params?: any[]) {
    if (!db) return;
    db.run(sql, params);
  }

  async function getAuthToken(): Promise<string> {
    const user = getAuth().currentUser;
    if (!user) throw new Error("User not authenticated with Firebase");
    const token = await user.getIdToken();
    if (!token) throw new Error("Firebase auth token not available");
    return token;
  }

  // --- Schema ---

  function createSchema() {
    run(`CREATE TABLE IF NOT EXISTS syncing_table (
      entity_name TEXT PRIMARY KEY,
      last_received_lts INTEGER DEFAULT 0
    )`);

    run(`CREATE TABLE IF NOT EXISTS archive (
      id TEXT PRIMARY KEY,
      lts INTEGER,
      is_unsynced INTEGER DEFAULT 0,
      table_name TEXT,
      data TEXT,
      data_id TEXT
    )`);

    run(
      `INSERT OR IGNORE INTO syncing_table (entity_name, last_received_lts) VALUES ('archive', 0)`,
    );

    for (const [tableName, columns] of Object.entries(config.tables)) {
      const colDefs = columns
        .map((col) => {
          if (col === "id") return "id TEXT PRIMARY KEY";
          if (col === "lts") return "lts INTEGER";
          if (col === "is_unsynced") return "is_unsynced INTEGER DEFAULT 0";
          return `${col} TEXT`;
        })
        .join(", ");

      run(`CREATE TABLE IF NOT EXISTS ${tableName} (${colDefs})`);
      run(
        `INSERT OR IGNORE INTO syncing_table (entity_name, last_received_lts) VALUES (?, 0)`,
        [tableName],
      );
    }

    scheduleSave();
  }

  // --- Table registration (get initial LTS from server) ---

  async function registerTable(tableName: string): Promise<void> {
    const existing = query(
      "SELECT last_received_lts FROM syncing_table WHERE entity_name = ?",
      [tableName],
    );
    if (existing.length > 0 && (existing[0].last_received_lts as number) > 0)
      return;

    let latestLts: number | null = null;
    let retries = 3;

    while (retries > 0 && latestLts === null) {
      try {
        const token = await getAuthToken();
        const res = await fetch(
          `${config.serverUrl}/latest-lts?name=${tableName}&app_id=${config.appId}`,
          { headers: { Authorization: `Bearer ${token}` } },
        );
        if (res.ok) {
          latestLts = (await res.json()).lts as number;
        } else if (res.status === 403 || res.status === 404) {
          latestLts = 0;
        } else {
          throw new Error(`HTTP ${res.status}`);
        }
      } catch {
        retries--;
        if (retries > 0) await new Promise((r) => setTimeout(r, 2000));
      }
    }

    run(
      "UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?",
      [latestLts ?? 0, tableName],
    );
    scheduleSave();
  }

  // --- Init / Deinit ---

  async function init(userId: string): Promise<void> {
    setStatus("userId", userId);
    setStatus("initialSyncCompleted", false);
    setStatus("syncError", null);

    const SQL = await initSqlJs(
      config.wasmUrl ? { locateFile: () => config.wasmUrl! } : undefined,
    );

    if (!config.persist) {
      db = new SQL.Database();
    } else {
      const key = `${config.appId}_${userId}`;
      const existing = await idbLoad(key);
      db = existing ? new SQL.Database(existing) : new SQL.Database();
    }

    createSchema();
    await registerTable("archive");
    bumpAllTables();
    startSyncer();
  }

  function deinit(): void {
    abortController?.abort();
    abortController = null;

    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (saveTimer) {
      clearTimeout(saveTimer);
      saveTimer = null;
    }

    if (db) {
      forceSave();
      db.close();
      db = null;
    }

    batch(() => {
      setStatus("sseConnected", false);
      setStatus("initialSyncCompleted", false);
      setStatus("userId", null);
    });
  }

  // --- Write operations ---

  async function write(
    tableName: string,
    data: Record<string, any>,
  ): Promise<void> {
    const row = { ...data };
    if (!row.id) row.id = crypto.randomUUID();
    delete row.lts;
    delete row.is_unsynced;

    const columns = Object.keys(row);
    const values = Object.values(row);
    const placeholders = columns.map(() => "?").join(", ");
    const updateCols = columns
      .filter((c) => c !== "id")
      .map((c) => `${c} = ?`)
      .join(", ");
    const updateValues = columns
      .filter((c) => c !== "id")
      .map((c) => row[c]);

    run(
      `INSERT INTO ${tableName} (${columns.join(", ")}, is_unsynced)
       VALUES (${placeholders}, 1)
       ON CONFLICT(id) DO UPDATE SET ${updateCols}, is_unsynced = 1`,
      [...values, ...updateValues],
    );

    bumpTable(tableName);
    scheduleSave();
    await fullSync();
  }

  async function writeBatch(
    tableName: string,
    dataList: Record<string, any>[],
  ): Promise<void> {
    if (dataList.length === 0) return;

    for (const data of dataList) {
      const row = { ...data };
      if (!row.id) row.id = crypto.randomUUID();
      delete row.lts;
      delete row.is_unsynced;

      const columns = Object.keys(row);
      const values = Object.values(row);
      const placeholders = columns.map(() => "?").join(", ");
      const updateCols = columns
        .filter((c) => c !== "id")
        .map((c) => `${c} = ?`)
        .join(", ");
      const updateValues = columns
        .filter((c) => c !== "id")
        .map((c) => row[c]);

      run(
        `INSERT INTO ${tableName} (${columns.join(", ")}, is_unsynced)
         VALUES (${placeholders}, 1)
         ON CONFLICT(id) DO UPDATE SET ${updateCols}, is_unsynced = 1`,
        [...values, ...updateValues],
      );
    }

    bumpTable(tableName);
    scheduleSave();
    await fullSync();
  }

  async function deleteRow(
    tableName: string,
    id: string,
  ): Promise<void> {
    const rows = query(`SELECT * FROM ${tableName} WHERE id = ?`, [id]);

    if (rows.length > 0) {
      const archiveId = crypto.randomUUID();
      run(
        "INSERT INTO archive (id, table_name, data, data_id, is_unsynced) VALUES (?, ?, ?, ?, 1)",
        [archiveId, tableName, JSON.stringify(rows[0]), id],
      );
    }

    run(`DELETE FROM ${tableName} WHERE id = ?`, [id]);

    bumpTable(tableName);
    bumpTable("archive");
    scheduleSave();
    await fullSync();
  }

  // --- Read operations ---

  function watch(
    sql: string,
    triggerOnTables: string[],
    params?: any[],
  ): Accessor<Row[]> {
    return createMemo(() => {
      // Subscribe to table version signals for reactivity
      for (const t of triggerOnTables) {
        tableSignals[t]?.[0]();
      }
      return query(sql, params);
    });
  }

  function getAll(sql: string, params?: any[]): Row[] {
    return query(sql, params);
  }

  // --- Sync engine ---

  async function fullSync(): Promise<void> {
    if (fullSyncStarted) {
      repeatSync = true;
      return;
    }
    fullSyncStarted = true;
    setStatus("isSyncing", true);

    try {
      const syncingTables = query("SELECT * FROM syncing_table");
      await sendUnsynced(syncingTables);

      for (const table of syncingTables) {
        const tableName = table.entity_name as string;
        let more = true;
        let lts = table.last_received_lts as number;

        while (more) {
          const token = await getAuthToken();
          const params = new URLSearchParams({
            name: tableName,
            pageSize: "1000",
            app_id: config.appId,
          });
          if (lts) params.set("lts", String(lts));

          const res = await fetch(`${config.serverUrl}/data?${params}`, {
            headers: { Authorization: `Bearer ${token}` },
          });

          if (!res.ok) throw new Error(`Fetch failed: ${res.status}`);

          const resp = await res.json();
          const data = (resp.data ?? []) as Record<string, any>[];

          if (data.length === 0) {
            more = false;
            continue;
          }

          // Check for local unsynced rows before pulling (same as Flutter)
          if (tableName !== "archive") {
            const unsynced = query(
              `SELECT id FROM ${tableName} WHERE is_unsynced = 1 LIMIT 1`,
            );
            if (unsynced.length > 0) {
              more = false;
              repeatSync = true;
              continue;
            }
          }

          const lastLts = data[data.length - 1].lts as number;

          if (tableName === "archive") {
            for (const row of data) {
              const targetTable = row.table_name as string | undefined;
              const targetId = row.data_id as string | undefined;
              const archiveRowId = row.id as string;

              if (targetTable && targetId) {
                run(`DELETE FROM ${targetTable} WHERE id = ?`, [targetId]);
                bumpTable(targetTable);
              }
              if (archiveRowId) {
                run("DELETE FROM archive WHERE id = ?", [archiveRowId]);
              }
            }
            run(
              "UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = 'archive'",
              [lastLts],
            );
            bumpTable("archive");
          } else {
            // Upsert rows from server
            const cols = config.tables[tableName];
            if (cols) {
              const placeholders = cols.map(() => "?").join(", ");
              const updates = cols
                .filter((c) => c !== "id")
                .map((c) => `${c} = excluded.${c}`)
                .join(", ");
              const sql = `INSERT INTO ${tableName} (${cols.join(", ")}) VALUES (${placeholders})
                           ON CONFLICT(id) DO UPDATE SET ${updates}`;

              for (const row of data) {
                const values = cols.map((c) => row[c] ?? null);
                run(sql, values);
              }
            }

            run(
              "UPDATE syncing_table SET last_received_lts = ? WHERE entity_name = ?",
              [lastLts, tableName],
            );
            bumpTable(tableName);
          }

          if (data.length < 1000) {
            more = false;
          } else {
            lts = lastLts;
          }
        }
      }

      scheduleSave();
    } catch (e) {
      console.error("Sync error:", e);
      setStatus("syncError", String(e));
    }

    fullSyncStarted = false;
    setStatus("isSyncing", false);

    if (repeatSync) {
      repeatSync = false;
      await fullSync();
    }
  }

  async function sendUnsynced(
    syncingTables: Row[],
  ): Promise<void> {
    const batchSize = 100;
    let retry: boolean;

    do {
      retry = false;

      for (const table of syncingTables) {
        const tableName = table.entity_name as string;
        const colString =
          tableName === "archive"
            ? ARCHIVE_COLUMNS
            : config.tables[tableName]?.join(", ");
        if (!colString) continue;

        let offset = 0;
        let hasMoreData = true;

        while (hasMoreData && !retry) {
          const rows = query(
            `SELECT ${colString} FROM ${tableName} WHERE is_unsynced = 1 LIMIT ? OFFSET ?`,
            [batchSize, offset],
          );

          if (rows.length === 0) {
            hasMoreData = false;
            continue;
          }

          try {
            const token = await getAuthToken();
            const res = await fetch(
              `${config.serverUrl}/data?app_id=${config.appId}`,
              {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  Authorization: `Bearer ${token}`,
                },
                body: JSON.stringify({
                  name: tableName,
                  data: JSON.stringify(rows),
                }),
              },
            );

            if (!res.ok) {
              retry = true;
              break;
            }

            const responseData = await res.json();
            const results = responseData.results as Array<{
              id: string;
              status: string;
              lts?: number;
              reason?: string;
            }>;

            for (const result of results) {
              if (result.status === "accepted") {
                const newLts = result.lts!;
                const sentRow = rows.find((r) => r.id === result.id);

                // Check if data changed locally since batch was sent
                const currentRows = query(
                  `SELECT * FROM ${tableName} WHERE id = ?`,
                  [result.id],
                );
                const currentRow =
                  currentRows.length > 0 ? currentRows[0] : null;

                let dataChanged = false;
                if (sentRow && currentRow) {
                  const dataCols = (
                    tableName === "archive"
                      ? ARCHIVE_COLUMNS.split(",")
                      : config.tables[tableName] ?? []
                  ).filter(
                    (c) => c !== "lts" && c !== "is_unsynced" && c !== "id",
                  );

                  for (const col of dataCols) {
                    if (
                      String(sentRow[col] ?? "") !==
                      String(currentRow[col] ?? "")
                    ) {
                      dataChanged = true;
                      break;
                    }
                  }
                }

                if (dataChanged) {
                  run(`UPDATE ${tableName} SET lts = ? WHERE id = ?`, [
                    newLts,
                    result.id,
                  ]);
                } else {
                  run(
                    `UPDATE ${tableName} SET is_unsynced = 0, lts = ? WHERE id = ?`,
                    [newLts, result.id],
                  );
                }
              } else if (result.status === "rejected") {
                run(
                  `UPDATE ${tableName} SET is_unsynced = 0 WHERE id = ?`,
                  [result.id],
                );
              }
            }

            bumpTable(tableName);
          } catch {
            retry = true;
            break;
          }

          if (rows.length < batchSize) {
            hasMoreData = false;
          } else {
            offset += batchSize;
          }
        }

        if (retry) break;
      }
    } while (retry);
  }

  // --- LTS validation ---

  async function validateLtsOnConnect(): Promise<boolean> {
    try {
      const token = await getAuthToken();
      const res = await fetch(`${config.serverUrl}/max-sequence-lts`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!res.ok) return true;

      const data = await res.json();
      const serverMaxLts =
        typeof data.lts === "number" ? data.lts : parseInt(data.lts) || 0;

      // Find max local LTS
      let clientMaxLts = 0;
      const syncRows = query("SELECT MAX(last_received_lts) as max_lts FROM syncing_table");
      if (syncRows.length > 0) {
        clientMaxLts = (syncRows[0].max_lts as number) ?? 0;
      }

      for (const tableName of Object.keys(config.tables)) {
        const result = query(
          `SELECT MAX(lts) as max_lts FROM ${tableName}`,
        );
        if (result.length > 0) {
          const tableLts = (result[0].max_lts as number) ?? 0;
          if (tableLts > clientMaxLts) clientMaxLts = tableLts;
        }
      }

      if (clientMaxLts > serverMaxLts) {
        setStatus(
          "syncError",
          `Local data ahead of server (LTS: ${clientMaxLts} > ${serverMaxLts})`,
        );
        return false;
      }

      setStatus("syncError", null);
      return true;
    } catch {
      return true;
    }
  }

  // --- SSE (fetch-based to support Authorization header) ---

  async function startSyncer(): Promise<void> {
    if (status.sseConnected) return;

    const handleError = (reason: string) => {
      console.warn(`SSE error: ${reason}, retrying in 5s`);
      setStatus("sseConnected", false);
      abortController?.abort();
      abortController = null;
      reconnectTimer = setTimeout(startSyncer, 5000);
    };

    try {
      const token = await getAuthToken();
      const url = new URL(`${config.serverUrl}/events`);
      url.searchParams.set("app_id", config.appId);

      abortController = new AbortController();

      const res = await fetch(url.toString(), {
        headers: {
          Accept: "text/event-stream",
          Authorization: `Bearer ${token}`,
        },
        signal: abortController.signal,
      });

      if (!res.ok || !res.body) {
        handleError(`HTTP ${res.status}`);
        return;
      }

      setStatus("sseConnected", true);

      await validateLtsOnConnect();
      await fullSync();

      if (!status.initialSyncCompleted) {
        setStatus("initialSyncCompleted", true);
      }

      // Read SSE stream
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      const readLoop = async () => {
        while (true) {
          const { done, value } = await reader.read();
          if (done) {
            handleError("Stream closed");
            return;
          }

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            if (line.startsWith("data:")) {
              fullSync();
            }
          }
        }
      };

      readLoop().catch((e: any) => {
        if (e.name !== "AbortError") handleError(String(e));
      });
    } catch (e: any) {
      if (e.name !== "AbortError") handleError(String(e));
    }
  }

  // --- Public API ---

  return {
    init,
    deinit,
    write,
    writeBatch,
    delete: deleteRow,
    watch,
    getAll,
    fullSync,
    status,
  };
}
