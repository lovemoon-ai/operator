"use client";

import { useEffect, useState } from "react";

interface Enrollment {
  id: string;
  hostname: string;
  platform: string;
  agentVersion: string;
  expiresAt: string;
  expired: boolean;
  approved: boolean;
  approvedByCurrentUser: boolean;
}

export function EnrollAgent({ enrollmentId }: { enrollmentId: string }) {
  const [enrollment, setEnrollment] = useState<Enrollment | null>(null);
  const [name, setName] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetch(`/api/collectors/enrollments/${encodeURIComponent(enrollmentId)}`)
      .then(async (response) => {
        if (!response.ok) throw new Error(await response.text());
        return response.json() as Promise<Enrollment>;
      })
      .then((value) => { setEnrollment(value); setName(value.hostname); })
      .catch((err) => setError((err as Error).message));
  }, [enrollmentId]);

  async function approve() {
    setBusy(true);
    setError("");
    try {
      const response = await fetch(
        `/api/collectors/enrollments/${encodeURIComponent(enrollmentId)}/approve`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name }),
        },
      );
      if (!response.ok) {
        const body = await response.json().catch(() => ({ error: response.statusText }));
        throw new Error(String(body.error ?? response.statusText));
      }
      window.location.href = "/collectors";
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="collector-enroll">
      <section className="panel">
        <h1>配对数采工作站</h1>
        {error && <div className="collector-alert collector-alert--bad">{error}</div>}
        {!enrollment ? <p>正在读取配对信息…</p> : enrollment.expired ? (
          <p>配对链接已过期，请重新启动 Collector Agent 生成新链接。</p>
        ) : enrollment.approved ? (
          <p>这台工作站已经完成配对。</p>
        ) : (
          <>
            <dl className="kv">
              <dt>电脑名称</dt><dd>{enrollment.hostname}</dd>
              <dt>系统</dt><dd>{enrollment.platform}</dd>
              <dt>Agent 版本</dt><dd>{enrollment.agentVersion}</dd>
              <dt>有效期至</dt><dd>{new Date(enrollment.expiresAt).toLocaleString("zh-CN")}</dd>
            </dl>
            <label>
              工作站显示名称
              <input value={name} onChange={(event) => setName(event.target.value)} />
            </label>
            <button className="primary" disabled={busy || !name.trim()} onClick={approve}>
              {busy ? "正在配对…" : "确认配对"}
            </button>
          </>
        )}
      </section>
    </div>
  );
}
