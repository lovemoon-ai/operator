import { notFound } from "next/navigation";
import Link from "next/link";

import { ingest } from "@/lib/ingest";
import { getReview } from "@/lib/reviews";
import { fmtBytes, fmtDate } from "@/lib/format";

import { ReviewForm } from "./ReviewForm";

interface PageProps {
  params: Promise<{ id: string }>;
}

// Server-rendered detail. We read directly from the in-process ingest
// store (lib/ingest.ts) rather than HTTP-fetching our own /api/ingest-read
// endpoint — same data, one less hop, no port-number coupling. If you
// ever split the ingest into a separate process, swap this for a fetch
// against the remote read API.
export const dynamic = "force-dynamic";

export default async function SessionDetailPage({ params }: PageProps) {
  const { id } = await params;
  const session = await ingest.store.getSession(id);
  if (!session) notFound();
  const review = getReview(id);
  const mediaUrl = session.artifacts["media"]
    ? `/api/ingest-read/sessions/${encodeURIComponent(id)}/artifacts/media`
    : null;

  return (
    <div style={{ display: "grid", gap: 16 }}>
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

      {mediaUrl && (
        <section className="panel">
          <h2>Playback</h2>
          <video className="video-frame" controls src={mediaUrl} />
          <p style={{ fontSize: 11, color: "var(--muted)", marginTop: 8 }}>
            Browser playback depends on HEVC support. Chrome on macOS and Safari
            handle it natively; on Linux you may need to download and play with
            ffmpeg/VLC.
          </p>
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
