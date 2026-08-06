"use client";

import { useEffect, useState } from "react";

type MemWorldStatus = Record<string, unknown>;

const STATUS_INTERVAL_MS = 500;
const MODEL_INTERVAL_MS = 50;
const SKELETON_INTERVAL_MS = 200;

export function MemWorldPanel() {
  const [status, setStatus] = useState<MemWorldStatus | null>(null);
  const [error, setError] = useState("");
  const [modelRevision, setModelRevision] = useState(0);
  const [skeletonRevision, setSkeletonRevision] = useState(0);

  useEffect(() => {
    let stopped = false;

    async function refreshStatus() {
      try {
        const response = await fetch("/api/memworld/status", {
          cache: "no-store",
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const nextStatus = (await response.json()) as MemWorldStatus;
        if (!stopped) {
          setStatus(nextStatus);
          setError("");
        }
      } catch (caught) {
        if (!stopped) {
          setError(caught instanceof Error ? caught.message : String(caught));
        }
      }
    }

    void refreshStatus();
    const statusTimer = window.setInterval(refreshStatus, STATUS_INTERVAL_MS);
    const modelTimer = window.setInterval(
      () => setModelRevision(Date.now()),
      MODEL_INTERVAL_MS,
    );
    const skeletonTimer = window.setInterval(
      () => setSkeletonRevision(Date.now()),
      SKELETON_INTERVAL_MS,
    );
    return () => {
      stopped = true;
      window.clearInterval(statusTimer);
      window.clearInterval(modelTimer);
      window.clearInterval(skeletonTimer);
    };
  }, []);

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <section className="panel">
        <h2>MemWorld live</h2>
        <p style={{ margin: 0, color: "var(--muted)" }}>
          Quest pose → workstation gateway → NV worker → generated video
        </p>
      </section>

      <div className="grid-2">
        <section className="panel">
          <h2>Generated video</h2>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            alt="MemWorld generated video"
            src={`/api/memworld/model.jpg?t=${modelRevision}`}
            style={{
              width: "100%",
              aspectRatio: "640 / 352",
              objectFit: "contain",
              background: "#000",
              borderRadius: 8,
            }}
          />
        </section>

        <div style={{ display: "grid", gap: 16 }}>
          <section className="panel">
            <h2>Projected hands</h2>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              alt="Projected Quest hands"
              src={`/api/memworld/skeleton.jpg?t=${skeletonRevision}`}
              style={{
                width: "100%",
                aspectRatio: "640 / 352",
                objectFit: "contain",
                background: "#000",
                borderRadius: 8,
              }}
            />
          </section>

          <section className="panel">
            <h2>Status</h2>
            <pre className="manifest-pre" style={{ margin: 0 }}>
              {error
                ? `gateway unavailable: ${error}`
                : JSON.stringify(status ?? { state: "waiting" }, null, 2)}
            </pre>
          </section>
        </div>
      </div>
    </div>
  );
}
