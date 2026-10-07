// The shared match library: a manifest of files (path -> sha256) in D1, their contents in R2 as
// content-addressed blobs. Paths are laid out exactly like the desktop app's user://matches
// (folders, X.positions.csv with its X.positions.json sidecar, audio and X.positions.logs/*.txt),
// so the web build keeps using MatchLibrary unchanged on a local mirror (web_library.gd).
//
// Changes arrive as commits of put/delete ops. Each op names the sha it expects the path to have
// now (`prev`), so a commit racing another one is refused as a conflict instead of clobbering it.
// Anyone may add files, create or remove folders and edit a match's sidecar (team swaps and
// names); replacing or deleting a match's files needs the match's uploader or an admin.

import { Env, User, audit, json, now } from "./util";

export interface FileRow {
  path: string;
  sha: string;
  size: number;
  owner_id: number;
  owner_name: string;
  mtime: number;
}

export type Op =
  | { op: "put"; path: string; sha: string; size: number; prev: string | null }
  | { op: "delete"; path: string; prev: string | null };

const SHA_RE = /^[0-9a-f]{64}$/;
const MAX_PATH = 512;
const MAX_OPS = 2000;

/** Whether `path` is a library path: relative, "/"-separated, no empty / "." / ".." segments or
 * control characters; folders end in "/". */
export function validPath(path: string): boolean {
  if (typeof path !== "string" || path.length === 0 || path.length > MAX_PATH) return false;
  if (/[\x00-\x1f\x7f\\:]/.test(path) || path.startsWith("/")) return false;
  const segs = (path.endsWith("/") ? path.slice(0, -1) : path).split("/");
  return segs.every((s) => s.length > 0 && s !== "." && s !== ".." && s.trim() === s);
}

export function isFolder(path: string): boolean {
  return path.endsWith("/");
}

/** The match a file belongs to, as its path without extension: "a/m.positions.csv",
 * "a/m.positions.json", "a/m.positions.ogg" and "a/m.positions.logs/x.txt" all give
 * "a/m.positions". Mirrors `WebLibrary.match_key`. */
export function matchKey(path: string): string {
  const segs = path.split("/");
  for (let i = 0; i < segs.length - 1; i++) {
    if (segs[i].toLowerCase().endsWith(".logs")) {
      return [...segs.slice(0, i), segs[i].slice(0, -".logs".length)].join("/");
    }
  }
  const file = segs[segs.length - 1];
  const dot = file.lastIndexOf(".");
  return dot > 0 ? path.slice(0, path.length - (file.length - dot)) : path;
}

export async function manifest(env: Env): Promise<{ version: number; files: FileRow[] }> {
  const [rows, ver] = await env.DB.batch([
    env.DB.prepare("SELECT path, sha, size, owner_id, owner_name, mtime FROM files ORDER BY path"),
    env.DB.prepare("SELECT value FROM kv WHERE key = 'library_version'"),
  ]);
  const version = parseInt(((ver.results[0] as { value?: string }) ?? {}).value ?? "0", 10);
  return { version, files: rows.results as unknown as FileRow[] };
}

// --- blobs ------------------------------------------------------------------------------

export function blobKey(sha: string): string {
  return `blobs/${sha}`;
}

/** Which of `shas` aren't stored yet. */
export async function missingBlobs(env: Env, shas: unknown): Promise<Response> {
  if (!Array.isArray(shas) || shas.length > MAX_OPS || !shas.every((s) => typeof s === "string" && SHA_RE.test(s))) {
    return json({ error: "shas must be a list of sha256 hex strings" }, 400);
  }
  const missing: string[] = [];
  for (const sha of new Set(shas as string[])) {
    if ((await env.BUCKET.head(blobKey(sha))) === null) missing.push(sha);
  }
  return json({ missing });
}

/** Stores the request body as blob `sha`; R2 rejects it if the body doesn't hash to `sha`. */
export async function putBlob(req: Request, env: Env, sha: string): Promise<Response> {
  if (!SHA_RE.test(sha)) return json({ error: "bad sha" }, 400);
  const length = parseInt(req.headers.get("Content-Length") ?? "", 10);
  const max = parseInt(env.MAX_UPLOAD_BYTES ?? "100000000", 10);
  if (!Number.isFinite(length)) return json({ error: "Content-Length required" }, 411);
  if (length > max) return json({ error: `file too large (max ${Math.floor(max / 1e6)} MB)` }, 413);
  if ((await env.BUCKET.head(blobKey(sha))) !== null) {
    await req.body?.cancel();
    return json({ ok: true, existed: true });
  }
  try {
    await env.BUCKET.put(blobKey(sha), req.body, { sha256: sha });
  } catch (e) {
    return json({ error: `upload rejected: ${(e as Error).message}` }, 400);
  }
  return json({ ok: true });
}

export async function getBlob(env: Env, sha: string): Promise<Response> {
  if (!SHA_RE.test(sha)) return json({ error: "bad sha" }, 400);
  const obj = await env.BUCKET.get(blobKey(sha));
  if (obj === null) return json({ error: "not found" }, 404);
  return new Response(obj.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(obj.size),
      // Content-addressed: never changes.
      "Cache-Control": "private, max-age=31536000, immutable",
      ETag: obj.httpEtag,
    },
  });
}

// --- commits ----------------------------------------------------------------------------

export type CommitResult =
  | { status: "ok"; version: number }
  | { status: "invalid"; error: string }
  | { status: "conflict"; paths: string[] }
  | { status: "rejected"; paths: string[]; reasons: Record<string, string> }
  | { status: "missing"; shas: string[] };

/** Applies `ops` atomically for `user`, or explains why none were applied. */
export async function commit(env: Env, user: User, rawOps: unknown): Promise<CommitResult> {
  if (!Array.isArray(rawOps) || rawOps.length === 0 || rawOps.length > MAX_OPS) {
    return { status: "invalid", error: `ops must be a list of 1-${MAX_OPS} operations` };
  }
  const ops: Op[] = [];
  const seen = new Set<string>();
  for (const o of rawOps as Record<string, unknown>[]) {
    const path = o?.path as string;
    const prev = o?.prev === null || o?.prev === undefined ? null : String(o.prev);
    if (!validPath(path)) return { status: "invalid", error: `bad path ${JSON.stringify(path)}` };
    if (seen.has(path)) return { status: "invalid", error: `${path} appears twice` };
    seen.add(path);
    if (o.op === "put") {
      const sha = String(o.sha ?? "");
      const size = Number(o.size);
      if (isFolder(path) ? sha !== "" || size !== 0 : !SHA_RE.test(sha) || !Number.isInteger(size) || size < 0) {
        return { status: "invalid", error: `bad put of ${path}` };
      }
      ops.push({ op: "put", path, sha, size, prev });
    } else if (o.op === "delete") {
      ops.push({ op: "delete", path, prev });
    } else {
      return { status: "invalid", error: `unknown op ${JSON.stringify(o?.op)}` };
    }
  }

  const { files } = await manifest(env);
  const byPath = new Map(files.map((f) => [f.path, f]));

  // Optimistic concurrency: every op must have been made against the current state.
  const conflicts = ops.filter((o) => (byPath.get(o.path)?.sha ?? null) !== o.prev).map((o) => o.path);
  if (conflicts.length) return { status: "conflict", paths: conflicts };

  const ownerOf = (path: string): number | undefined =>
    byPath.get(matchKey(path) + ".csv")?.owner_id ?? byPath.get(path)?.owner_id;
  const reasons: Record<string, string> = {};
  for (const o of ops) {
    const cur = byPath.get(o.path);
    if (!cur || isFolder(o.path) || user.admin) continue;
    if (o.op === "put" && (o.sha === cur.sha || o.path.toLowerCase().endsWith(".json"))) continue;
    if (ownerOf(o.path) !== user.id) {
      const owner = byPath.get(matchKey(o.path) + ".csv")?.owner_name ?? cur.owner_name;
      reasons[o.path] = `only ${owner} (who uploaded it) or an admin can ${o.op === "put" ? "replace" : "remove"} it`;
    }
  }
  const rejected = Object.keys(reasons);
  if (rejected.length) return { status: "rejected", paths: rejected, reasons };

  const puts = ops.filter((o): o is Extract<Op, { op: "put" }> => o.op === "put" && !isFolder(o.path));
  const missing: string[] = [];
  for (const sha of new Set(puts.filter((p) => byPath.get(p.path)?.sha !== p.sha).map((p) => p.sha))) {
    if ((await env.BUCKET.head(blobKey(sha))) === null) missing.push(sha);
  }
  if (missing.length) return { status: "missing", shas: missing };

  // A put whose content is deleted elsewhere in the same commit is a move (rename, or into
  // another folder): it keeps its uploader.
  const movedFrom = new Map<string, FileRow>();
  for (const o of ops) {
    const cur = byPath.get(o.path);
    if (o.op === "delete" && cur && !isFolder(o.path)) movedFrom.set(cur.sha, cur);
  }
  const t = now();
  const stmts: D1PreparedStatement[] = [];
  for (const o of ops) {
    if (o.op === "delete") {
      stmts.push(env.DB.prepare("DELETE FROM files WHERE path = ?").bind(o.path));
      continue;
    }
    const cur = byPath.get(o.path);
    const src = cur ?? movedFrom.get(o.sha);
    const ownerId = src?.owner_id ?? user.id;
    const ownerName = src?.owner_name ?? user.name;
    stmts.push(
      env.DB.prepare(
        "INSERT INTO files (path, sha, size, owner_id, owner_name, mtime) VALUES (?, ?, ?, ?, ?, ?) " +
          "ON CONFLICT (path) DO UPDATE SET sha = excluded.sha, size = excluded.size, mtime = excluded.mtime",
      ).bind(o.path, o.sha, o.size, ownerId, ownerName, t),
    );
  }
  stmts.push(
    env.DB.prepare(
      "INSERT INTO kv (key, value) VALUES ('library_version', '1') " +
        "ON CONFLICT (key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)",
    ),
  );
  stmts.push(
    env.DB.prepare("INSERT INTO audit (at, char_id, char_name, action, detail) VALUES (?, ?, ?, ?, ?)").bind(
      t,
      user.id,
      user.name,
      "library",
      JSON.stringify(ops.map((o) => `${o.op} ${o.path}`)),
    ),
  );
  // D1 batches run as one transaction.
  await env.DB.batch(stmts);
  const ver = await env.DB.prepare("SELECT value FROM kv WHERE key = 'library_version'").first<{ value: string }>();
  return { status: "ok", version: parseInt(ver?.value ?? "0", 10) };
}

export function commitResponse(r: CommitResult): Response {
  switch (r.status) {
    case "ok":
      return json(r);
    case "invalid":
      return json(r, 400);
    case "rejected":
      return json(r, 403);
    default:
      return json(r, 409);
  }
}

// --- settings ---------------------------------------------------------------------------

const MAX_SETTINGS = 512 * 1024;

export async function getSettings(env: Env, user: User): Promise<string | null> {
  const row = await env.DB.prepare("SELECT body FROM settings WHERE char_id = ?").bind(user.id).first<{ body: string }>();
  return row?.body ?? null;
}

export async function putSettings(req: Request, env: Env, user: User): Promise<Response> {
  const body = await req.text();
  if (body.length > MAX_SETTINGS) return json({ error: "settings too large" }, 413);
  await env.DB.prepare(
    "INSERT INTO settings (char_id, body, updated_at) VALUES (?, ?, ?) " +
      "ON CONFLICT (char_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at",
  )
    .bind(user.id, body, now())
    .run();
  return json({ ok: true });
}

export { audit };
