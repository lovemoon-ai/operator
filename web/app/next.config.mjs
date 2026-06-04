// Next.js config for the data-management app.
//
// `transpilePackages` is what lets us import the workspace package
// directly from source — without it, Next would only consume the
// pre-built `dist/` and require a manual `npm run build:ingest`
// before every `next dev`.
const nextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@love-moon/ego-ingest"],
};

export default nextConfig;
