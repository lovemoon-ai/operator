import type { Metadata } from "next";
import type { ReactNode } from "react";

import "./globals.css";
import { getServerComponentUser } from "@/lib/auth/server-component";

export const metadata: Metadata = {
  title: "Operator 数据采集工作台",
  description: "Quest 数据读取、检查、标签与上传工作台。",
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
    <html lang="zh-CN">
      <body data-chrome={user ? "app" : "bare"}>
        {user ? (
          <>
            <header className="app-header">
              <a href="/collectors" className="app-header__brand" aria-label="数据采集工作台">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src="/icon.png" alt="" width={28} height={28} />
              </a>
              <nav>
                <a href="/collectors">数据采集</a>
              </nav>
              <div className="app-header__account">
                <span>{user.name || user.email || user.id}</span>
                <a href="/auth/logout">退出</a>
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
