// Shared types for the @love-moon/ego-ingest package.
//
// Kept intentionally small — adding fields here is a wire-compat change
// for downstream consumers. Anything that's purely server-internal stays
// out of this file.

export const TUS_VERSION = "1.0.0" as const;
export const SCHEMA_VERSION = "spatialmp4.quest_capture.spool.v2" as const;

export type ArtifactKind = "manifest" | "media" | (string & {});

/** Metadata parsed off the TUS `Upload-Metadata` header. */
export interface UploadMetadata {
  session_id: string;
  artifact_kind: ArtifactKind;
  filename: string;
  schema?: string;
  /** Free-form pass-through for unknown keys. */
  extra: Record<string, string>;
}

/** A single in-progress TUS resource. */
export interface ResourceRecord {
  id: string;
  sessionId: string;
  artifactKind: ArtifactKind;
  uploadLength: number;
  offset: number;
  metadata: UploadMetadata;
  createdAt: string;
  lastPatchAt?: string;
}

/** A session that has at least one finalized artifact on disk. */
export interface SessionRecord {
  id: string;
  receivedAt: string;
  artifacts: Record<string, FinalizedArtifact>;
  totalBytes: number;
  /** Best-effort parsed from manifest.json after it's uploaded. */
  manifest?: Record<string, unknown>;
}

export interface FinalizedArtifact {
  kind: ArtifactKind;
  filename: string;
  bytes: number;
  sha256?: string;
  storedAt: string;
  /** Storage-driver-specific opaque locator (path / S3 key / …). */
  uri: string;
}

/** Hook invoked once a session's `media` artifact has finalized. */
export type OnSessionHook = (session: SessionRecord) => void | Promise<void>;

/** Auth predicate — called on every request before TUS state changes. */
export type AuthFn = (req: import("express").Request) => boolean | Promise<boolean>;

export interface IngestOptions {
  store: import("./store/index.js").SessionStore;
  storage: import("./storage/index.js").StorageDriver;
  auth?: AuthFn;
  /** Reject `Upload-Length` larger than this. Default 100 GB. */
  maxUploadSizeBytes?: number;
  /** Called after a session has all its expected artifacts. */
  onSession?: OnSessionHook;
  /** Schema versions this server will accept. Default: current only. */
  acceptedSchemas?: readonly string[];
}
