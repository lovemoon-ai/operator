import { AnimatedGraphBackground } from "./AnimatedGraphBackground";

// Local collector login. The first successful use of an ID creates it;
// subsequent logins must present the same PIN.
export const dynamic = "force-dynamic";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string; error?: string; collectorId?: string }>;
}) {
  const params = await searchParams;
  const returnTo = params.returnTo?.startsWith("/") ? params.returnTo : "/collectors";
  const errors: Record<string, string> = {
    invalid_id: "数采 ID 需为 3–32 位，只能使用字母、数字、下划线或短横线。",
    invalid_pin: "PIN 必须是 6 位数字。",
    invalid_credentials: "数采 ID 或 PIN 不正确。",
    locked: "尝试次数过多，请 15 分钟后再试。",
  };

  return (
    <div className="login-shell">
      <AnimatedGraphBackground />
      <div className="login-content">
        <div className="login-card">
          <h1 className="login-title">
          {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/icon.png" alt="operator" width={72} height={72} />
          </h1>
          <div className="login-heading">
            <h2>数据采集工作台</h2>
            <p>登录后只会看到属于你的工作站和数据。</p>
          </div>
          {params.error && <div className="login-error" role="alert">{errors[params.error] ?? "登录失败，请重试。"}</div>}
          <form className="login-form" method="post" action="/auth/local">
            <input type="hidden" name="returnTo" value={returnTo} />
            <label>
              <span>数采 ID</span>
              <input
                name="collectorId"
                defaultValue={params.collectorId ?? ""}
                required
                minLength={3}
                maxLength={32}
                pattern="[A-Za-z0-9_-]{3,32}"
                autoComplete="username"
                autoCapitalize="none"
                spellCheck={false}
                placeholder="例如 collector_01"
                autoFocus
              />
            </label>
            <label>
              <span>6 位 PIN</span>
              <input
                name="pin"
                type="password"
                required
                minLength={6}
                maxLength={6}
                pattern="[0-9]{6}"
                inputMode="numeric"
                autoComplete="current-password"
                placeholder="••••••"
              />
            </label>
            <button className="login-cta login-submit" type="submit">登录</button>
          </form>
          <p className="login-help">首次使用某个数采 ID 时会自动创建账号，请牢记 PIN，不要与他人共用 ID。</p>
        </div>
      </div>
    </div>
  );
}
