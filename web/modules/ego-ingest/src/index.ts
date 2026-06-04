// Public entry point for @love-moon/ego-ingest.
//
// What you'll typically import:
//
//   import {
//     createIngestMiddleware,  // TUS 1.0.0 receiver (mount under /ingest)
//     createReadApi,           // read-only sessions / stats / SSE API
//     MemoryStore,             // default metadata store
//     DiskStorage,             // default bytes storage
//     IngestEvents,            // event bus shared between middleware + api
//   } from '@love-moon/ego-ingest';
//
// See examples/ for runnable wiring.

export { createIngestMiddleware } from "./tus/middleware.js";
export { createReadApi } from "./api.js";
export { createDashboard } from "./dashboard/server.js";
export type { DashboardOptions } from "./dashboard/server.js";
export { IngestEvents } from "./events.js";
export type { IngestEvent } from "./events.js";

export { MemoryStore } from "./store/memory.js";
export type { SessionStore, StoreStats } from "./store/index.js";

export { DiskStorage } from "./storage/disk.js";
export type { StorageDriver, ArtifactWriteHandle, FinalizedLocator } from "./storage/index.js";

export type {
  ArtifactKind,
  AuthFn,
  FinalizedArtifact,
  IngestOptions,
  OnSessionHook,
  ResourceRecord,
  SessionRecord,
  UploadMetadata,
} from "./types.js";

export { SCHEMA_VERSION, TUS_VERSION } from "./types.js";
export { parseUploadMetadata, buildUploadMetadata } from "./tus/metadata.js";
