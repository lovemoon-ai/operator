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
          disabled={isPending}
          onClick={refresh}
        >
          {isPending ? "Resetting..." : "Reset"}
        </button>
      )}
    </div>
  );
}
