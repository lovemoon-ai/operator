import { notFound, redirect } from "next/navigation";
import Link from "next/link";

import { getServerComponentUser } from "@/lib/auth/server-component";
import { ingest } from "@/lib/ingest";
import { getReview } from "@/lib/reviews";
import { fmtBytes, fmtDate } from "@/lib/format";

import { ReviewForm } from "./ReviewForm";
import { RerunViewer } from "./RerunViewer";
import { SessionLiveRefresh } from "./SessionLiveRefresh";
import { WorkerPendingIndicator } from "./WorkerPendingIndicator";

interface PageProps {
  params: Promise<{ id: string }>;
}

/**
 * Server-rendered session detail.
 *
 * We hit the SqliteStore directly. The Next-15 "two MemoryStore
 * instances" hazard that previously forced a loopback fetch is gone
 * — SQLite is file-backed, so any number of in-process Database
 * handles see the same rows. Skipping the round-trip also fixes the
 * "loopback fetch has no cookie → 401 from the user-scoped read API"
 * problem we'd otherwise hit now that the read API is authenticated.
 *
 * The current user is read from AsyncLocalStorage, bound by the
 * Express `browserAuthMiddleware` wrapper around handleNext().
 */
export const dynamic = "force-dynamic";

export default async function SessionDetailPage({ params }: PageProps) {
  const { id } = await params;
  const user = await getServerComponentUser();
  if (!user) redirect(`/login?returnTo=/sessions/${encodeURIComponent(id)}`);
  const session = await ingest.store.getSession(id, { userId: user.id });
  if (!session) notFound();
  const review = getReview(id);
  const mediaArtifact = session.artifacts["media"];
  // Corrupt media disables every downstream render path so the user
  // never looks at a half-baked preview / rrd derived from bad bytes.
  // The bytes themselves stay on disk (under Artifacts) for forensics.
  const mediaCorrupt = !!mediaArtifact?.corrupt;
  // The XR uploader sends two artifacts per session: manifest first,
  // then media. If we have a manifest but no media, the second upload
  // never started or was abandoned mid-flight — the visualization
  // panels would be silently empty without this banner.
  const mediaMissing = !mediaArtifact;

  // Prefer the derived "preview" artifact (clean H.264/HEVC MP4 with
  // just the RGB track) over the raw SpatialMP4 — the latter holds
  // FFV1 depth + 7 'mett' tracks that no browser will play. While the
  // preview worker is still running (first ~1 s after upload) we fall
  // back to the raw "media" so at least Safari has something to try.
  // Only show a Playback panel when we have the DERIVED preview MP4
  // ready. Falling back to the raw SpatialMP4 used to be the plan
  // but in practice that file's container holds FFV1 depth + 7 mett
  // metadata tracks; many browsers refuse to parse it and the
  // <video> tag just shows a black frame with no error. Better to
  // hide the section and let the WorkerPendingIndicator below say
  // "preview generating" honestly.
  // Corrupt media also disables the panel — same reason as before:
  // never let the user look at bytes the integrity check rejected.
  const playbackUrl = !mediaCorrupt && session.artifacts["preview"]
    ? `/api/ingest-read/sessions/${encodeURIComponent(id)}/artifacts/preview`
    : null;
  // Append `/session.rrd` so the URL ends in `.rrd` — Rerun 0.33's
  // URL categorizer (Rust `url` crate inside the WASM viewer) rejects
  // HTTP sources whose path doesn't end in that extension. The ingest
  // read API maps the extra path segment to the same artifact byte
  // stream (see the `:filename?` route in ego-ingest/src/api.ts).
  const rrdUrl = !mediaCorrupt && session.artifacts["rrd"]
    ? `/api/ingest-read/sessions/${encodeURIComponent(id)}/artifacts/rrd/session.rrd`
    : null;
  const previewPending =
    !!mediaArtifact && !mediaCorrupt && !session.artifacts["preview"];
  const rrdPending = !!mediaArtifact && !mediaCorrupt && !session.artifacts["rrd"];

  return (
    <div style={{ display: "grid", gap: 16 }}>
      {/* Auto-refresh this page whenever workers append new artifacts
          to this session (preview → rrd → …). Silent; renders no UI. */}
      <SessionLiveRefresh sessionId={session.id} />
      <Link href="/" style={{ fontSize: 12 }}>← All sessions</Link>

      <section className="panel">
        <h2>Session</h2>
        <dl className="kv">
          <dt>Session ID</dt>
          <dd>{session.id}</dd>
          <dt>Received</dt>
          <dd>{fmtDate(session.receivedAt)}</dd>
          <dt>Total size</dt>
          <dd>{fmtBytes(session.totalBytes)}</dd>
          <dt>Artifacts</dt>
          <dd>{Object.keys(session.artifacts).length}</dd>
        </dl>
      </section>

      {mediaCorrupt && (
        <section className="panel" style={{ borderColor: "rgba(248,81,73,0.5)" }}>
          <h2 style={{ color: "var(--bad)" }}>Media corrupt — integrity check failed</h2>
          <p style={{ fontSize: 13, lineHeight: 1.5, margin: 0 }}>
            The server-computed SHA-256 of <code>media.mp4</code> does NOT match
            the hash the headset declared in <code>manifest.json</code>. The
            bytes are still on disk (see Artifacts) for forensics, but the
            preview MP4 and Rerun visualization have been disabled so nobody
            looks at a half-broken file by accident.
          </p>
          <dl className="kv" style={{ marginTop: 12 }}>
            <dt>expected</dt>
            <dd>{mediaArtifact?.expectedSha256 ?? "(none)"}</dd>
            <dt>actual</dt>
            <dd>{mediaArtifact?.sha256 ?? "(none)"}</dd>
          </dl>
          <p style={{ fontSize: 12, color: "var(--muted)", marginTop: 12 }}>
            Most likely a flaky network path corrupted bytes in flight (the TUS
            chunk hit the declared Content-Length but the proxy garbled the
            body). Have the headset re-upload this session — the worker will
            re-fire as soon as the fresh upload's hash matches.
          </p>
        </section>
      )}

      {mediaMissing && (
        <section className="panel" style={{ borderColor: "rgba(248,81,73,0.5)" }}>
          <h2 style={{ color: "var(--bad)" }}>
            {session.expired ? "Upload abandoned" : "Incomplete upload"}
          </h2>
          <p style={{ fontSize: 13, lineHeight: 1.5, margin: 0 }}>
            Only the <code>manifest.json</code> arrived for this session — the
            companion <code>media.mp4</code> never reached the server, so
            there&apos;s nothing to play back or visualize.
            {session.expired && (
              <>
                {" "}
                The orphan watchdog gave up at{" "}
                <code>{fmtDate(session.expired.at)}</code> ({session.expired.reason}).
              </>
            )}
          </p>
          <p style={{ fontSize: 12, color: "var(--muted)", marginTop: 12 }}>
            Common causes:
          </p>
          <ul style={{ fontSize: 12, color: "var(--muted)", marginTop: 4, paddingLeft: 20 }}>
            <li>Recording was stopped before the mp4 finalized on disk.</li>
            <li>The headset never queued the media artifact (check
              <code> adb logcat | grep -iE &quot;ego|upload&quot;</code> on the device).</li>
            <li>The expected file path
              {(() => {
                const m = session.manifest as { output_mp4_path?: string } | undefined;
                return m?.output_mp4_path ? <> (<code>{m.output_mp4_path}</code>)</> : null;
              })()} doesn&apos;t exist on the headset.</li>
            <li>A network blip after manifest landed but before TUS resumed
              media (re-trigger upload from the headset to retry).</li>
          </ul>
        </section>
      )}

      {(playbackUrl || previewPending) && (
        <section className="panel">
          <h2>Playback</h2>
          {playbackUrl ? (
            <>
              <video className="video-frame" controls src={playbackUrl} />
              <p style={{ fontSize: 11, color: "var(--muted)", marginTop: 8 }}>
                Showing the derived RGB preview (left-eye crop + H.264). The raw
                SpatialMP4 with depth + pose tracks is still available under
                Artifacts.
              </p>
            </>
          ) : (
            <WorkerPendingIndicator
              worker="preview"
              startedAtIso={mediaArtifact!.storedAt}
              mediaBytes={mediaArtifact!.bytes}
            />
          )}
        </section>
      )}

      {(rrdUrl || rrdPending) && (
        <section className="panel">
          <h2>Rerun visualization</h2>
          {rrdUrl ? (
            <RerunViewer rrdUrl={rrdUrl} />
          ) : (
            // Rrd worker only starts AFTER preview finishes (the
            // orchestrator runs them sequentially). Use the preview
            // artifact's storedAt as the baseline whenever available
            // so "Elapsed Ns" matches what the rrd worker is actually
            // doing, not the preview time we already accounted for.
            <WorkerPendingIndicator
              worker="rrd"
              startedAtIso={
                session.artifacts["preview"]?.storedAt ?? mediaArtifact!.storedAt
              }
              mediaBytes={mediaArtifact!.bytes}
            />
          )}
        </section>
      )}

      <section className="panel">
        <h2>Review</h2>
        <ReviewForm sessionId={session.id} initial={review} />
      </section>

      <section className="panel">
        <h2>Artifacts</h2>
        <div style={{ display: "grid", gap: 8 }}>
          {Object.entries(session.artifacts).map(([kind, a]) => (
            <div className="artifact" key={kind}>
              <span className="kind">{kind}</span>
              <span className="filename">
                {a.filename || "(unnamed)"}
                {a.sha256 && (
                  <span style={{ display: "block", fontSize: 10, opacity: 0.6 }}>
                    sha256: {a.sha256}
                  </span>
                )}
              </span>
              <span className="bytes">{fmtBytes(a.bytes)}</span>
              <a href={`/api/ingest-read/sessions/${encodeURIComponent(session.id)}/artifacts/${encodeURIComponent(kind)}`}>
                download
              </a>
            </div>
          ))}
        </div>
      </section>

      {session.manifest && (
        <section className="panel">
          <h2>manifest.json</h2>
          <pre className="manifest-pre">{JSON.stringify(session.manifest, null, 2)}</pre>
        </section>
      )}
    </div>
  );
}
