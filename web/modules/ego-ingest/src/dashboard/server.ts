import type { RequestHandler } from "express";
import express from "express";

import { dashboardHtml } from "./html.js";

export interface DashboardOptions {
  /**
   * The base path the read-only API was mounted at. Defaults to
   * `/ingest/api`. The dashboard fetches sessions and subscribes to
   * SSE from this prefix.
   */
  apiBase?: string;
  /** Custom title shown in the browser tab and header. */
  title?: string;
}

/**
 * Mount as `app.use('/dashboard', createDashboard({ apiBase: '/ingest/api' }))`.
 *
 * Ships a single-page vanilla-JS dashboard — no build step, no React,
 * no framework lock-in. It's intentionally plain so users can read the
 * source, fork it, or replace it with their own React/Vue components
 * (see `ui/react/` for embeddable components).
 */
export function createDashboard(opts: DashboardOptions = {}): RequestHandler {
  const router = express.Router();
  const apiBase = (opts.apiBase ?? "/ingest/api").replace(/\/+$/, "");
  const title = opts.title ?? "Ego Ingest";

  router.get("/", (_req, res) => {
    res.type("html").send(dashboardHtml({ apiBase, title }));
  });

  return router;
}
