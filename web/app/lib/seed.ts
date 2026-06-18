/**
 * One-shot demo seeding.
 *
 * On a user's first authenticated request we mint a "demo" session for
 * them so a visitor without an XR headset still sees the full UI:
 * playback, Rerun viewer, review state, stats.
 *
 * The operator drops the source files into
 *   `<DATA_ROOT>/seed/{manifest.json, media.mp4, [preview.mp4], [session.rrd]}`
 * and we hardlink them into a per-user directory
 *   `<DATA_ROOT>/sessions/<userId>-demo/<file>`
 * Hardlinks share inodes — no disk doubling — and the file system still
 * accounts ownership per session directory so cleanup-on-delete works.
 *
 * Falls back silently when no seed directory is present so a fresh
 * checkout boots without any preparation step.
 */
import { existsSync, linkSync, mkdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { DATA_ROOT } from "./db.js";
import { ingest } from "./ingest.js";
import { runAsUser } from "./auth-context.js";
import { markSeeded, type User } from "./users.js";

const SEED_DIR = path.join(DATA_ROOT, "seed");
const SESSIONS_DIR = path.join(DATA_ROOT, "sessions");

interface SeedFile {
  kind: string;
  filename: string;
  source: string;
}

// Files we ship if present. `manifest.json` and `media.mp4` are the
// minimum the rest of the pipeline (preview / rerun workers, review,
// playback) is built around; Quest camera calibration sidecars and the
// derived `preview.mp4` / `session.rrd` are optional so the seed can either
// ship pre-baked derivations or let the in-process workers regenerate them.
const KNOWN_KINDS: { kind: string; filename: string }[] = [
  { kind: "manifest", filename: "manifest.json" },
  { kind: "media", filename: "media.mp4" },
  { kind: "left_camera_characteristics", filename: "left_camera_characteristics.json" },
  { kind: "right_camera_characteristics", filename: "right_camera_characteristics.json" },
  { kind: "preview", filename: "preview.mp4" },
  { kind: "rrd", filename: "session.rrd" },
];

function collectSeedFiles(): SeedFile[] {
  if (!existsSync(SEED_DIR)) return [];
  const out: SeedFile[] = [];
  for (const { kind, filename } of KNOWN_KINDS) {
    const src = path.join(SEED_DIR, filename);
    if (existsSync(src)) out.push({ kind, filename, source: src });
  }
  return out;
}

/**
 * Idempotent: returns immediately if the user already has the seeded
 * flag, OR if no seed files are configured. Safe to call on every
 * login.
 */
export async function seedDemoForUser(user: User): Promise<void> {
  if (user.seeded) return;
  const files = collectSeedFiles();
  if (files.length === 0) {
    // No seed staged; mark seeded so we don't keep checking on each
    // request, and so adding seed files later doesn't surprise
    // existing users.
    markSeeded(user.id);
    return;
  }

  const sessionId = `${user.id}-demo`;
  const targetDir = path.join(SESSIONS_DIR, sessionId);
  mkdirSync(targetDir, { recursive: true });

  // Parse manifest before registering artifacts so the store picks it up.
  const manifestFile = files.find((f) => f.kind === "manifest");
  let manifest: Record<string, unknown> | undefined;
  if (manifestFile) {
    try {
      manifest = JSON.parse(readFileSync(manifestFile.source, "utf8")) as Record<string, unknown>;
    } catch {
      /* keep going without manifest */
    }
  }

  await runAsUser(user.id, async () => {
    for (const f of files) {
      const dest = path.join(targetDir, f.filename);
      if (!existsSync(dest)) {
        try {
          linkSync(f.source, dest);
        } catch {
          // Cross-device hardlink falls back to copy. Demo files are small.
          const { copyFileSync } = await import("node:fs");
          copyFileSync(f.source, dest);
        }
      }
      const stats = statSync(dest);
      await ingest.store.upsertSessionArtifact(
        sessionId,
        {
          kind: f.kind,
          filename: f.filename,
          bytes: stats.size,
          storedAt: new Date(stats.mtimeMs).toISOString(),
          uri: dest,
        },
        f.kind === "manifest" ? manifest : undefined,
      );
    }
  });

  markSeeded(user.id);
  // eslint-disable-next-line no-console
  console.log(`[seed] demo session ${sessionId} provisioned (${files.length} artifact(s))`);
}
