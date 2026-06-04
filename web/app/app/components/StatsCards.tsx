"use client";

import { useCallback, useEffect, useState } from "react";
import type { StoreStats } from "@love-moon/ego-ingest";

import { fmtBytes } from "@/lib/format";

export function StatsCards({ apiBase }: { apiBase: string }) {
  const [stats, setStats] = useState<StoreStats | null>(null);

  const refresh = useCallback(async () => {
    try {
      const r = await fetch(`${apiBase}/stats`);
      if (r.ok) setStats((await r.json()) as StoreStats);
    } catch {
      /* ignore */
    }
  }, [apiBase]);

  useEffect(() => {
    refresh();
    const tick = () => refresh();
    window.addEventListener("ego:refresh", tick);
    const interval = setInterval(refresh, 30_000);
    return () => {
      window.removeEventListener("ego:refresh", tick);
      clearInterval(interval);
    };
  }, [refresh]);

  const last7d = stats ? sum7d(stats) : 0;
  return (
    <div className="stats">
      <div className="stat">
        <div className="label">Sessions</div>
        <div className="value">{stats?.sessionCount ?? "–"}</div>
      </div>
      <div className="stat">
        <div className="label">Total size</div>
        <div className="value">{stats ? fmtBytes(stats.totalBytes) : "–"}</div>
      </div>
      <div className="stat">
        <div className="label">Last 7 days</div>
        <div className="value">{fmtBytes(last7d)}</div>
      </div>
    </div>
  );
}

function sum7d(stats: StoreStats): number {
  const now = new Date();
  let total = 0;
  for (let i = 0; i < 7; i += 1) {
    const d = new Date(now.getTime() - i * 86_400_000);
    const key = d.toISOString().slice(0, 10);
    const bucket = stats.perDay[key];
    if (bucket) total += bucket.bytes;
  }
  return total;
}
