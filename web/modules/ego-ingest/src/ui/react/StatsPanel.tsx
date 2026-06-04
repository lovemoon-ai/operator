import { useCallback, useEffect, useState } from "react";

import type { StoreStats } from "../../store/index.js";
import { fmtBytes } from "./format.js";
import { useIngestEvents } from "./useIngestEvents.js";

export interface StatsPanelProps {
  apiBase: string;
  /** "7d" | "30d" | "all". Defaults to "7d". */
  range?: "7d" | "30d" | "all";
  /** Refresh interval ms; SSE events also trigger refresh. Default 30 s. */
  refreshMs?: number;
}

export function StatsPanel({ apiBase, range = "7d", refreshMs = 30_000 }: StatsPanelProps) {
  const [stats, setStats] = useState<StoreStats | null>(null);

  const refresh = useCallback(async () => {
    try {
      const r = await fetch(`${apiBase.replace(/\/+$/, "")}/stats`);
      if (!r.ok) throw new Error();
      setStats((await r.json()) as StoreStats);
    } catch {
      /* ignore */
    }
  }, [apiBase]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, refreshMs);
    return () => clearInterval(t);
  }, [refresh, refreshMs]);

  useIngestEvents(apiBase, (ev) => {
    if (ev.type === "session.updated") refresh();
  });

  const rangeBytes = stats ? bytesInRange(stats, range) : 0;
  const rangeSessions = stats ? sessionsInRange(stats, range) : 0;

  return (
    <div
      className="ego-stats-panel"
      style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 12 }}
    >
      <Stat label="Sessions" value={stats ? String(stats.sessionCount) : "–"} />
      <Stat label="Total size" value={stats ? fmtBytes(stats.totalBytes) : "–"} />
      <Stat label={`${range} sessions`} value={String(rangeSessions)} />
      <Stat label={`${range} size`} value={fmtBytes(rangeBytes)} />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div
      className="ego-stat"
      style={{ background: "rgba(255,255,255,0.04)", borderRadius: 8, padding: 12 }}
    >
      <div style={{ fontSize: 11, opacity: 0.6, textTransform: "uppercase", letterSpacing: "0.04em", marginBottom: 4 }}>
        {label}
      </div>
      <div style={{ fontSize: 22, fontWeight: 600, fontVariantNumeric: "tabular-nums" }}>{value}</div>
    </div>
  );
}

function bytesInRange(stats: StoreStats, range: "7d" | "30d" | "all"): number {
  if (range === "all") return stats.totalBytes;
  const days = range === "7d" ? 7 : 30;
  return sumDays(stats, days, (b) => b.bytes);
}

function sessionsInRange(stats: StoreStats, range: "7d" | "30d" | "all"): number {
  if (range === "all") return stats.sessionCount;
  const days = range === "7d" ? 7 : 30;
  return sumDays(stats, days, (b) => b.sessions);
}

function sumDays(stats: StoreStats, days: number, pick: (b: { sessions: number; bytes: number }) => number): number {
  const now = new Date();
  let total = 0;
  for (let i = 0; i < days; i++) {
    const d = new Date(now.getTime() - i * 86_400_000);
    const key = d.toISOString().slice(0, 10);
    const bucket = stats.perDay[key];
    if (bucket) total += pick(bucket);
  }
  return total;
}
