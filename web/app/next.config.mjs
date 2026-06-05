// Next.js config for the data-management app.
//
// `transpilePackages` is what lets us import the workspace package
// directly from source — without it, Next would only consume the
// pre-built `dist/` and require a manual `npm run build:ingest`
// before every `next dev`.
//
// `webpack.resolve.extensionAlias` mirrors the TS5 `.js → .ts` resolver
// behaviour that `tsx` does at runtime, so a server-side `lib/users.ts`
// can `import { db } from "./db.js"` and still bundle correctly when
// pulled into a Next page subtree. Without this, the page bundle's
// webpack tries to resolve a literal `db.js` and 500s.
const nextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@love-moon/ego-ingest"],
  webpack(config) {
    config.resolve.extensionAlias = {
      ".js": [".ts", ".tsx", ".js"],
      ".mjs": [".mts", ".mjs"],
    };
    return config;
  },
};

export default nextConfig;
