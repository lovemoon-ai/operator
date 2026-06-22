// StorageDriver is the bytes layer. Sessions are tracked separately by
// SessionStore (see ../store). We split them so a deployment can pair
// disk storage with SQLite metadata, or S3 storage with the in-memory
// store, without rewriting glue.
//
// The driver receives an open Writable for each artifact and resolves
// when the body has been fully flushed. Implementations MUST be safe
// against the same `resourceId` appearing in two concurrent open()
// calls — TUS clients should not do that, but defensive handlers
// (e.g. a client retrying through a proxy that double-delivers) will.

import type { Writable } from "node:stream";
import type { UploadMetadata } from "../types.js";

export interface ArtifactWriteHandle {
  resourceId: string;
  /** Stream the *next* chunk of `length` bytes into this writable. */
  appendStream: Writable;
  /**
   * Persist any per-chunk bookkeeping (offset, hash). Called after the
   * client-supplied body has fully drained into `appendStream`.
   */
  commitChunk(newOffset: number): Promise<void>;
  /**
   * Roll back a failed append to the last committed offset while keeping the
   * upload resource resumable. Drivers without rollback support may omit this;
   * callers will fall back to dispose().
   */
  abortChunk?(committedOffset: number): Promise<void>;
  /** Final close + (driver-specific) rename-into-place. */
  finalize(metadata: UploadMetadata, totalBytes: number): Promise<FinalizedLocator>;
  /** Abort + cleanup. Safe to call after finalize. */
  dispose(): Promise<void>;
}

export interface FinalizedLocator {
  /** Driver-specific opaque locator (filesystem path, S3 URL, …). */
  uri: string;
  bytes: number;
  /** Hex SHA-256 if the driver computed one. Optional. */
  sha256?: string;
}

export interface StorageDriver {
  /** Allocate a new in-progress upload slot. */
  openResource(resourceId: string, opts: { uploadLength: number }): Promise<ArtifactWriteHandle>;

  /** Re-open an existing slot. Returns null if not found. */
  reopenResource(resourceId: string): Promise<ArtifactWriteHandle | null>;

  /** Current persisted offset for an in-progress upload. */
  resourceOffset(resourceId: string): Promise<number>;

  /**
   * Stream a finalized artifact back out (for the dashboard's download endpoint).
   *
   * If `range` is provided, the returned stream emits only bytes
   * `[start, end]` inclusive — the read API uses this to satisfy HTTP
   * `Range: bytes=…` requests so `<video>` can seek without re-fetching
   * the whole file.
   */
  openFinalized(
    uri: string,
    range?: { start: number; end: number },
  ): Promise<NodeJS.ReadableStream | null>;

  /** Delete a finalized artifact. Used by the dashboard's session-delete action. */
  deleteFinalized(uri: string): Promise<void>;
}

export { DiskStorage } from "./disk.js";
