import { networkInterfaces } from "node:os";

import { headers } from "next/headers";
import QRCode from "qrcode";

import { buildConnectTicket } from "../../lib/connect-ticket";

// "Connect" tab. Shows one QR code per LAN-reachable IPv4 address
// pointing at /api/ingest, so the operator can scan from the headset
// (or a phone) and avoid typing a long URL into a VR text field.
//
// Server-rendered: we read os.networkInterfaces() and generate inline
// SVG QR codes at request time. Nothing ships to the browser beyond
// the rendered HTML — no QR JS dep on the client.

export const dynamic = "force-dynamic";

interface Endpoint {
  /** Network interface name (en0, eth0, …) for the operator to recognize. */
  iface: string;
  /** Display address (ip:port). */
  host: string;
  /** Full upload URL the XR headset pastes into "Upload URL". */
  url: string;
  /** Signed, short-lived URL encoded into the QR. */
  ackUrl: string;
  /** Unix ms timestamp. */
  expiresAt: number;
  /** Inline SVG markup. */
  qrSvg: string;
}

export default async function ConnectPage() {
  // Use whatever port the user reached us on. If the page was served
  // via http://localhost:3000/connect, port = 3000; via a reverse
  // proxy on 443, port = 443 (and we'll honor x-forwarded-proto for
  // the scheme).
  const h = await headers();
  const hostHeader = h.get("host") ?? `localhost:${process.env.PORT ?? 3000}`;
  const port = hostHeader.includes(":") ? hostHeader.split(":").pop() ?? "3000" : "3000";
  const proto = (h.get("x-forwarded-proto") ?? "http").split(",")[0]!.trim();

  const endpoints = await collectEndpoints(proto, port);

  const tokenRequired = Boolean(process.env.INGEST_TOKEN);

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <section className="panel">
        <h2>Connect headset</h2>
        <p style={{ marginTop: 0, color: "var(--muted)" }}>
          Scan one of the short-lived QR codes below from the headset. The
          headset will ack the endpoint, fill the upload URL, and enable
          upload after stop when the handshake succeeds.
        </p>
        <ol style={{ color: "var(--muted)", fontSize: 13, lineHeight: 1.8, marginTop: 8 }}>
          <li>In headset: Ego settings → camera button next to <strong>Upload URL</strong>.</li>
          <li>Point at a QR code, then click the green arrow.</li>
          {tokenRequired && (
            <li>Bearer auth is attached by the QR ack; no token typing in-headset.</li>
          )}
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
              <div
                style={{
                  background: "white",
                  borderRadius: 8,
                  padding: 12,
                  width: "100%",
                  maxWidth: 260,
                  margin: "0 auto",
                }}
                // QR is server-rendered SVG markup; safe to inline.
                dangerouslySetInnerHTML={{ __html: ep.qrSvg }}
              />
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
                Refresh this page to issue a new 5-minute QR.
              </div>
            </section>
          ))}
        </div>
      )}

      <section className="panel">
        <h2>Auth</h2>
        {tokenRequired ? (
          <div style={{ fontSize: 13 }}>
            Bearer auth is <span className="badge flagged">REQUIRED</span>. The
            QR ack hands the headset the server token after verifying the
            5-minute ticket.
          </div>
        ) : (
          <div style={{ fontSize: 13 }}>
            Bearer auth is <span className="badge reviewed">OFF</span>. Anyone on
            the same network can upload. Set the <code>INGEST_TOKEN</code> env var
            and restart to require authentication.
          </div>
        )}
      </section>
    </div>
  );
}

// --- helpers --------------------------------------------------------------

async function collectEndpoints(proto: string, port: string): Promise<Endpoint[]> {
  const out: Endpoint[] = [];
  const nics = networkInterfaces();
  for (const [iface, addrs] of Object.entries(nics)) {
    if (!addrs) continue;
    for (const addr of addrs) {
      // Node 18+ returns family as "IPv4" string; older runtimes used
      // the numeric 4. Handle both for forward compatibility.
      const isV4 = addr.family === "IPv4" || (addr.family as unknown as number) === 4;
      if (!isV4 || addr.internal) continue;
      const host = `${addr.address}:${port}`;
      const url = `${proto}://${host}/api/ingest`;
      const ticket = buildConnectTicket(url);
      const qrSvg = await QRCode.toString(ticket.ackUrl, {
        type: "svg",
        margin: 1,
        errorCorrectionLevel: "M",
        color: { dark: "#0d1014", light: "#ffffff" },
      });
      out.push({ iface, host, url, ackUrl: ticket.ackUrl, expiresAt: ticket.expiresAt, qrSvg });
    }
  }
  // Sort so the order is stable across renders (and so Wi-Fi-ish
  // interfaces come first on most platforms).
  out.sort((a, b) => a.iface.localeCompare(b.iface));
  return out;
}
