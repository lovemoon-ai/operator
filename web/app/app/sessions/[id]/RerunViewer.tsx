"use client";

import { useEffect, useRef, useState } from "react";

// Type-only import: pulls signatures + the WebViewer class type at
// compile time but NEVER emits a `require` of the package into the
// bundle. We still do a runtime dynamic `import()` inside useEffect
// so the WASM blob loads lazily on the client.
import type { WebViewer as WebViewerType } from "@rerun-io/web-viewer";

interface Props {
  /** URL the Rerun web viewer should load the .rrd from. */
  rrdUrl: string;
  /** Optional pixel height; defaults to a comfortable 720. */
  height?: number;
}

/**
 * Thin wrapper around `@rerun-io/web-viewer`.
 *
 * The viewer ships a ~10 MB WASM blob and a WebGL canvas, so we
 * dynamic-import it inside `useEffect` to keep it out of the Next.js
 * server bundle entirely. We let the viewer paint its OWN loading
 * splash (which displays the source URL it's fetching) instead of
 * stacking our own text on top — the user previously saw the two
 * overlap, and Rerun's splash is the authoritative progress display.
 *
 * Lifecycle hooks worth knowing:
 *   - `viewer.start(url, parent, options)` resolves after the canvas
 *     has been mounted, but BEFORE the .rrd has finished downloading
 *     and the 3D view has painted its first frame. So we listen to
 *     the `ready` event for the actual "you can now see the data"
 *     signal — that's what hides our spinner.
 *   - On unmount we call `viewer.stop()` to free the WASM heap so
 *     route transitions don't leak a hundred MB per session view.
 *
 * If the dependency isn't installed (`npm install @rerun-io/web-viewer`
 * pending), we render an actionable hint instead of crashing the page.
 */
export function RerunViewer({ rrdUrl, height = 720 }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let viewer: WebViewerType | null = null;
    let unsubscribeReady: (() => void) | null = null;

    (async () => {
      try {
        const mod = await import(
          /* webpackChunkName: "rerun-web-viewer" */
          "@rerun-io/web-viewer"
        );
        if (cancelled) return;
        viewer = new mod.WebViewer();
        if (!containerRef.current) return;
        unsubscribeReady = viewer.on("ready", () => {
          if (!cancelled) setReady(true);
        });
        // Rerun 0.33+'s URL parser (Rust `url` crate compiled to WASM)
        // rejects path-only URLs like "/api/...". Absolutize against
        // the current origin — works for same-origin loads which is
        // the only case we serve.
        const absoluteUrl = rrdUrl.startsWith("http")
          ? rrdUrl
          : new URL(rrdUrl, window.location.origin).toString();
        // Pass CSS percentages for the canvas instead of a pixel
        // snapshot of `clientWidth` — the latter locks the canvas to
        // whatever width the container had at viewer.start() time,
        // which leaves black margin on the right whenever the panel
        // grows later (window resize, late flexbox layout, …).
        // Percentages keep the canvas glued to the parent.
        await viewer.start(absoluteUrl, containerRef.current, {
          hide_welcome_screen: true,
          width: "100%",
          height: "100%",
        });
      } catch (err) {
        if (cancelled) return;
        const msg = (err as Error)?.message ?? String(err);
        // The most common failure during development is "module not
        // found" because the dependency hasn't been npm-installed yet.
        // Surface it as a polite hint rather than a stack trace.
        if (/Cannot find module|Failed to resolve|Failed to fetch dynamically imported module/i.test(msg)) {
          setError(
            "Rerun web viewer not installed. Run `npm install @rerun-io/web-viewer` in web/app.",
          );
        } else {
          setError(msg);
        }
      }
    })();

    return () => {
      cancelled = true;
      try {
        unsubscribeReady?.();
      } catch {
        /* ignore */
      }
      try {
        viewer?.stop();
      } catch {
        /* ignore */
      }
    };
  }, [rrdUrl, height]);

  if (error) {
    return (
      <div className="rerun-frame rerun-frame--error" style={{ minHeight: height }}>
        <p>{error}</p>
      </div>
    );
  }

  return (
    <div className="rerun-frame" style={{ height }}>
      <div ref={containerRef} style={{ width: "100%", height: "100%" }} />
      {/* No text overlay — Rerun paints its own splash + progress while
          the WASM + .rrd download. A single thin progress bar at the
          top tells the user something is happening without colliding
          with the viewer's own URL banner once it loads. */}
      {!ready && <div className="rerun-frame__progress" aria-label="Loading viewer" />}
    </div>
  );
}
