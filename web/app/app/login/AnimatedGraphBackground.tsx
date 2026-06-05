"use client";

import { useEffect, useRef } from "react";

/**
 * Animated graph-network background for the login page.
 *
 * Renders ~40 drifting nodes on a full-viewport canvas; any pair within
 * `LINK_DISTANCE` px gets a faint line whose opacity falls off with
 * distance. Cheap (canvas2d, no WebGL), runs at the display refresh
 * rate via rAF, pauses cleanly on tab-hidden via Page Visibility.
 *
 * Why a client component: canvas + animation loop need browser APIs.
 * Why a separate file (not inline in page.tsx): keeps the login page
 * a pure server component, dynamic `import()` lazy-loads this for the
 * "code split everything client" budget Next 15 emits.
 */
export function AnimatedGraphBackground() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = Math.max(1, Math.min(window.devicePixelRatio || 1, 2));
    const NODE_COUNT = 42;
    const LINK_DISTANCE = 140;
    // Soft accent that reads on the dark bg without competing with the
    // CTA. Tweaked to match the operator palette's --accent (#58a6ff)
    // but at low alpha so it never crowds the centered title.
    const STROKE_RGB = "88, 166, 255";
    const NODE_RGB = "200, 220, 255";

    interface Node { x: number; y: number; vx: number; vy: number; r: number }
    let nodes: Node[] = [];
    let width = 0;
    let height = 0;
    let rafId = 0;
    let lastTime = performance.now();
    let running = true;

    function resize() {
      width = canvas!.clientWidth;
      height = canvas!.clientHeight;
      canvas!.width = Math.floor(width * dpr);
      canvas!.height = Math.floor(height * dpr);
      ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    function init() {
      resize();
      nodes = Array.from({ length: NODE_COUNT }, () => ({
        x: Math.random() * width,
        y: Math.random() * height,
        // 8-22 px/s drift in either axis — slow enough to read as
        // "calm", fast enough that the network never looks frozen.
        vx: (Math.random() - 0.5) * 0.04,
        vy: (Math.random() - 0.5) * 0.04,
        r: 1.2 + Math.random() * 1.2,
      }));
    }

    function tick(now: number) {
      if (!running) return;
      const dt = Math.min(64, now - lastTime); // clamp big tab-switch dt
      lastTime = now;

      ctx!.clearRect(0, 0, width, height);

      // Move + bounce.
      for (const n of nodes) {
        n.x += n.vx * dt;
        n.y += n.vy * dt;
        if (n.x < 0) { n.x = 0; n.vx *= -1; }
        if (n.x > width) { n.x = width; n.vx *= -1; }
        if (n.y < 0) { n.y = 0; n.vy *= -1; }
        if (n.y > height) { n.y = height; n.vy *= -1; }
      }

      // Lines first so node dots paint on top.
      for (let i = 0; i < nodes.length; i++) {
        const a = nodes[i]!;
        for (let j = i + 1; j < nodes.length; j++) {
          const b = nodes[j]!;
          const dx = a.x - b.x;
          const dy = a.y - b.y;
          const d2 = dx * dx + dy * dy;
          const max = LINK_DISTANCE * LINK_DISTANCE;
          if (d2 > max) continue;
          const t = 1 - d2 / max;
          ctx!.strokeStyle = `rgba(${STROKE_RGB}, ${(t * 0.35).toFixed(3)})`;
          ctx!.lineWidth = 1;
          ctx!.beginPath();
          ctx!.moveTo(a.x, a.y);
          ctx!.lineTo(b.x, b.y);
          ctx!.stroke();
        }
      }

      // Node dots.
      ctx!.fillStyle = `rgba(${NODE_RGB}, 0.85)`;
      for (const n of nodes) {
        ctx!.beginPath();
        ctx!.arc(n.x, n.y, n.r, 0, Math.PI * 2);
        ctx!.fill();
      }

      rafId = requestAnimationFrame(tick);
    }

    init();
    rafId = requestAnimationFrame(tick);

    const onResize = () => init();
    window.addEventListener("resize", onResize);

    const onVisibility = () => {
      if (document.hidden) {
        running = false;
        cancelAnimationFrame(rafId);
      } else if (!running) {
        running = true;
        lastTime = performance.now();
        rafId = requestAnimationFrame(tick);
      }
    };
    document.addEventListener("visibilitychange", onVisibility);

    return () => {
      running = false;
      cancelAnimationFrame(rafId);
      window.removeEventListener("resize", onResize);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      aria-hidden="true"
      className="login-bg"
    />
  );
}
