// Shared types for the @love-moon/ego-ingest package.
//
// Kept intentionally small — adding fields here is a wire-compat change
// for downstream consumers. Anything that's purely server-internal stays
// out of this file.

export const TUS_VERSION = "1.0.0" as const;
export const SCHEMA_VERSION = "spatialmp4.quest_capture.spool.v3" as const;

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
  /**
   * Set when the orphan watchdog declared this session abandoned
   * (manifest landed but media didn't show up within
   * `IngestOptions.orphanTimeoutMs`). Visible to the UI so the
   * "Incomplete upload" banner can distinguish "still waiting" from
   * "gave up waiting".
   */
  expired?: { at: string; reason: string };
}

export interface FinalizedArtifact {
  kind: ArtifactKind;
  filename: string;
  bytes: number;
  /** Server-computed SHA-256 (DiskStorage with `computeHashes: true`). */
  sha256?: string;
  storedAt: string;
  /** Storage-driver-specific opaque locator (path / S3 key / …). */
  uri: string;
  /**
   * Set when the manifest declared a `sha256` for this artifact and
   * the server-computed value didn't match. The bytes are still on
   * disk for forensics, but downstream workers (preview / rrd) MUST
   * NOT consume a corrupt artifact — see the integrity gate in
   * `tus/middleware.ts`.
   */
  corrupt?: boolean;
  /**
   * The SHA-256 declared in the manifest's `artifacts.<kind>.sha256`
   * field, if any. Kept on the artifact for diagnostic UI even when
   * the comparison passed.
   */
  expectedSha256?: string;
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
  /**
   * How long to wait, after a session's manifest has landed, for the
   * companion media artifact before declaring the session abandoned.
   * Default 15 minutes. Set `0` (or a negative value) to disable the
   * watchdog entirely — useful for tests + ingest pipelines where
   * media might arrive hours later.
   */
  orphanTimeoutMs?: number;
}
