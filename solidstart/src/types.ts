import type { Accessor } from "solid-js";

export interface SyncConfig {
  appId: string;
  serverUrl: string;
  /** Table schemas: tableName -> columns (must include id, lts, is_unsynced) */
  tables: Record<string, string[]>;
  /** Optional URL to sql-wasm.wasm file */
  wasmUrl?: string;
  /** If false, persist to IndexedDB — survives refresh but slower writes. Default: true (pure in-memory) */
  persist?: boolean;
}

export interface Row {
  id: string;
  lts: number | null;
  is_unsynced: number;
  [key: string]: any;
}

export interface SyncStatus {
  sseConnected: boolean;
  isSyncing: boolean;
  initialSyncCompleted: boolean;
  syncError: string | null;
  userId: string | null;
}

export interface SyncClient {
  init(userId: string): Promise<void>;
  deinit(): void;
  write(tableName: string, data: Record<string, any>): Promise<void>;
  writeBatch(tableName: string, dataList: Record<string, any>[]): Promise<void>;
  delete(tableName: string, id: string): Promise<void>;
  watch(sql: string, triggerOnTables: string[], params?: any[]): Accessor<Row[]>;
  getAll(sql: string, params?: any[]): Row[];
  fullSync(): Promise<void>;
  status: SyncStatus;
}
