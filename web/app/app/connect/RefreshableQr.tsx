"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState, useTransition } from "react";

interface RefreshableQrProps {
  label: string;
  qrSvg: string;
  expiresAt: number;
}

export function RefreshableQr({ label, qrSvg, expiresAt }: RefreshableQrProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [isExpired, setIsExpired] = useState(false);

  const refresh = () => startTransition(() => router.refresh());

  useEffect(() => {
    const updateExpired = () => setIsExpired(Date.now() >= expiresAt);
    updateExpired();
    const interval = window.setInterval(updateExpired, 1000);
    return () => window.clearInterval(interval);
  }, [expiresAt]);

  return (
    <div className="qr-refresh-wrap" data-expired={isExpired ? "true" : "false"}>
      <button
        type="button"
        aria-label={label}
        title="Click to refresh this QR"
        className="qr-refresh-button"
        data-refreshing={isPending ? "true" : "false"}
        onClick={refresh}
      >
        <span dangerouslySetInnerHTML={{ __html: qrSvg }} />
      </button>
      {isExpired && (
        <button
          type="button"
          className="qr-reset-overlay"
          data-refreshing={isPending ? "true" : "false"}
          disabled={isPending}
          onClick={refresh}
          aria-label={isPending ? "Resetting QR" : "Reset QR"}
          title={isPending ? "Resetting QR" : "Reset QR"}
        >
          {/* Lucide `rotate-ccw` — inlined to avoid pulling lucide-react
              for one 24×24 SVG. Spins via CSS when isPending. */}
          <svg
            xmlns="http://www.w3.org/2000/svg"
            width="22"
            height="22"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
            <path d="M3 3v5h5" />
          </svg>
        </button>
      )}
    </div>
  );
}
