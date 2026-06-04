// Single-file dashboard. Kept as a template literal so consumers don't
// need a bundler to serve it. If we ever grow into a "real" React app
// the migration is straightforward — same API surface, swap out html.ts
// for a Vite build.
//
// Design rules:
//   - No external scripts or fonts. Air-gapped labs sometimes serve
//     this on a LAN with no internet, and a missing CDN ruins their day.
//   - One CSS file inline, no preprocessor. Anyone can fork and tweak.
//   - SSE for live updates. Falls back gracefully (the page still loads
//     and the user can refresh) if the EventSource fails.

export function dashboardHtml(opts: { apiBase: string; title: string }): string {
  const { apiBase, title } = opts;
  // JSON-encode for safe embedding in the inline script.
  const cfg = JSON.stringify({ apiBase, title });
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
:root {
  color-scheme: dark;
  --bg: #0d1014;
  --panel: #161b22;
  --panel-2: #1f2730;
  --border: #2c343d;
  --text: #e6edf3;
  --muted: #8b949e;
  --accent: #58a6ff;
  --good: #3fb950;
  --warn: #d29922;
  --bad: #f85149;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
header { padding: 16px 24px; border-bottom: 1px solid var(--border); display: flex; align-items: baseline; gap: 16px; }
header h1 { margin: 0; font-size: 18px; font-weight: 600; }
header .live { font-size: 12px; color: var(--muted); margin-left: auto; display: flex; align-items: center; gap: 6px; }
header .live::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
header .live[data-connected="true"]::before { background: var(--good); box-shadow: 0 0 6px var(--good); }
main { display: grid; grid-template-columns: minmax(360px, 1fr) minmax(420px, 2fr); gap: 16px; padding: 16px 24px; min-height: calc(100vh - 64px); }
.panel { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
.panel h2 { margin: 0 0 12px; font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 16px; }
.stat { background: var(--panel-2); border-radius: 8px; padding: 12px; }
.stat .label { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; margin-bottom: 4px; }
.stat .value { font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; }
.sessions { display: flex; flex-direction: column; gap: 6px; max-height: calc(100vh - 280px); overflow: auto; }
.session-row { background: var(--panel-2); border: 1px solid transparent; border-radius: 8px; padding: 10px 12px; cursor: pointer; display: flex; flex-direction: column; gap: 4px; }
.session-row:hover { border-color: var(--accent); }
.session-row[data-active="true"] { border-color: var(--accent); background: #1d2733; }
.session-row .id { font-family: var(--mono); font-size: 12px; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.session-row .meta { font-size: 11px; color: var(--muted); display: flex; gap: 12px; }
.detail .empty { color: var(--muted); font-style: italic; padding: 32px; text-align: center; }
.detail dl { display: grid; grid-template-columns: 140px 1fr; gap: 4px 16px; margin: 0 0 16px; }
.detail dt { color: var(--muted); font-size: 12px; }
.detail dd { margin: 0; font-family: var(--mono); font-size: 12px; word-break: break-all; }
.artifacts { display: flex; flex-direction: column; gap: 8px; margin-top: 12px; }
.artifact { background: var(--panel-2); border-radius: 8px; padding: 10px 12px; display: flex; align-items: center; gap: 12px; }
.artifact .kind { font-weight: 600; min-width: 80px; }
.artifact .filename { font-family: var(--mono); font-size: 12px; color: var(--muted); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.artifact .bytes { font-variant-numeric: tabular-nums; font-size: 12px; color: var(--muted); }
.artifact a { color: var(--accent); text-decoration: none; font-size: 12px; }
.artifact a:hover { text-decoration: underline; }
.manifest { background: var(--panel-2); border-radius: 8px; padding: 12px; max-height: 260px; overflow: auto; font-family: var(--mono); font-size: 11px; white-space: pre-wrap; word-break: break-all; }
.progress-banner { background: #1d2733; border: 1px solid var(--accent); border-radius: 8px; padding: 10px 12px; margin-bottom: 12px; font-size: 12px; }
.progress-banner .bar { height: 4px; background: var(--panel); border-radius: 2px; margin-top: 6px; overflow: hidden; }
.progress-banner .bar > div { height: 100%; background: var(--accent); transition: width 200ms ease; }
.empty-state { padding: 48px 16px; text-align: center; color: var(--muted); }
.empty-state code { background: var(--panel-2); padding: 2px 6px; border-radius: 4px; font-size: 12px; }
</style>
</head>
<body>
<header>
  <h1>${escapeHtml(title)}</h1>
  <span class="live" id="live" data-connected="false">live</span>
</header>
<main>
  <section class="panel">
    <div class="stats" id="stats">
      <div class="stat"><div class="label">Sessions</div><div class="value" id="stat-sessions">–</div></div>
      <div class="stat"><div class="label">Total size</div><div class="value" id="stat-bytes">–</div></div>
      <div class="stat"><div class="label">Last 7 days</div><div class="value" id="stat-recent">–</div></div>
    </div>
    <h2>Sessions</h2>
    <div id="progress-banner"></div>
    <div class="sessions" id="sessions"></div>
  </section>
  <section class="panel detail">
    <h2>Session detail</h2>
    <div id="detail">
      <div class="empty">Select a session on the left to inspect.</div>
    </div>
  </section>
</main>
<script>
const CFG = ${cfg};

const fmtBytes = (n) => {
  if (!Number.isFinite(n)) return "–";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(n >= 100 ? 0 : 1) + " " + u[i];
};
const fmtDate = (iso) => {
  if (!iso) return "–";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleString();
};
const escape = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

let activeId = null;
let sessions = [];          // most-recent first
let progress = new Map();   // resourceId -> {offset, length, sessionId?}

async function refreshSessions() {
  const r = await fetch(CFG.apiBase + "/sessions?limit=200");
  if (!r.ok) return;
  const page = await r.json();
  sessions = page.items;
  renderSessions();
  if (activeId) renderDetail(sessions.find(s => s.id === activeId));
}

async function refreshStats() {
  const r = await fetch(CFG.apiBase + "/stats");
  if (!r.ok) return;
  const s = await r.json();
  document.getElementById("stat-sessions").textContent = String(s.sessionCount);
  document.getElementById("stat-bytes").textContent = fmtBytes(s.totalBytes);
  const sevenDayBytes = recent7d(s.perDay);
  document.getElementById("stat-recent").textContent = fmtBytes(sevenDayBytes);
}

function recent7d(perDay) {
  const now = new Date();
  let total = 0;
  for (let i = 0; i < 7; i++) {
    const d = new Date(now.getTime() - i * 86400000);
    const key = d.toISOString().slice(0, 10);
    if (perDay && perDay[key]) total += perDay[key].bytes;
  }
  return total;
}

function renderSessions() {
  const root = document.getElementById("sessions");
  if (!sessions.length) {
    root.innerHTML =
      '<div class="empty-state">No sessions yet.<br><br>Upload to <code>' +
      escape(CFG.apiBase.replace(/\\/api$/, "")) +
      '</code> from your XR headset.</div>';
    return;
  }
  root.innerHTML = sessions.map(s => {
    const active = s.id === activeId ? "true" : "false";
    return (
      '<div class="session-row" data-id="' + escape(s.id) + '" data-active="' + active + '">' +
        '<div class="id">' + escape(s.id) + '</div>' +
        '<div class="meta"><span>' + fmtDate(s.receivedAt) + '</span><span>' + fmtBytes(s.totalBytes) +
        '</span><span>' + Object.keys(s.artifacts).length + ' artifact(s)</span></div>' +
      '</div>'
    );
  }).join("");
  root.querySelectorAll(".session-row").forEach(el => {
    el.addEventListener("click", () => {
      activeId = el.dataset.id;
      renderSessions();
      renderDetail(sessions.find(s => s.id === activeId));
    });
  });
}

function renderDetail(session) {
  const root = document.getElementById("detail");
  if (!session) {
    root.innerHTML = '<div class="empty">Select a session on the left to inspect.</div>';
    return;
  }
  const artifactsHtml = Object.entries(session.artifacts).map(([kind, a]) => {
    const dl = CFG.apiBase + "/sessions/" + encodeURIComponent(session.id) + "/artifacts/" + encodeURIComponent(kind);
    return (
      '<div class="artifact">' +
        '<div class="kind">' + escape(kind) + '</div>' +
        '<div class="filename">' + escape(a.filename || "(unnamed)") + '</div>' +
        '<div class="bytes">' + fmtBytes(a.bytes) + '</div>' +
        '<a href="' + dl + '">download</a>' +
      '</div>'
    );
  }).join("");
  const manifestHtml = session.manifest
    ? '<h2 style="margin-top:16px">manifest.json</h2><pre class="manifest">' + escape(JSON.stringify(session.manifest, null, 2)) + '</pre>'
    : "";
  root.innerHTML =
    '<dl>' +
      '<dt>Session ID</dt><dd>' + escape(session.id) + '</dd>' +
      '<dt>Received</dt><dd>' + fmtDate(session.receivedAt) + '</dd>' +
      '<dt>Total size</dt><dd>' + fmtBytes(session.totalBytes) + '</dd>' +
    '</dl>' +
    '<h2>Artifacts</h2><div class="artifacts">' + artifactsHtml + '</div>' +
    manifestHtml;
}

function renderProgressBanner() {
  const banner = document.getElementById("progress-banner");
  // Sum across active uploads — typically one MP4 at a time but multiple
  // headsets can stream simultaneously.
  const active = Array.from(progress.values()).filter(p => p.offset < p.length);
  if (!active.length) { banner.innerHTML = ""; return; }
  const sent = active.reduce((s, p) => s + p.offset, 0);
  const total = active.reduce((s, p) => s + p.length, 0);
  const pct = total > 0 ? Math.round((sent / total) * 100) : 0;
  banner.innerHTML =
    '<div>' + active.length + ' upload(s) in flight · ' + fmtBytes(sent) + ' / ' + fmtBytes(total) + ' (' + pct + '%)</div>' +
    '<div class="bar"><div style="width:' + pct + '%"></div></div>';
}

function connectSSE() {
  let es;
  let backoff = 1000;
  const open = () => {
    es = new EventSource(CFG.apiBase + "/events");
    es.onopen = () => {
      backoff = 1000;
      document.getElementById("live").dataset.connected = "true";
    };
    es.onerror = () => {
      document.getElementById("live").dataset.connected = "false";
      es.close();
      setTimeout(open, backoff);
      backoff = Math.min(backoff * 2, 30_000);
    };
    es.addEventListener("resource.created", (ev) => {
      const e = JSON.parse(ev.data);
      progress.set(e.resource.id, { offset: 0, length: e.resource.uploadLength, sessionId: e.resource.sessionId });
      renderProgressBanner();
    });
    es.addEventListener("resource.progress", (ev) => {
      const e = JSON.parse(ev.data);
      const cur = progress.get(e.resourceId) || { offset: 0, length: e.uploadLength };
      cur.offset = e.offset;
      cur.length = e.uploadLength;
      progress.set(e.resourceId, cur);
      renderProgressBanner();
    });
    es.addEventListener("resource.finalized", (ev) => {
      const e = JSON.parse(ev.data);
      progress.delete(e.resourceId);
      renderProgressBanner();
    });
    es.addEventListener("session.updated", () => {
      refreshSessions();
      refreshStats();
    });
  };
  open();
}

refreshSessions();
refreshStats();
connectSSE();
setInterval(refreshStats, 30_000);
</script>
</body>
</html>`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}
