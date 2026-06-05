import { networkInterfaces } from "node:os";

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import QRCode from "qrcode";

import { buildConnectTicket } from "../../lib/connect-ticket";
import { getServerComponentUser } from "../../lib/auth/server-component";
import { RefreshableQr } from "./RefreshableQr";

// "Connect" tab. One QR per LAN-reachable IPv4 address pointing at
// /api/ingest. The QR ack endpoint trades the (signed, 5-min) ticket
// for the current dashboard user's permanent upload token, so the
// headset never has to see — or type — the token.

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
  const hostHeader = h.get("host") ?? `localhost:${process.env.PORT ?? 3000}`;
  const port = hostHeader.includes(":") ? hostHeader.split(":").pop() ?? "3000" : "3000";
  const proto = (h.get("x-forwarded-proto") ?? "http").split(",")[0]!.trim();

  const endpoints = await collectEndpoints(proto, port, user.id);

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

async function collectEndpoints(proto: string, port: string, userId: string): Promise<Endpoint[]> {
  const out: Endpoint[] = [];
  const nics = networkInterfaces();
  for (const [iface, addrs] of Object.entries(nics)) {
    if (!addrs) continue;
    for (const addr of addrs) {
      const isV4 = addr.family === "IPv4" || (addr.family as unknown as number) === 4;
      if (!isV4 || addr.internal) continue;
      const host = `${addr.address}:${port}`;
      const url = `${proto}://${host}/api/ingest`;
      const ticket = buildConnectTicket(url, userId);
      const qrSvg = await QRCode.toString(ticket.ackUrl, {
        type: "svg",
        margin: 1,
        errorCorrectionLevel: "M",
        color: { dark: "#0d1014", light: "#ffffff" },
      });
      out.push({ iface, host, url, ackUrl: ticket.ackUrl, expiresAt: ticket.expiresAt, qrSvg });
    }
  }
  out.sort((a, b) => a.iface.localeCompare(b.iface));
  return out;
}
