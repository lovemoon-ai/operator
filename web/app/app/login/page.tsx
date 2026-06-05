// Static, unauthenticated landing page. The "Continue" link points at
// the Express-side `/auth/start` route which decides whether to stamp
// a dev cookie (bypass mode) or redirect to the OIDC authorization
// endpoint.

export const dynamic = "force-dynamic";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string }>;
}) {
  const params = await searchParams;
  const returnTo = params.returnTo ?? "/";
  return (
    <div style={{ display: "grid", gap: 16 }}>
      <section className="panel">
        <h2>Sign in</h2>
        <p style={{ color: "var(--muted)", fontSize: 13 }}>
          The Operator dashboard is per-user. Sign in to see your own uploads,
          generate a personal headset upload token, and try the data
          pipeline. In <code>AUTH_BYPASS=1</code> mode the same link logs you
          in as a fixed dev user without prompting.
        </p>
        <p style={{ marginTop: 16 }}>
          <a
            className="badge reviewed"
            href={`/auth/start?returnTo=${encodeURIComponent(returnTo)}`}
            style={{
              display: "inline-block",
              padding: "8px 18px",
              fontSize: 14,
            }}
          >
            Continue →
          </a>
        </p>
      </section>
    </div>
  );
}
