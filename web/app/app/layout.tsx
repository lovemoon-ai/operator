import type { Metadata } from "next";
import type { ReactNode } from "react";

import "./globals.css";
import { LiveIndicator } from "./components/LiveIndicator";
import { getServerComponentUser } from "@/lib/auth/server-component";

export const metadata: Metadata = {
  title: "Ego Data Manager",
  description: "Browse, review, and manage XR ego recordings uploaded via @love-moon/ego-ingest.",
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  // Read straight from the iron-session cookie — Express's
  // AsyncLocalStorage doesn't reliably propagate into Next's RSC
  // render, but the cookie does. Pages NOT gated by the auth
  // middleware (just `/login`) still get `null` here and the account
  // chip stays hidden.
  const user = await getServerComponentUser();

  return (
    <html lang="en">
      <body>
        <header className="app-header">
          <h1>Ego Data Manager</h1>
          <nav>
            <a href="/">Sessions</a>
            <a href="/stats">Stats</a>
            <a href="/connect">Connect</a>
          </nav>
          <LiveIndicator apiBase="/api/ingest-read" />
          {user && (
            <div
              style={{
                marginLeft: "auto",
                display: "flex",
                alignItems: "center",
                gap: 12,
                fontSize: 12,
                color: "var(--muted)",
              }}
            >
              <span>{user.name || user.email || user.id}</span>
              <a href="/auth/logout">Sign out</a>
            </div>
          )}
        </header>
        <main className="container">{children}</main>
      </body>
    </html>
  );
}
