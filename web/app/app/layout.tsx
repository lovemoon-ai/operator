import type { Metadata } from "next";
import type { ReactNode } from "react";

import "./globals.css";
import { LiveIndicator } from "./components/LiveIndicator";

export const metadata: Metadata = {
  title: "Ego Data Manager",
  description: "Browse, review, and manage XR ego recordings uploaded via @love-moon/ego-ingest.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
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
        </header>
        <main className="container">{children}</main>
      </body>
    </html>
  );
}
