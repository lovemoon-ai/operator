/**
 * Request-bound user context.
 *
 * The TUS middleware in `@love-moon/ego-ingest` is created once and
 * doesn't carry per-request app state. To plumb "who is uploading this"
 * down into the SqliteStore's INSERT of `sessions.user_id` /
 * `resources.user_id`, we bind the value to AsyncLocalStorage at the
 * outer Express middleware layer and let the store implementation read
 * it back inside its store methods.
 *
 * The "system" call form (`runAsSystem`) is used by paths that
 * legitimately need to touch ALL users' rows — most importantly the
 * orphan-watchdog rehydration that scans every session at boot, and
 * the post-ingest worker callbacks that fire outside any HTTP request.
 */
import { AsyncLocalStorage } from "node:async_hooks";

export interface AuthContext {
  userId: string;
  /** True when callers should skip per-user filtering. */
  system?: boolean;
}

const storage = new AsyncLocalStorage<AuthContext>();

export function runAsUser<T>(userId: string, fn: () => T): T {
  return storage.run({ userId }, fn);
}

export function runAsSystem<T>(fn: () => T): T {
  return storage.run({ userId: "__system__", system: true }, fn);
}

/** Current user id, or `undefined` if no context was set. */
export function currentUserId(): string | undefined {
  const ctx = storage.getStore();
  if (!ctx) return undefined;
  if (ctx.system) return undefined;
  return ctx.userId;
}

/** True when the current call is running in system (no-filter) mode. */
export function isSystem(): boolean {
  return storage.getStore()?.system === true;
}
