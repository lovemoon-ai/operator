import { networkInterfaces } from "node:os";

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import QRCode from "qrcode";

import { buildConnectTicket } from "../../lib/connect-ticket";
import { getServerComponentUser } from "../../lib/auth/server-component";
import { RefreshableQr } from "./RefreshableQr";

// "Connect" tab.
//
// Endpoint selection priority:
//   1. `OPERATOR_INGEST_URL` from .env — when set, render exactly one
//      QR pointing at it (typical for prod with a fixed public origin).
//   2. Public request host — render a same-origin QR so prod can work
//      behind a reverse proxy without hard-coding an ingest URL.
//   3. Local/private request host — enumerate LAN IPv4 addresses so a
//      headset on the same network can reach a dev server.
//
// In both cases the QR ack endpoint trades the (signed, 5-min)
// ticket for the current dashboard user's permanent upload token, so
// the headset never has to see — or type — the token.

export const dynamic = "force-dynamic";

interface Endpoint {
  iface: string;
  host: string;
  url: string;
  ackUrl: string;
  expiresAt: number;
  qrSvg: string;
}

export default async function ConnectPage() {
  const user = await getServerComponentUser();
  if (!user) redirect("/login?returnTo=/connect");

  const h = await headers();
  const hostHeader = forwardedHeader(h.get("x-forwarded-host")) ?? h.get("host");
  const port = resolveIngestPort(hostHeader);
  const proto = (h.get("x-forwarded-proto") ?? "http").split(",")[0]!.trim();

  const endpoints = await collectEndpoints(proto, hostHeader, port, user.id);

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <section className="panel">
        <h2>Connect headset</h2>
        <p style={{ marginTop: 0, color: "var(--muted)" }}>
          Scan one of the short-lived QR codes below from the headset. The
          headset acks the endpoint, fills the upload URL, and enables upload
          after stop when the handshake succeeds. The QR carries an HMAC
          signature bound to <strong>your</strong> account — recordings the
          headset uploads will land on your dashboard.
        </p>
        <ol style={{ color: "var(--muted)", fontSize: 13, lineHeight: 1.8, marginTop: 8 }}>
          <li>In headset: Ego settings → camera button next to <strong>Upload URL</strong>.</li>
          <li>Point at a QR code, then click the green arrow.</li>
          <li>Tap <strong>Save</strong> — recordings upload automatically after each Stop.</li>
        </ol>
      </section>

      {endpoints.length === 0 ? (
        <section className="panel">
          <div className="empty-state">
            No non-loopback IPv4 interfaces detected. The headset can&apos;t reach this
            machine from outside. Check that you&apos;re on Wi-Fi or wired Ethernet, not
            cellular-only.
          </div>
        </section>
      ) : (
        <div style={{ display: "grid", gap: 16, gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))" }}>
          {endpoints.map((ep) => (
            <section className="panel" key={`${ep.iface}-${ep.host}`}>
              <h2>{ep.iface}</h2>
              <RefreshableQr label={`Refresh QR for ${ep.host}`} qrSvg={ep.qrSvg} expiresAt={ep.expiresAt} />
              <div
                style={{
                  marginTop: 12,
                  fontFamily: "var(--mono)",
                  fontSize: 12,
                  wordBreak: "break-all",
                  textAlign: "center",
                  color: "var(--accent)",
                }}
              >
                {ep.url}
              </div>
              <div style={{ marginTop: 6, fontSize: 11, color: "var(--muted)", textAlign: "center" }}>
                host {ep.host} · QR expires {new Date(ep.expiresAt).toLocaleTimeString()}
              </div>
              <div style={{ marginTop: 4, fontSize: 11, color: "var(--muted)", textAlign: "center" }}>
                Click the QR to issue a new 5-minute QR.
              </div>
            </section>
          ))}
        </div>
      )}

      <section className="panel">
        <h2>Your upload token</h2>
        <p style={{ fontSize: 13, marginTop: 0 }}>
          The QR ack hands this token to the headset automatically — you
          shouldn&apos;t need to copy it by hand. Kept here for visibility /
          API testing.
        </p>
        <code
          style={{
            display: "block",
            marginTop: 8,
            padding: 8,
            background: "var(--panel-deep, rgba(255,255,255,0.04))",
            fontSize: 11,
            wordBreak: "break-all",
          }}
        >
          {user.uploadToken}
        </code>
      </section>
    </div>
  );
}

// --- helpers --------------------------------------------------------------

async function collectEndpoints(
  proto: string,
  hostHeader: string | null,
  port: string,
  userId: string,
): Promise<Endpoint[]> {
  // .env override wins over auto-detection: if OPERATOR_INGEST_URL is
  // set we emit exactly one QR pointing at it and skip the NIC scan.
  const overrideUrl = (process.env.OPERATOR_INGEST_URL ?? "").trim();
  if (overrideUrl) {
    const ep = await buildEndpoint("configured", overrideUrl, userId);
    return [ep];
  }

  if (hostHeader && isPublicHost(hostHeader)) {
    return [await buildEndpoint("public", `${proto}://${hostHeader}/api/ingest`, userId)];
  }

  const out: Endpoint[] = [];
  const seen = new Set<string>();
  const nics = networkInterfaces();
  for (const [iface, addrs] of Object.entries(nics)) {
    if (!addrs) continue;
    for (const addr of addrs) {
      const isV4 = addr.family === "IPv4" || (addr.family as unknown as number) === 4;
      if (!isV4 || addr.internal) continue;
      const url = `${proto}://${addr.address}:${port}/api/ingest`;
      if (seen.has(url)) continue;
      seen.add(url);
      const ep = await buildEndpoint(iface, url, userId);
      out.push(ep);
    }
  }
  if (out.length === 0 && hostHeader) {
    out.push(await buildEndpoint("request", `${proto}://${hostHeader}/api/ingest`, userId));
  }
  out.sort((a, b) => a.iface.localeCompare(b.iface));
  return out;
}

async function buildEndpoint(iface: string, url: string, userId: string): Promise<Endpoint> {
  const ticket = buildConnectTicket(url, userId);
  const qrSvg = await QRCode.toString(ticket.ackUrl, {
    type: "svg",
    margin: 1,
    errorCorrectionLevel: "M",
    color: { dark: "#0d1014", light: "#ffffff" },
  });
  const host = hostFromUrl(url);
  return { iface, host, url, ackUrl: ticket.ackUrl, expiresAt: ticket.expiresAt, qrSvg };
}

function hostFromUrl(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

function resolveIngestPort(hostHeader: string | null): string {
  const listenPort = process.env.PORT ?? "3000";
  if (!hostHeader) return listenPort;

  const parsed = hostHeader.startsWith("[")
    ? hostHeader.match(/^\[[^\]]+\]:(\d+)$/)?.[1]
    : hostHeader.match(/:(\d+)$/)?.[1];

  if (!parsed || parsed === "80" || parsed === "443") return listenPort;
  return parsed;
}

function forwardedHeader(value: string | null): string | null {
  return value?.split(",")[0]?.trim() || null;
}

function isPublicHost(hostHeader: string): boolean {
  const hostname = hostnameFromHeader(hostHeader).toLowerCase();
  if (!hostname || hostname === "localhost") return false;
  if (hostname === "::1" || hostname.endsWith(".local")) return false;
  if (/^\d+\.\d+\.\d+\.\d+$/.test(hostname)) return !isPrivateIpv4(hostname);
  return true;
}

function hostnameFromHeader(hostHeader: string): string {
  if (hostHeader.startsWith("[")) return hostHeader.slice(1, hostHeader.indexOf("]"));
  return hostHeader.split(":")[0] ?? "";
}

function isPrivateIpv4(hostname: string): boolean {
  const parts = hostname.split(".").map((part) => Number(part));
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }
  const [a, b] = parts as [number, number, number, number];
  return (
    a === 10 ||
    a === 127 ||
    a === 0 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}
