"use client";

import { useCallback, useEffect, useState } from "react";
import type { StoreStats } from "@love-moon/ego-ingest";

import { fmtBytes } from "@/lib/format";

export function DailyTable({ apiBase }: { apiBase: string }) {
  const [stats, setStats] = useState<StoreStats | null>(null);

  const refresh = useCallback(async () => {
    const r = await fetch(`${apiBase}/stats`);
    if (r.ok) setStats((await r.json()) as StoreStats);
  }, [apiBase]);

  useEffect(() => {
    refresh();
    const tick = () => refresh();
    window.addEventListener("ego:refresh", tick);
    return () => window.removeEventListener("ego:refresh", tick);
  }, [refresh]);

  if (!stats) return <div className="empty-state">Loading…</div>;
  const days = Object.entries(stats.perDay).sort(([a], [b]) => b.localeCompare(a));
  if (days.length === 0) return <div className="empty-state">No data yet.</div>;

  return (
    <table style={{ width: "100%", borderCollapse: "collapse" }}>
      <thead>
        <tr style={{ textAlign: "left", color: "var(--muted)", fontSize: 12 }}>
          <th style={{ padding: "8px 12px" }}>Date</th>
          <th style={{ padding: "8px 12px", textAlign: "right" }}>Sessions</th>
          <th style={{ padding: "8px 12px", textAlign: "right" }}>Bytes</th>
        </tr>
      </thead>
      <tbody>
        {days.map(([day, b]) => (
          <tr key={day} style={{ borderTop: "1px solid var(--border)" }}>
            <td style={{ padding: "8px 12px", fontFamily: "var(--mono)" }}>{day}</td>
            <td style={{ padding: "8px 12px", textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{b.sessions}</td>
            <td style={{ padding: "8px 12px", textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{fmtBytes(b.bytes)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
