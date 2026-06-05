import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { PassThrough, type Writable } from "node:stream";

import type { ArtifactWriteHandle, FinalizedLocator, StorageDriver } from "./index.js";
import type { UploadMetadata } from "../types.js";

export interface DiskStorageOptions {
  /**
   * Base directory for both in-progress and finalized files. We create
   * `<root>/.partial/` for chunked uploads and move into
   * `<root>/<session_id>/<artifact_kind><ext>` on finalize.
   */
  root: string;
  /**
   * Compute SHA-256 of each finalized artifact. Off by default because
   * it doubles disk read for the largest artifact (a multi-GB MP4).
   * Turn it on for ingest pipelines that want server-side verification.
   */
  computeHashes?: boolean;
}

const PARTIAL_DIR = ".partial";

/**
 * Plain filesystem storage. Each chunk is appended to
 * `<root>/.partial/<resourceId>`; finalize() rename-moves the file to
 * `<root>/<session_id>/<artifact_kind><ext>`.
 *
 * Renames are atomic on the same filesystem, so a crash between the
 * final PATCH and the rename leaves a complete (but oddly-named) file
 * in `.partial/` — the gc() method is the dashboard's hook to clean
 * those up, but for v1 we leave them: easier debugging.
 */
export class DiskStorage implements StorageDriver {
  private readonly root: string;
  private readonly computeHashes: boolean;
  private readonly hashers = new Map<string, ReturnType<typeof createHash>>();

  constructor(opts: DiskStorageOptions) {
    this.root = path.resolve(opts.root);
    this.computeHashes = !!opts.computeHashes;
  }

  private partialPath(resourceId: string): string {
    return path.join(this.root, PARTIAL_DIR, resourceId);
  }

  async openResource(resourceId: string, opts: { uploadLength: number }): Promise<ArtifactWriteHandle> {
    await mkdir(path.join(this.root, PARTIAL_DIR), { recursive: true });
    // Touch the file so reopenResource() / resourceOffset() see it.
    await createEmptyIfMissing(this.partialPath(resourceId));
    void opts.uploadLength;
    return this.handle(resourceId);
  }

  async reopenResource(resourceId: string): Promise<ArtifactWriteHandle | null> {
    try {
      await stat(this.partialPath(resourceId));
    } catch {
      return null;
    }
    return this.handle(resourceId);
  }

  async resourceOffset(resourceId: string): Promise<number> {
    try {
      const s = await stat(this.partialPath(resourceId));
      return s.size;
    } catch {
      return 0;
    }
  }

  async openFinalized(
    uri: string,
    range?: { start: number; end: number },
  ): Promise<NodeJS.ReadableStream | null> {
    try {
      await stat(uri);
    } catch {
      return null;
    }
    if (range) {
      // createReadStream's `end` is inclusive — same semantics as HTTP
      // Range, so the read API can hand the parsed pair straight through.
      return createReadStream(uri, { start: range.start, end: range.end });
    }
    return createReadStream(uri);
  }

  async deleteFinalized(uri: string): Promise<void> {
    try {
      await unlink(uri);
    } catch {
      /* ignore */
    }
  }

  private handle(resourceId: string): ArtifactWriteHandle {
    const partial = this.partialPath(resourceId);
    let hasher: ReturnType<typeof createHash> | undefined;
    if (this.computeHashes) {
      hasher = this.hashers.get(resourceId) ?? createHash("sha256");
      this.hashers.set(resourceId, hasher);
    }

    // Each chunk gets a fresh append stream — Node's streams complete
    // their lifecycle per request, and reusing a Writable across two
    // PATCH bodies invites half-flushed state on disconnect.
    const fileStream = createWriteStream(partial, { flags: "a" });
    const fileDone = new Promise<void>((resolve, reject) => {
      const cleanup = () => {
        fileStream.off("error", onError);
        fileStream.off("finish", onFinish);
      };
      const onError = (err: Error) => {
        cleanup();
        reject(err);
      };
      const onFinish = () => {
        cleanup();
        resolve();
      };
      fileStream.once("error", onError);
      fileStream.once("finish", onFinish);
    });
    // fs.WriteStream is write-only and does NOT emit 'data', so we can't
    // attach a hasher to it directly. Wrap with a PassThrough so the
    // middleware writes through us, we tap each chunk into the hash,
    // and then forward to the underlying file. The PassThrough is what
    // we hand back as `appendStream`.
    let appendStream: Writable;
    if (hasher) {
      const tap = new PassThrough();
      const h = hasher;
      tap.on("data", (chunk: Buffer) => h.update(chunk));
      tap.pipe(fileStream);
      // Forward finish/error from the file back up so callers awaiting
      // 'finish' on `appendStream` still see flush completion.
      fileStream.on("error", (err) => tap.destroy(err));
      appendStream = tap;
    } else {
      appendStream = fileStream;
    }

    return {
      resourceId,
      appendStream,
      commitChunk: async (_newOffset: number) => {
        // The middleware waits for appendStream.finish. With hashing enabled
        // appendStream is a PassThrough, so finish only proves the request body
        // entered the pipe; wait for the underlying fs.WriteStream too before
        // publishing a new TUS offset or finalizing the resource.
        await fileDone;
      },
      finalize: async (metadata: UploadMetadata, totalBytes: number): Promise<FinalizedLocator> => {
        const sessionDir = path.join(this.root, sanitizeSegment(metadata.session_id || resourceId));
        await mkdir(sessionDir, { recursive: true });
        const kind = sanitizeSegment(metadata.artifact_kind || "data");
        const ext = inferExtension(metadata.filename, metadata.artifact_kind);
        const target = path.join(sessionDir, `${kind}${ext}`);
        // Atomic move on same FS. If target exists from an earlier
        // upload, overwrite — TUS clients don't retry past completion
        // but a manual re-run might.
        await rename(partial, target);
        const sz = await stat(target);
        if (sz.size !== totalBytes) {
          throw new Error(`Disk size mismatch for ${target}: expected ${totalBytes}, got ${sz.size}`);
        }
        const sha256 = hasher ? hasher.digest("hex") : undefined;
        this.hashers.delete(resourceId);
        return { uri: target, bytes: sz.size, sha256 };
      },
      dispose: async () => {
        this.hashers.delete(resourceId);
        try {
          await unlink(partial);
        } catch {
          /* ignore */
        }
      },
    };
  }
}

// --- helpers ----------------------------------------------------------------

function sanitizeSegment(s: string): string {
  // Strip path separators and anything that could escape the session
  // directory. Conservative — we accept a-z A-Z 0-9 _ - . and replace
  // everything else with `_`.
  const cleaned = s.replace(/[^A-Za-z0-9_.\-]/g, "_");
  // No leading dots (would collide with hidden dirs / our .partial slot).
  return cleaned.replace(/^\.+/, "_");
}

function inferExtension(filename: string, kind: string): string {
  if (filename && filename.includes(".")) {
    return "." + filename.split(".").pop()!;
  }
  if (kind === "manifest") return ".json";
  if (kind === "media") return ".mp4";
  return "";
}

async function createEmptyIfMissing(p: string): Promise<void> {
  try {
    await stat(p);
  } catch {
    const fh = await import("node:fs/promises").then((m) => m.open(p, "a"));
    await fh.close();
  }
}
