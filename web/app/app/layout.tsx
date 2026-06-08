import type { Metadata } from "next";
import type { ReactNode } from "react";

import "./globals.css";
import { LiveIndicator } from "./components/LiveIndicator";
import { getServerComponentUser } from "@/lib/auth/server-component";

export const metadata: Metadata = {
  title: "operator",
  description: "Teleoperate-anything data manager.",
  icons: { icon: "/icon.png", shortcut: "/icon.png", apple: "/icon.png" },
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  // Read straight from the iron-session cookie — Express's
  // AsyncLocalStorage doesn't reliably propagate into Next's RSC
  // render, but the cookie does. When there's no user the page is
  // either /login or the auth middleware redirected here mid-flight;
  // either way we drop the header + container so the login page can
  // own the full viewport.
  const user = await getServerComponentUser();

  return (
    <html lang="en">
      <body data-chrome={user ? "app" : "bare"}>
        {user ? (
          <>
            <header className="app-header">
              <a href="/" className="app-header__brand" aria-label="operator home">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src="/icon.png" alt="" width={28} height={28} />
              </a>
              <nav>
                <a href="/">Sessions</a>
                <a href="/connect">Connect</a>
              </nav>
              <LiveIndicator apiBase="/api/ingest-read" />
              <div className="app-header__account">
                <span>{user.name || user.email || user.id}</span>
                <a href="/auth/logout">Sign out</a>
              </div>
            </header>
            <main className="container">{children}</main>
          </>
        ) : (
          children
        )}
      </body>
    </html>
  );
}
