// Express-side exports only. `server-component.ts` MUST NOT be
// re-exported here — it imports `next/headers`, which throws on
// module-load whenever it's pulled into a non-Next context (e.g.
// server.ts running under tsx). Server components import it directly
// from `@/lib/auth/server-component` instead.
export {
  authRoutes,
  browserAuthMiddleware,
  describeAuth,
} from "./express.js";
export { readSession } from "./session.js";
export type { AuthConfig } from "./config.js";
