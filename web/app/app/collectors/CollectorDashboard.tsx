"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";

type Json = Record<string, unknown>;

interface Agent {
  id: string;
  name: string;
  hostname: string;
  platform: string;
  agentVersion: string;
  config: Json;
  state: Json;
  lastSeen: string | null;
  online: boolean;
}

interface Job {
  id: string;
  agentId: string;
  kind: string;
  payload: Json;
  status: string;
  progress: number;
  message: string;
  result: Json | null;
  error: string | null;
  createdAt: string;
}

interface Item {
  id: string;
  agentId: string;
  sourceSessionId: string;
  datasetName: string;
  localPath: string;
  label: string;
  status: string;
  qc: Json;
  hasPreview: boolean;
  previewCount: number;
  previewKind: "images" | "video" | "none";
  upload: Json | null;
}

interface Overview {
  agents: Agent[];
  jobs: Job[];
  items: Item[];
}

interface ScannedSession {
  session_id: string;
  media_bytes?: number;
  has_manifest?: boolean;
  has_sidecars?: boolean;
  source?: string;
  source_path?: string;
}

const EMPTY: Overview = { agents: [], jobs: [], items: [] };

export function CollectorDashboard() {
  const [overview, setOverview] = useState<Overview>(EMPTY);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [deleteAfter, setDeleteAfter] = useState<Record<string, boolean>>({});
  const [labels, setLabels] = useState<Record<string, string>>({});
  const [configs, setConfigs] = useState<Record<string, Json>>({});
  const [selectedItems, setSelectedItems] = useState<Record<string, boolean>>({});

  const refresh = useCallback(async () => {
    try {
      const response = await fetch("/api/collectors/overview", { cache: "no-store" });
      if (!response.ok) throw new Error(await response.text());
      const next = await response.json() as Overview;
      setOverview(next);
      setConfigs((previous) => {
        const merged = { ...previous };
        for (const agent of next.agents) {
          if (!merged[agent.id]) merged[agent.id] = { ...agent.config };
        }
        return merged;
      });
      setLabels((previous) => {
        const merged = { ...previous };
        for (const item of next.items) {
          if (merged[item.id] === undefined) merged[item.id] = item.label;
        }
        return merged;
      });
      setError("");
    } catch (exception) {
      setError(localizeError((exception as Error).message));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 2_000);
    return () => window.clearInterval(timer);
  }, [refresh]);

  async function request(key: string, url: string, init: RequestInit = {}): Promise<boolean> {
    setBusy(key);
    setError("");
    try {
      const response = await fetch(url, {
        ...init,
        headers: { "Content-Type": "application/json", ...(init.headers ?? {}) },
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({ error: response.statusText }));
        throw new Error(String(body.error ?? response.statusText));
      }
      await refresh();
      return true;
    } catch (exception) {
      setError(localizeError((exception as Error).message));
      return false;
    } finally {
      setBusy("");
    }
  }

  async function createJob(agentId: string, kind: string, payload: Json = {}) {
    await request(
      `${agentId}:${kind}:${String(payload.source ?? "")}`,
      `/api/collectors/agents/${agentId}/jobs`,
      { method: "POST", body: JSON.stringify({ kind, payload }) },
    );
  }

  const agentsById = useMemo(
    () => Object.fromEntries(overview.agents.map((agent) => [agent.id, agent])),
    [overview.agents],
  );
  const onlineCount = overview.agents.filter((agent) => agent.online).length;
  const readyCount = overview.items.filter(isUploadable).length;

  if (loading) return <div className="empty-state">正在加载数采工作站…</div>;

  return (
    <div className="collector-page">
      <section className="collector-hero">
        <div className="collector-hero__copy">
          <span className="collector-eyebrow">OPERATOR · DATA DESK</span>
          <h1>数据采集工作台</h1>
          <p>从 Quest 或本机读取数据，快速检查、标记并批量上传到私有仓库。</p>
        </div>
        <div className="collector-counts" aria-label="采集概览">
          <div><strong>{onlineCount}</strong><span>在线工作站</span></div>
          <div><strong>{overview.items.length}</strong><span>本地数据</span></div>
          <div><strong>{readyCount}</strong><span>待上传</span></div>
        </div>
      </section>

      {error && <div className="collector-alert collector-alert--bad" role="alert">{error}</div>}

      <div className="collector-workspace">
        <aside className="collector-sidebar" aria-label="电脑操作提示">
          <div className="collector-sidebar__sticky">
            <section className="collector-guide">
              <div className="collector-guide__head">
                <span>电脑操作提示</span>
                <b>5 步</b>
              </div>
              <ol>
                <li><span>1</span><div><strong>保持 Agent 在线</strong><p>看到工作站“在线”后再操作。</p></div></li>
                <li><span>2</span><div><strong>USB 连接 Quest</strong><p>在头显内允许 USB 调试。</p></div></li>
                <li><span>3</span><div><strong>启动并完成录制</strong><p>Ego 启动后可以拔掉 USB。</p></div></li>
                <li><span>4</span><div><strong>重新连接并读取</strong><p>扫描、校验，再检查图片预览。</p></div></li>
                <li><span>5</span><div><strong>标签并批量上传</strong><p>多选数据，一次加入上传队列。</p></div></li>
              </ol>
            </section>

            <section className="collector-side-note">
              <span className="collector-side-note__mark">私有</span>
              <strong>ModelScope · chenghy666/test</strong>
              <p>上传凭据由 Station 自动安全配置，网页不会显示 token。</p>
            </section>

            <section className="collector-side-note collector-side-note--quiet">
              <strong>没有 Quest 也可以工作</strong>
              <p>设置“本地已有数据集目录”，直接扫描、预览和上传。</p>
            </section>

            <section className="collector-side-jobs">
              <div className="collector-side-jobs__head">
                <div><span className="collector-section-kicker">ACTIVITY</span><strong>最近任务</strong></div>
                <span>{overview.jobs.length}</span>
              </div>
              {overview.jobs.length === 0 ? <p>暂无任务</p> : (
                <div className="collector-side-jobs__list">
                  {overview.jobs.slice(0, 3).map((job) => (
                    <div className="collector-side-job" key={job.id}>
                      <span className={`collector-side-job__dot is-${job.status}`} />
                      <div>
                        <div className="collector-side-job__summary"><strong>{localizeJobKind(job.kind)}</strong><span>{localizeJobStatus(job.status)}</span></div>
                        <small>{agentsById[job.agentId]?.name ?? job.agentId}</small>
                        <div className="collector-side-job__detail"><span>命令</span><code>{formatJobCommand(job)}</code></div>
                        <div className={`collector-side-job__detail collector-side-job__result is-${job.status}`}>
                          <span>结果</span><p>{formatJobResult(job)}</p>
                        </div>
                        {(job.status === "queued" || job.status === "running") && <progress max={1} value={job.progress} />}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </section>
          </div>
        </aside>

        <div className="collector-main">
          {overview.agents.length === 0 ? (
            <section className="panel empty-state">
              <h2>尚未配对数采 Agent</h2>
              <p>安装并启动 Operator Collector，浏览器会自动打开一次性配对页面。</p>
            </section>
          ) : overview.agents.map((agent) => {
            const state = agent.state ?? {};
            const questSessions = asSessions(state.scannedQuestSessions);
            const localSessions = asSessions(state.scannedLocalSessions);
            const config = configs[agent.id] ?? agent.config;
            const agentItems = overview.items.filter((item) => item.agentId === agent.id);
            const uploadableItems = agentItems.filter(isUploadable);
            const selectedIds = uploadableItems.filter((item) => selectedItems[item.id]).map((item) => item.id);
            const allSelected = uploadableItems.length > 0 && selectedIds.length === uploadableItems.length;
            const modelscopeReady = ["ready", "authenticated"].includes(String(state.modelscope ?? ""));
            return (
              <section className="collector-agent" key={agent.id}>
                <div className="collector-agent__head">
                  <div className="collector-agent__identity">
                    <span className={`collector-online-dot ${agent.online ? "is-online" : "is-offline"}`} />
                    <div>
                      <h2>{agent.name}</h2>
                      <div className="collector-muted">{agent.hostname} · {agent.platform} · Agent {agent.agentVersion}</div>
                    </div>
                  </div>
                  <span className={`collector-status ${agent.online ? "is-online" : "is-offline"}`}>
                    {agent.online ? "在线" : "离线"}
                  </span>
                </div>

                <div className="collector-control-deck">
                  <div className="collector-status-grid">
                    <StatusMetric label="Quest" value={localizeState(String(state.quest ?? "unknown"))} good={!String(state.quest ?? "").includes("not")} />
                    <StatusMetric label="ADB" value={localizeState(String(state.adb ?? "unknown"))} good={String(state.adb ?? "") === "ready"} />
                    <StatusMetric label="FFmpeg" value={localizeState(String(state.ffmpeg ?? "unknown"))} good={String(state.ffmpeg ?? "") === "ready"} />
                    <StatusMetric label="Python" value={`${localizeState(String(state.python ?? "unknown"))} · ${String(state.pythonVersion ?? "未知版本")}`} good={String(state.python ?? "") === "ready"} />
                    <StatusMetric label="ModelScope" value={localizeState(String(state.modelscope ?? "unknown"))} good={modelscopeReady} />
                    <StatusMetric label="剩余空间" value={formatBytes(Number(state.freeBytes ?? 0))} good={Number(state.freeBytes ?? 0) > 0} />
                  </div>
                  <div className="collector-actions">
                    <button disabled={!agent.online || busy.startsWith(`${agent.id}:start_ego`)} onClick={() => createJob(agent.id, "start_ego")}>启动 Ego</button>
                    <button disabled={!agent.online || busy === `${agent.id}:scan:quest`} onClick={() => createJob(agent.id, "scan", { source: "quest" })}>扫描 Quest</button>
                    <button className="primary" disabled={!agent.online || busy === `${agent.id}:scan:local`} onClick={() => createJob(agent.id, "scan", { source: "local" })}>扫描本地数据</button>
                  </div>
                </div>

                <details className="collector-settings">
                  <summary><span>工作站设置</span><small>数据目录和 Quest 路径</small></summary>
                  <div className="collector-settings__grid">
                    <label>数据保存目录<input value={String(config.data_root ?? "")} placeholder="例如 /Users/name/OperatorData" onChange={(event) => updateConfig(setConfigs, agent.id, config, "data_root", event.target.value)} /><span>数据保存到该目录的 sessions 子目录。</span></label>
                    <label>本地已有数据集目录<input value={String(config.local_source_root ?? config.fixture_root ?? "")} placeholder="一条数据或包含多条数据的目录" onChange={(event) => updateConfig(setConfigs, agent.id, config, "local_source_root", event.target.value)} /><span>无需连接 Quest 也可以扫描。</span></label>
                    <label>Quest 录制根目录<input value={String(config.quest_root ?? "")} placeholder="/sdcard/DCIM/SpatialMP4" onChange={(event) => updateConfig(setConfigs, agent.id, config, "quest_root", event.target.value)} /></label>
                    <label>ModelScope 目标仓库<input value="chenghy666/test" readOnly /><span>固定私有仓库，无需操作员配置。</span></label>
                    <label>ADB 路径（可选）<input value={String(config.adb_path ?? "")} placeholder="例如 /opt/homebrew/bin/adb" onChange={(event) => updateConfig(setConfigs, agent.id, config, "adb_path", event.target.value)} /></label>
                    <label>FFmpeg 路径（可选）<input value={String(config.ffmpeg_path ?? "")} placeholder="例如 /opt/homebrew/bin/ffmpeg" onChange={(event) => updateConfig(setConfigs, agent.id, config, "ffmpeg_path", event.target.value)} /></label>
                  </div>
                  <button className="primary collector-save" disabled={busy === `${agent.id}:config`} onClick={() => request(`${agent.id}:config`, `/api/collectors/agents/${agent.id}`, { method: "PATCH", body: JSON.stringify({ config }) })}>{busy === `${agent.id}:config` ? "保存中…" : "保存工作站设置"}</button>
                </details>

                <div className="collector-source-grid">
                  <DatasetSourceCard
                    title="本地目录"
                    count={localSessions.length}
                    emptyText="点击“扫描本地数据”，无需连接 Quest。"
                    sessions={localSessions}
                    agent={agent}
                    busy={busy}
                    source="local"
                    onImport={(session) => request(`${agent.id}:import:local:${session.session_id}`, `/api/collectors/agents/${agent.id}/jobs`, { method: "POST", body: JSON.stringify({ kind: "import", payload: { source: "local", source_path: session.source_path, session_id: session.session_id, delete_after: false } }) })}
                  />
                  <DatasetSourceCard
                    title="Quest 录制"
                    count={questSessions.length}
                    emptyText="连接 Quest 后点击“扫描 Quest”。"
                    sessions={questSessions}
                    agent={agent}
                    busy={busy}
                    source="quest"
                    extra={<label className="collector-check"><input type="checkbox" checked={!!deleteAfter[agent.id]} onChange={(event) => setDeleteAfter((previous) => ({ ...previous, [agent.id]: event.target.checked }))} />校验成功后删除 Quest 原数据</label>}
                    onImport={(session) => request(`${agent.id}:import:quest:${session.session_id}`, `/api/collectors/agents/${agent.id}/jobs`, { method: "POST", body: JSON.stringify({ kind: "import", payload: { source: "quest", session_id: session.session_id, delete_after: !!deleteAfter[agent.id] } }) })}
                  />
                </div>

                <section className="collector-library">
                  <div className="collector-library__head">
                    <div><span className="collector-section-kicker">LOCAL LIBRARY</span><h3>已读取的数据</h3></div>
                    <div className="collector-batch-bar">
                      <label className="collector-select-all">
                        <input
                          type="checkbox"
                          checked={allSelected}
                          disabled={uploadableItems.length === 0}
                          onChange={(event) => setSelectedItems((previous) => {
                            const next = { ...previous };
                            for (const item of uploadableItems) next[item.id] = event.target.checked;
                            return next;
                          })}
                        />
                        全选可上传
                      </label>
                      <span>{selectedIds.length} 条已选</span>
                      <button
                        className="primary collector-batch-button"
                        disabled={!agent.online || !modelscopeReady || selectedIds.length === 0 || busy === `${agent.id}:batch-upload`}
                        onClick={async () => {
                          const ok = await request(`${agent.id}:batch-upload`, `/api/collectors/agents/${agent.id}/uploads`, { method: "POST", body: JSON.stringify({ item_ids: selectedIds }) });
                          if (ok) setSelectedItems((previous) => {
                            const next = { ...previous };
                            for (const itemId of selectedIds) delete next[itemId];
                            return next;
                          });
                        }}
                      >{busy === `${agent.id}:batch-upload` ? "正在加入队列…" : `批量上传到私有仓库${selectedIds.length ? `（${selectedIds.length}）` : ""}`}</button>
                    </div>
                  </div>

                  {!modelscopeReady && <div className="collector-inline-note">Agent 正在等待 Station 配置 ModelScope 上传凭据。</div>}

                  {agentItems.length === 0 ? (
                    <div className="collector-library__empty">还没有通过校验的本地数据。</div>
                  ) : (
                    <div className="collector-item-list">
                      {agentItems.map((item) => {
                        const uploadable = isUploadable(item);
                        return (
                          <article className={`collector-item ${selectedItems[item.id] ? "is-selected" : ""}`} key={item.id}>
                            <label className="collector-item__select" title={uploadable ? "选择上传" : "保存标签后可选择"}>
                              <input type="checkbox" aria-label={`选择 ${item.datasetName}`} checked={!!selectedItems[item.id]} disabled={!uploadable} onChange={(event) => setSelectedItems((previous) => ({ ...previous, [item.id]: event.target.checked }))} />
                            </label>
                            <PreviewGallery item={item} />
                            <div className="collector-item__body">
                              <div className="collector-item__topline">
                                <div><div className="collector-item__name">{item.datasetName}</div><div className="collector-muted"><code>{item.sourceSessionId}</code></div></div>
                                <span className={`collector-item__state is-${item.status}`}>{item.status === "uploaded" ? "已上传" : item.label ? "待上传" : "待标签"}</span>
                              </div>
                              <div className="collector-item__path" title={item.localPath}>{item.localPath}</div>
                              <QcSummary qc={item.qc} />
                              <div className="collector-label-row">
                                <input value={labels[item.id] ?? ""} placeholder="输入短标签，例如 wash" onChange={(event) => setLabels((previous) => ({ ...previous, [item.id]: event.target.value }))} />
                                <button disabled={!agent.online || !labels[item.id] || busy === `${item.id}:label`} onClick={() => request(`${item.id}:label`, `/api/collectors/items/${item.id}/label`, { method: "POST", body: JSON.stringify({ label: labels[item.id] }) })}>保存标签并重命名</button>
                              </div>
                              <div className="collector-item-tools">
                                <button
                                  disabled={!agent.online || busy === `${item.id}:preview`}
                                  onClick={() => request(`${item.id}:preview`, `/api/collectors/items/${item.id}/preview`, { method: "POST" })}
                                >{busy === `${item.id}:preview` ? "正在生成…" : item.hasPreview ? "重新生成预览" : "生成预览"}</button>
                                <button
                                  className="danger"
                                  disabled={!agent.online || busy === `${item.id}:delete`}
                                  onClick={async () => {
                                    if (!window.confirm(`确定将 ${item.datasetName} 移到本机回收站吗？`)) return;
                                    const ok = await request(`${item.id}:delete`, `/api/collectors/items/${item.id}`, { method: "DELETE" });
                                    if (ok) setSelectedItems((previous) => {
                                      const next = { ...previous };
                                      delete next[item.id];
                                      return next;
                                    });
                                  }}
                                >{busy === `${item.id}:delete` ? "正在删除…" : "删除本地数据"}</button>
                              </div>
                            </div>
                          </article>
                        );
                      })}
                    </div>
                  )}
                </section>
              </section>
            );
          })}
        </div>
      </div>
    </div>
  );
}

function StatusMetric({ label, value, good }: { label: string; value: string; good: boolean }) {
  return <div className="collector-metric"><span>{label}</span><strong className={good ? "is-good" : ""}>{value}</strong></div>;
}

function PreviewGallery({ item }: { item: Item }) {
  if (item.previewKind === "images" && item.previewCount > 0) {
    return (
      <div className="collector-preview-grid" aria-label={`${item.datasetName} 图片预览`}>
        {Array.from({ length: item.previewCount }, (_, index) => (
          <a key={index} href={`/api/collectors/items/${item.id}/previews/${index}`} target="_blank" rel="noreferrer" title={`第 ${index * 20} 秒`}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img loading="lazy" src={`/api/collectors/items/${item.id}/previews/${index}`} alt={`${item.datasetName} 第 ${index * 20} 秒预览`} />
            <span>{index * 20}s</span>
          </a>
        ))}
      </div>
    );
  }
  if (item.previewKind === "video") {
    return <div className="collector-legacy-preview"><video controls preload="metadata" src={`/api/collectors/items/${item.id}/preview`} /><span>旧版视频预览</span></div>;
  }
  const warning = Array.isArray(item.qc.warnings)
    ? item.qc.warnings.map(String).find((value) => value.includes("预览"))
    : "";
  return <div className="collector-preview-empty"><strong>暂无图片预览</strong><span>{warning ? localizeError(warning) : "前 2 分钟 · 每 20 秒一张"}</span></div>;
}

function DatasetSourceCard({ title, count, emptyText, sessions, agent, busy, source, extra, onImport }: {
  title: string;
  count: number;
  emptyText: string;
  sessions: ScannedSession[];
  agent: Agent;
  busy: string;
  source: "local" | "quest";
  extra?: ReactNode;
  onImport: (session: ScannedSession) => void;
}) {
  return (
    <section className="collector-source-card">
      <div className="collector-card__title"><h3>{title}<span>{count}</span></h3>{extra}</div>
      {sessions.length === 0 ? <div className="collector-source-empty">{emptyText}</div> : (
        <div className="collector-table-wrap"><table className="collector-table"><thead><tr><th>数据 ID</th><th>大小</th><th>完整性</th><th /></tr></thead><tbody>{sessions.map((session) => (
          <tr key={`${source}:${session.source_path ?? session.session_id}`}><td><code>{session.session_id}</code></td><td>{formatBytes(session.media_bytes ?? 0)}</td><td><span className={session.has_manifest && session.has_sidecars ? "collector-complete" : "collector-incomplete"}>{session.has_manifest && session.has_sidecars ? "完整" : "缺文件"}</span></td><td><button className="primary" disabled={!agent.online || busy === `${agent.id}:import:${source}:${session.session_id}`} onClick={() => onImport(session)}>{source === "local" ? "读取" : "导入"}</button></td></tr>
        ))}</tbody></table></div>
      )}
    </section>
  );
}

function QcSummary({ qc }: { qc: Json }) {
  const checks = qc.checks && typeof qc.checks === "object" ? qc.checks as Json : {};
  const warnings = Array.isArray(qc.warnings) ? qc.warnings.map((value) => localizeError(String(value))) : [];
  return <div className="collector-qc"><span className={qc.ok ? "is-good" : "is-bad"}>{qc.ok ? "校验通过" : "需要检查"}</span><span>视频 {checks.media_hash === true ? "✓" : "—"}</span><span>清单 {checks.manifest === true ? "✓" : "—"}</span>{warnings.length > 0 && <span className="is-warn">{warnings.join(" · ")}</span>}</div>;
}

function updateConfig(setter: Dispatch<SetStateAction<Record<string, Json>>>, agentId: string, config: Json, key: string, value: string) {
  setter((previous) => ({ ...previous, [agentId]: { ...config, [key]: value } }));
}

function asSessions(value: unknown): ScannedSession[] { return Array.isArray(value) ? value as ScannedSession[] : []; }
function isUploadable(item: Item): boolean { return !!item.label && item.status !== "uploaded"; }

function localizeState(value: string): string {
  const values: Record<string, string> = { ready: "可用", authenticated: "已登录", "not authenticated": "未登录", fixture: "本地数据模式", "not found": "未找到", "not connected": "未连接", "multiple devices": "连接了多台设备", unknown: "未知" };
  return values[value] ?? value;
}

function localizeJobKind(value: string): string { return ({ scan: "扫描", start_ego: "启动 Ego", import: "读取数据", label: "标签", upload: "上传", preview: "生成预览", delete_local: "删除本地数据" } as Record<string, string>)[value] ?? value; }
function localizeJobStatus(value: string): string { return ({ queued: "等待中", running: "执行中", completed: "已完成", failed: "失败" } as Record<string, string>)[value] ?? value; }

function formatJobCommand(job: Job): string {
  const payload = job.payload ?? {};
  const session = shortValue(payload.session_id);
  const dataset = shortValue(payload.dataset_name) || shortValue(payload.label);
  switch (job.kind) {
    case "scan": return payload.source === "local" ? "扫描本地数据" : "扫描 Quest 数据";
    case "start_ego": return "启动 Quest Ego 录制";
    case "import": return `${payload.source === "local" ? "读取本地数据" : "导入 Quest 数据"}${session ? ` · ${session}` : ""}`;
    case "label": return `保存标签${dataset ? ` · ${dataset}` : ""}`;
    case "upload": return `上传到 ModelScope${dataset ? ` · ${dataset}` : ""}`;
    case "preview": return `生成图片预览${dataset ? ` · ${dataset}` : ""}`;
    case "delete_local": return `删除本地数据${dataset ? ` · ${dataset}` : ""}`;
    default: return localizeJobKind(job.kind);
  }
}

function formatJobResult(job: Job): string {
  if (job.error) return localizeError(job.error);
  if (job.status === "queued") return "等待 Agent 执行";
  if (job.status === "running") return localizeError(job.message || `执行中 · ${Math.round(job.progress * 100)}%`);
  const result = job.result ?? {};
  if (job.kind === "scan" && Array.isArray(result.sessions)) return `完成 · 发现 ${result.sessions.length} 条数据`;
  if (job.kind === "import") {
    const name = shortValue(result.dataset_name);
    return name ? `读取完成 · ${name}` : "读取和校验完成";
  }
  if (job.kind === "label") {
    const name = shortValue(result.dataset_name);
    return name ? `已重命名 · ${name}` : "标签已保存";
  }
  if (job.kind === "upload") {
    const target = shortValue(result.path_in_repo);
    return target ? `上传完成 · ${target}` : "ModelScope 上传完成";
  }
  if (job.kind === "preview" && Array.isArray(result.preview_paths)) return `已生成 ${result.preview_paths.length} 张预览图`;
  if (job.kind === "delete_local") return "已移到本机回收站";
  if (job.kind === "start_ego") return "Ego 已启动";
  return localizeError(job.message || "执行完成");
}

function shortValue(value: unknown): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) return "";
  const leaf = text.split(/[\\/]/).filter(Boolean).pop() ?? text;
  return leaf.length > 40 ? `${leaf.slice(0, 37)}…` : leaf;
}

function localizeError(value: string): string {
  const replacements: Array<[string, string]> = [
    ["Depth requested but missing", "已请求深度数据，但本条录制中缺失"],
    ["completed", "已完成"],
    ["failed", "失败"],
    ["agent unavailable", "Agent 不可用"],
    ["label item before upload", "上传前请先填写并保存标签"],
    ["ModelScope credentials were not provisioned", "Station 尚未向 Agent 配置 ModelScope 凭据"],
    ["Upload job is missing item or local data", "上传失败：本地数据目录不存在"],
    ["adb was not found; install Android Platform Tools", "未找到 ADB，请安装 Android Platform Tools 或填写 ADB 路径"],
    ["adb was not found in the Agent package", "Agent 安装包中未找到 ADB"],
  ];
  let localized = value;
  for (const [source, target] of replacements) localized = localized.replace(source, target);
  return localized;
}

function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit += 1; }
  return `${size.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}
