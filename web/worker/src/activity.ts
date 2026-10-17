// Basic usage tracking: who loads the site and which library matches they open, kept as daily
// counters (one `activity` row per day, character and match) so the data stays small. The web
// build reports a match open itself (WebLibrary.report_watched): blobs are cached forever and
// mirrored locally, so re-opening a match never reaches the server otherwise.

import { Env, User, json } from "./util";

const KEEP_DAYS = 90;
const SUMMARY_DAYS = 30;

/** Counts one site visit (`match` "") or one open of library match `match` for `user` today. */
export async function record(env: Env, user: User, match = ""): Promise<void> {
  await env.DB.prepare(
    "INSERT INTO activity (day, char_id, char_name, match, n) VALUES (date('now'), ?, ?, ?, 1) " +
      "ON CONFLICT (day, char_id, match) DO UPDATE SET n = n + 1, char_name = excluded.char_name",
  )
    .bind(user.id, user.name, match)
    .run();
}

/** POST /api/watched {path}: `user` opened library match `path` (its CSV). */
export async function watched(req: Request, env: Env, user: User): Promise<Response> {
  const body = (await req.json().catch(() => null)) as { path?: unknown } | null;
  const path = body?.path;
  if (typeof path !== "string" || !path.toLowerCase().endsWith(".csv")) return json({ error: "path must be a match CSV" }, 400);
  const row = await env.DB.prepare("SELECT 1 FROM files WHERE path = ?").bind(path).first();
  if (row === null) return json({ error: "no such match" }, 400);
  await record(env, user, path);
  return json({ ok: true });
}

/** Drops counts older than KEEP_DAYS (run daily by the scheduled handler). */
export async function prune(env: Env): Promise<void> {
  await env.DB.prepare("DELETE FROM activity WHERE day < date('now', ?)").bind(`-${KEEP_DAYS} days`).run();
}

export interface PilotActivity {
  char_id: number;
  char_name: string;
  days: number;
  visits: number;
  opens: number;
  last_day: string;
}

export interface MatchActivity {
  match: string;
  viewers: number;
  opens: number;
}

/** The last SUMMARY_DAYS days per character and per match, most recent / most watched first. */
export async function summary(env: Env): Promise<{ days: number; pilots: PilotActivity[]; matches: MatchActivity[] }> {
  const since = `-${SUMMARY_DAYS} days`;
  const [pilots, matches] = await env.DB.batch([
    env.DB.prepare(
      "SELECT char_id, MAX(char_name) AS char_name, COUNT(DISTINCT day) AS days, " +
        "SUM(CASE WHEN match = '' THEN n ELSE 0 END) AS visits, SUM(CASE WHEN match = '' THEN 0 ELSE n END) AS opens, " +
        "MAX(day) AS last_day FROM activity WHERE day >= date('now', ?) GROUP BY char_id ORDER BY last_day DESC, visits DESC",
    ).bind(since),
    env.DB.prepare(
      "SELECT match, COUNT(DISTINCT char_id) AS viewers, SUM(n) AS opens FROM activity " +
        "WHERE match != '' AND day >= date('now', ?) GROUP BY match ORDER BY viewers DESC, opens DESC LIMIT 50",
    ).bind(since),
  ]);
  return {
    days: SUMMARY_DAYS,
    pilots: pilots.results as unknown as PilotActivity[],
    matches: matches.results as unknown as MatchActivity[],
  };
}
