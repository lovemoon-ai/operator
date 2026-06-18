/**
 * Preview worker — produces a browser-playable RGB MP4 from the raw
 * SpatialMP4 archive that the headset uploaded.
 *
 * Why this exists:
 *   The XR-side muxer (xr/android_plugin/spatialmp4_muxer) packs a
 *   single MP4 container with:
 *     - 1× HEVC video track (RGB stereo)
 *     - 1× FFV1 lossless track (depth)
 *     - 1× AAC track (audio, optional)
 *     - 'mett' timed-metadata tracks (pose, input, body, replay metadata)
 *
 *   No browser will accept that moov box. `<video src=media.mp4>` either
 *   refuses to parse it or hangs on the first 'mett' sample description.
 *   We can't avoid the issue at the muxer either — the metadata tracks
 *   are the reason the format exists. So we let the original sit on
 *   disk as the source-of-truth archive, and derive a clean H/E/V/C-only
 *   MP4 next to it for in-browser preview.
 *
 * Why remux (`-c copy`) instead of transcode:
 *   - speed: 1 minute of capture takes <1 s of wall time on a Mac
 *   - fidelity: the HEVC bitstream is bit-exact
 *   - small disk: no duplicated pixel data
 *
 * The tradeoff is HEVC playback — Safari and macOS Chrome/Edge handle
 * it natively, Firefox and Linux Chrome don't. Set
 * `PREVIEW_TRANSCODE=1` in the environment to switch to a libx264
 * transcode (~1–3× realtime) for cross-browser compatibility.
 *
 * Stereo handling:
 *   When the manifest sets `capture_options.stereo_rgb = true`, the
 *   RGB track is side-by-side (left half = left eye, right half =
 *   right eye). For a preview pane the user just wants to see what
 *   was captured, so we crop to the left half before encoding. That
 *   requires decoding the HEVC bitstream (a filter graph can't sit
 *   between `-c copy` and the file), so the stereo branch always
 *   transcodes via libx264 regardless of `PREVIEW_TRANSCODE`. Net
 *   result is a half-width, single-eye preview that's ~2× smaller
 *   over the wire and ~2× faster to first-frame in the browser.
 */
import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import path from "node:path";

import type { SessionRecord } from "@love-moon/ego-ingest";

import { ingest } from "../ingest.js";

export type PreviewStatus = "ok" | "skipped" | "error";

export interface PreviewWorkerResult {
  status: PreviewStatus;
  reason?: string;
  artifactPath?: string;
  /** Wall-clock duration of the ffmpeg invocation, in milliseconds. */
  durationMs?: number;
}

const TRANSCODE = process.env.PREVIEW_TRANSCODE === "1";
const FFMPEG_BIN = process.env.FFMPEG_BIN ?? "ffmpeg";

export async function runPreviewWorker(
  session: SessionRecord,
): Promise<PreviewWorkerResult> {
  const media = session.artifacts["media"];
  if (!media) return { status: "skipped", reason: "no media artifact yet" };
  // Defense in depth: the TUS middleware already gates `onSession` on
  // !media.corrupt, but anyone re-running the worker manually (CLI,
  // future REST trigger, …) should hit the same guard.
  if (media.corrupt) {
    return {
      status: "skipped",
      reason: `media flagged corrupt (expected sha256 ${media.expectedSha256 ?? "?"} vs actual ${media.sha256 ?? "?"})`,
    };
  }
  if (session.artifacts["preview"]) {
    return { status: "skipped", reason: "preview already exists" };
  }

  try {
    await stat(media.uri);
  } catch {
    return { status: "error", reason: `media file missing on disk: ${media.uri}` };
  }

  // Preview lives next to the source so cleanup follows session
  // deletion automatically — `data/sessions/<id>/preview.mp4`.
  const sessionDir = path.dirname(media.uri);
  const previewPath = path.join(sessionDir, "preview.mp4");

  // Detect stereo + layout from the manifest the headset uploaded
  // alongside the mp4. `capture_options.stereo_rgb` is the
  // authoritative flag (see xr/scripts/ego_uploader.gd + the JNI
  // muxer). Layout defaults to side-by-side L|R which is what
  // SpatialMp4Native currently produces; if a future muxer variant
  // packs top|bottom or right|left, the manifest can override via
  // `capture_options.stereo_layout` (sbs_lr | sbs_rl | tb_lr | tb_rl).
  const stereo = detectStereo(session);
  let args: string[];
  let mode: "remux" | "transcode" | "crop";
  if (stereo) {
    args = cropEyeArgs(media.uri, previewPath, stereo);
    mode = `crop:${stereo}` as "crop";
  } else if (TRANSCODE) {
    args = transcodeArgs(media.uri, previewPath);
    mode = "transcode";
  } else {
    args = remuxArgs(media.uri, previewPath);
    mode = "remux";
  }
  // eslint-disable-next-line no-console
  console.log(`[workers] preview ${session.id}: ffmpeg mode=${mode}`);

  const started = Date.now();
  const exit = await runFfmpeg(args);
  const durationMs = Date.now() - started;

  if (exit.code !== 0) {
    return {
      status: "error",
      reason: `ffmpeg exit ${exit.code}: ${truncate(exit.stderr, 500)}`,
      durationMs,
    };
  }

  let bytes: number;
  try {
    const s = await stat(previewPath);
    bytes = s.size;
  } catch (err) {
    return {
      status: "error",
      reason: `preview not produced: ${(err as Error).message}`,
      durationMs,
    };
  }

  await ingest.store.upsertSessionArtifact(session.id, {
    kind: "preview",
    filename: "preview.mp4",
    bytes,
    storedAt: new Date().toISOString(),
    uri: previewPath,
  });
  ingest.events.emit({
    type: "session.updated",
    session: (await ingest.store.getSession(session.id))!,
  });

  return { status: "ok", artifactPath: previewPath, durationMs };
}

/** Stream-copy remux: fastest, keeps HEVC, drops FFV1 + mett tracks. */
function remuxArgs(input: string, output: string): string[] {
  return [
    "-y",
    "-loglevel", "error",
    "-i", input,
    // Take the first video track (RGB HEVC) and audio if present.
    // Leaving depth (FFV1) and metadata ('mett') out is the whole point.
    "-map", "0:v:0",
    "-map", "0:a?",
    "-c", "copy",
    // Put moov at the head so the browser can begin playback before
    // the whole file is downloaded.
    "-movflags", "+faststart",
    output,
  ];
}

type StereoLayout = "sbs_lr" | "sbs_rl" | "tb_lr" | "tb_rl";

/**
 * Stereo crop: extract the "primary eye" half of a packed-stereo
 * video and re-encode to H.264. The four layout variants:
 *
 *   sbs_lr  ─ side-by-side, left then right  →  crop left half
 *   sbs_rl  ─ side-by-side, right then left  →  crop right half
 *   tb_lr   ─ top-bottom,  left then right   →  crop top half
 *   tb_rl   ─ top-bottom,  right then left   →  crop bottom half
 *
 * libx264 ultrafast keeps wall-clock close to remux speed while
 * halving the output size and ditching HEVC for max browser
 * compatibility (a free win, since we're already paying the decode).
 */
function cropEyeArgs(
  input: string,
  output: string,
  layout: StereoLayout,
): string[] {
  // ffmpeg crop:  crop=w:h:x:y
  const filter: Record<StereoLayout, string> = {
    sbs_lr: "crop=in_w/2:in_h:0:0",
    sbs_rl: "crop=in_w/2:in_h:in_w/2:0",
    tb_lr: "crop=in_w:in_h/2:0:0",
    tb_rl: "crop=in_w:in_h/2:0:in_h/2",
  };
  return [
    "-y",
    "-loglevel", "error",
    "-i", input,
    "-map", "0:v:0",
    "-map", "0:a?",
    "-filter:v", filter[layout],
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-crf", "26",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-movflags", "+faststart",
    output,
  ];
}

/** Cross-browser transcode fallback — libx264 + AAC. */
function transcodeArgs(input: string, output: string): string[] {
  return [
    "-y",
    "-loglevel", "error",
    "-i", input,
    "-map", "0:v:0",
    "-map", "0:a?",
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-crf", "23",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-movflags", "+faststart",
    output,
  ];
}

function runFfmpeg(args: string[]): Promise<{ code: number; stderr: string }> {
  return new Promise((resolve, reject) => {
    const proc = spawn(FFMPEG_BIN, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    proc.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    proc.on("error", (err) => {
      // ENOENT etc. — surface as a friendlier error than letting the
      // promise reject. Caller already logs `reason`.
      resolve({ code: -1, stderr: `spawn ${FFMPEG_BIN}: ${err.message}` });
    });
    proc.on("close", (code) => resolve({ code: code ?? -1, stderr }));
    // Defensive: spawn errors raise both `error` and a non-zero
    // `close` on some Node versions, so reject on neither is wrong.
    void reject;
  });
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n) + "…";
}

/**
 * Pull stereo flag + layout out of the session manifest. Returns the
 * concrete layout to crop, or `null` if mono (treats anything
 * unknown as mono — safer than guessing wrong and mangling the
 * preview).
 *
 *   capture_options.stereo_rgb: true               → defaults to sbs_lr
 *   capture_options.stereo_layout: "sbs_lr" | ...  → explicit override
 */
function detectStereo(session: SessionRecord): StereoLayout | null {
  const opts = (session.manifest as
    | { capture_options?: { stereo_rgb?: unknown; stereo_layout?: unknown } }
    | undefined)?.capture_options;
  if (!opts || opts.stereo_rgb !== true) return null;
  const explicit = typeof opts.stereo_layout === "string"
    ? opts.stereo_layout.toLowerCase()
    : "";
  if (explicit === "sbs_lr" || explicit === "sbs_rl" || explicit === "tb_lr" || explicit === "tb_rl") {
    return explicit;
  }
  // Default for current Quest3 muxer: side-by-side, left first.
  return "sbs_lr";
}
