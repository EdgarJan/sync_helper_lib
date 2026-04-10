import { createContext, useContext } from "solid-js";
import type { SyncClient } from "./types";

export const SyncContext = createContext<SyncClient>();

export function useSync(): SyncClient {
  const ctx = useContext(SyncContext);
  if (!ctx) throw new Error("useSync must be used within SyncContext.Provider");
  return ctx;
}
