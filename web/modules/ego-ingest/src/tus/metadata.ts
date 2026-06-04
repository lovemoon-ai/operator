import type { UploadMetadata } from "../types.js";

/**
 * Parse a TUS `Upload-Metadata` header value.
 *
 * Spec: comma-separated list of `<key> <base64 value>` pairs. Keys
 * without a value are permitted (encoded as just `<key>`). We never
 * throw on malformed input — corrupt metadata becomes an empty `extra`
 * map rather than a 500.
 */
export function parseUploadMetadata(raw: string | undefined | null): UploadMetadata {
  const out: UploadMetadata = {
    session_id: "",
    artifact_kind: "",
    filename: "",
    extra: {},
  };
  if (!raw) return out;

  for (const entry of raw.split(",")) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const spaceIdx = trimmed.indexOf(" ");
    const key = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
    if (!key) continue;
    let value = "";
    if (spaceIdx !== -1) {
      const b64 = trimmed.slice(spaceIdx + 1).trim();
      try {
        value = Buffer.from(b64, "base64").toString("utf8");
      } catch {
        value = b64;
      }
    }
    switch (key) {
      case "session_id":
        out.session_id = value;
        break;
      case "artifact_kind":
        out.artifact_kind = value;
        break;
      case "filename":
        out.filename = value;
        break;
      case "schema":
        out.schema = value;
        break;
      default:
        out.extra[key] = value;
    }
  }
  return out;
}

/** Helper used by tests and the dashboard's "replay" view. */
export function buildUploadMetadata(md: Partial<UploadMetadata>): string {
  const pairs: string[] = [];
  const push = (k: string, v: string | undefined) => {
    if (v === undefined) return;
    pairs.push(`${k} ${Buffer.from(v, "utf8").toString("base64")}`);
  };
  push("session_id", md.session_id);
  push("artifact_kind", md.artifact_kind);
  push("filename", md.filename);
  push("schema", md.schema);
  for (const [k, v] of Object.entries(md.extra ?? {})) push(k, v);
  return pairs.join(",");
}
