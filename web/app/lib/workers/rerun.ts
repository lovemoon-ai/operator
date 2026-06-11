/**
 * Rerun worker — converts the SpatialMP4 archive into a `.rrd`
 * recording that the embedded Rerun web viewer can load directly.
 *
 * We outsource the actual demux + log calls to a Python sidecar
 * (scripts/spatialmp4_to_rrd.py) for one reason: there is no Node
 * binding for either PyAV-style libav access or the Rerun SDK. The
 * sidecar uses both, so the conversion stays in one process instead
 * of plumbing raw decoded frames across an IPC boundary.
 *
 * Python environment is managed by `uv` via PEP 723 inline metadata
 * at the top of the sidecar. The worker invokes
 *   uv run --script --no-project scripts/spatialmp4_to_rrd.py …
 * which resolves and caches the environment on first run, then
 * reuses it for subsequent sessions. No pyproject.toml, no venv to
 * manage, no pip install step. The only one-time install on the
 * host is uv itself.
 *
 * Sidecar contract (same regardless of how it's invoked):
 *   --input  <abs path to media.mp4>
 *   --output <abs path to session.rrd>
 *   [--topk N]   # cap RGB+depth frame count; default unlimited
 *
 *   Exit 0 on success, non-zero on failure. Any stderr is forwarded
 *   to the server log so the cause shows up next to the worker line.
 *
 *   The sidecar relies on the SpatialMP4 SDK
 *   (https://github.com/Pico-Developer/SpatialMP4) which is NOT a
 *   PyPI package — it ships as a pybind11 build. We auto-discover a
 *   local checkout via `SPATIALMP4_HOME`, Operator's shared `.deps`
 *   cache, or common dev paths under $HOME and forward it to the sidecar; the sidecar's
 *   bootstrap then injects the right `.so` directory onto `sys.path`.
 *   If no checkout is found the worker still runs but the sidecar
 *   bails out with a clear hint.
 *
 * Setup:
 *   brew install uv         # macOS
 *   # or: curl -LsSf https://astral.sh/uv/install.sh | sh
 *
 *   # Build the SpatialMP4 SDK once for your Python ABI (uv picks
 *   # CPython 3.13 by default, see the sidecar's PEP 723 block):
 *   scripts/setup_spatialmp4.sh
 *
 * The worker degrades gracefully when uv is missing or the sidecar
 * fails — the session page just hides the Rerun panel and the
 * <video> preview still works.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { SessionRecord } from "@love-moon/ego-ingest";

import { ingest } from "../ingest.js";

const DEFAULT_SCRIPT_PATH = fileURLToPath(
  // Resolve from this compiled-or-tsx module to the repo-relative script.
  // `app/lib/workers/rerun.ts` → `app/scripts/spatialmp4_to_rrd.py`
  new URL("../../scripts/spatialmp4_to_rrd.py", import.meta.url),
);
const PICO_SCRIPT_PATH = fileURLToPath(
  // Pico captures use the SDK's Pico coordinate profile.
  new URL("../../scripts/spatialmp4_to_rrd_pico.py", import.meta.url),
);
const UV_BIN = process.env.UV_BIN ?? "uv";
// Escape hatch: if someone really wants to bypass uv and run with a
// pre-built venv on $PATH, set RERUN_PYTHON_BIN=/path/to/python and we
// skip uv entirely. The script's PEP 723 metadata is just a comment to
// that python — it'll need the deps already installed.
const PYTHON_BIN = process.env.RERUN_PYTHON_BIN ?? null;
// Pin the Python version uv runs the sidecar with. Has to match the
// ABI of the SpatialMP4 SDK `.so` we point at — by default uv would
// pick the newest installed, which often isn't what the SDK was built
// against. 3.13 matches the build at
// `SpatialMP4/build/python313/python/`; flip to 3.10 if you'd rather
// use `build/host_py/`.
const PYTHON_VERSION = process.env.RERUN_PYTHON_VERSION ?? "3.13";
const TOPK_FRAMES = process.env.RERUN_TOPK_FRAMES ?? null;

/**
 * Discover the SpatialMP4 SDK source checkout so the Python sidecar
 * can `import spatialmp4` (the SDK is a pybind11 build that ships as a
 * compiled `.so`, not a PyPI package). The sidecar's bootstrap walks
 * this directory for a `spatialmp4.cpython-<tag>-<plat>.so` that
 * matches its own Python ABI; we just need to point it at the right
 * tree.
 *
 * Order of preference:
 *   1. SPATIALMP4_HOME env var (operator override)
 *   2. Operator shared dependency cache at `.deps/src/SpatialMP4`
 *   3. Common dev checkout locations under $HOME — first one that
 *      actually exists wins
 *
 * Returning `null` is fine — the sidecar still bails out with an
 * actionable hint, but the worker logs that the SDK wasn't found
 * before incurring the uv startup cost.
 */
function discoverSpatialmp4Home(): string | null {
  const fromEnv = process.env.SPATIALMP4_HOME;
  if (fromEnv && fromEnv.length > 0) return fromEnv;

  const home = os.homedir();
  const repoRoot = path.resolve(path.dirname(DEFAULT_SCRIPT_PATH), "../../..");
  const depsRoot = process.env.OPERATOR_DEPS_CACHE_ROOT ?? path.join(repoRoot, ".deps");
  const candidates = [
    path.join(depsRoot, "src", "SpatialMP4"),
    path.join(home, "ws", "spatialmp4-quest", "SpatialMP4"),
    path.join(home, "spatialmp4-quest", "SpatialMP4"),
    path.join(home, "SpatialMP4"),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return null;
}

const SPATIALMP4_HOME = discoverSpatialmp4Home();

export type RerunStatus = "ok" | "skipped" | "error";

export interface RerunWorkerResult {
  status: RerunStatus;
  reason?: string;
  artifactPath?: string;
  durationMs?: number;
}

export async function runRerunWorker(
  session: SessionRecord,
): Promise<RerunWorkerResult> {
  if (process.env.RERUN_DISABLED === "1") {
    return { status: "skipped", reason: "RERUN_DISABLED=1" };
  }
  const media = session.artifacts["media"];
  if (!media) return { status: "skipped", reason: "no media artifact yet" };
  // Same defense-in-depth as preview.ts: refuse to run on a media
  // artifact the integrity check has already flagged as corrupt.
  if (media.corrupt) {
    return {
      status: "skipped",
      reason: `media flagged corrupt (expected sha256 ${media.expectedSha256 ?? "?"} vs actual ${media.sha256 ?? "?"})`,
    };
  }
  if (session.artifacts["rrd"]) {
    return { status: "skipped", reason: "rrd already exists" };
  }

  try {
    await stat(media.uri);
  } catch {
    return { status: "error", reason: `media file missing on disk: ${media.uri}` };
  }
  const scriptPath = selectRerunScript(session);
  try {
    await stat(scriptPath);
  } catch {
    return { status: "error", reason: `sidecar missing: ${scriptPath}` };
  }

  const sessionDir = path.dirname(media.uri);
  const rrdPath = path.join(sessionDir, "session.rrd");

  const scriptArgs: string[] = [
    "--input", media.uri,
    "--output", rrdPath,
  ];
  if (TOPK_FRAMES) scriptArgs.push("--topk", TOPK_FRAMES);

  const { bin, args } = PYTHON_BIN
    ? { bin: PYTHON_BIN, args: [scriptPath, ...scriptArgs] }
    : {
        bin: UV_BIN,
        // `--script` tells uv to treat the target as a PEP 723 script
        // (resolves inline deps, no project lookup). `--no-project`
        // belt-and-suspenders against uv climbing the tree and picking
        // up some ancestral pyproject.toml. `--python` pins the ABI
        // to whatever the SpatialMP4 SDK was built against.
        args: [
          "run",
          "--script",
          "--no-project",
          "--python", PYTHON_VERSION,
          scriptPath,
          ...scriptArgs,
        ],
      };

  // Forward parent env + the discovered SPATIALMP4_HOME so the
  // sidecar's bootstrap can find the SDK's compiled .so. Anything the
  // user explicitly exports wins (they may have built the SDK
  // somewhere non-standard).
  const childEnv: NodeJS.ProcessEnv = { ...process.env };
  if (SPATIALMP4_HOME && !childEnv.SPATIALMP4_HOME) {
    childEnv.SPATIALMP4_HOME = SPATIALMP4_HOME;
  }
  if (!childEnv.SPATIALMP4_HOME) {
    // eslint-disable-next-line no-console
    console.warn(
      "[workers] rerun: SPATIALMP4_HOME not set and no checkout found under " +
        "OPERATOR_DEPS_CACHE_ROOT/src/SpatialMP4, .deps/src/SpatialMP4, " +
        "~/ws/spatialmp4-quest/SpatialMP4, ~/spatialmp4-quest/SpatialMP4, " +
        "or ~/SpatialMP4. Run scripts/setup_spatialmp4.sh.",
    );
  }

  const started = Date.now();
  const exit = await runChild(bin, args, childEnv);
  const durationMs = Date.now() - started;

  if (exit.code !== 0) {
    return {
      status: "error",
      reason: `${bin} exit ${exit.code}: ${truncate(exit.stderr, 800)}`,
      durationMs,
    };
  }

  let bytes: number;
  try {
    const s = await stat(rrdPath);
    bytes = s.size;
  } catch (err) {
    return {
      status: "error",
      reason: `rrd not produced: ${(err as Error).message}`,
      durationMs,
    };
  }

  await ingest.store.upsertSessionArtifact(session.id, {
    kind: "rrd",
    filename: "session.rrd",
    bytes,
    storedAt: new Date().toISOString(),
    uri: rrdPath,
  });
  ingest.events.emit({
    type: "session.updated",
    session: (await ingest.store.getSession(session.id))!,
  });

  return { status: "ok", artifactPath: rrdPath, durationMs };
}

function selectRerunScript(session: SessionRecord): string {
  return isPicoSession(session) ? PICO_SCRIPT_PATH : DEFAULT_SCRIPT_PATH;
}

function isPicoSession(session: SessionRecord): boolean {
  const manifest = session.manifest;
  if (!isRecord(manifest)) return false;
  const device = manifest["device"];
  if (!isRecord(device)) return false;
  const fields = [
    "device_type",
    "device_model",
    "device_manufacturer",
    "device_build_device",
  ];
  return fields.some((key) => {
    const value = String(device[key] ?? "").toLowerCase();
    return value.includes("pico") || value.includes("picovr");
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function runChild(
  bin: string,
  args: string[],
  env: NodeJS.ProcessEnv = process.env,
): Promise<{ code: number; stderr: string }> {
  return new Promise((resolve) => {
    const proc = spawn(bin, args, {
      stdio: ["ignore", "inherit", "pipe"],
      env,
    });
    let stderr = "";
    proc.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      stderr += text;
      // Tee the sidecar's stderr to ours so progress shows up live in
      // the dev server log instead of only at completion.
      process.stderr.write(text);
    });
    proc.on("error", (err) => {
      // Most common cause: `uv` not on PATH yet.
      // ENOENT → friendlier message than the raw spawn error.
      const hint =
        (err as NodeJS.ErrnoException).code === "ENOENT"
          ? bin === "uv"
            ? " — install with `brew install uv` or https://astral.sh/uv"
            : " — not found on PATH"
          : "";
      resolve({ code: -1, stderr: `spawn ${bin}: ${err.message}${hint}` });
    });
    proc.on("close", (code) => resolve({ code: code ?? -1, stderr }));
  });
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n) + "…";
}
