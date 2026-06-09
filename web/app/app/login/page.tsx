import { AnimatedGraphBackground } from "./AnimatedGraphBackground";

// Static, unauthenticated landing. Visual language deliberately
// stripped down — a single sign-in action sitting on a calm animated
// graph background, in the spirit of arxiv-radar's login. The
// "Continue" link points at the Express `/auth/start` route which
// stamps the dev-bypass session.
export const dynamic = "force-dynamic";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string }>;
}) {
  const params = await searchParams;
  const returnTo = params.returnTo ?? "/";

  return (
    <div className="login-shell">
      <AnimatedGraphBackground />
      <div className="login-content">
        <h1 className="login-title">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/icon.png" alt="operator" width={96} height={96} />
        </h1>
        <a
          className="login-cta"
          href={`/auth/start?returnTo=${encodeURIComponent(returnTo)}`}
          aria-label="登录"
          title="登录"
        >
          {/* Lucide `log-in` — inlined so we don't pull in lucide-react
              for a single 24×24 SVG. */}
          <svg
            xmlns="http://www.w3.org/2000/svg"
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="m10 17 5-5-5-5" />
            <path d="M15 12H3" />
            <path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4" />
          </svg>
          <span>登录</span>
        </a>
      </div>
    </div>
  );
}
