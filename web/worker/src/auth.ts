// EVE SSO login (OAuth2 authorization code flow, no scopes: only the character's identity is
// needed) and sessions. Access needs a whitelisted character, membership of a whitelisted
// alliance, or an admin character (ADMIN_CHAR_IDS); affiliation is re-checked daily, so a pilot
// who leaves the alliance loses access.

import {
  Env,
  User,
  adminIds,
  base64urlDecode,
  cookie,
  getCookie,
  now,
  randomToken,
  redirect,
  sha256Hex,
} from "./util";

export const SESSION_COOKIE = "ss_session";
const STATE_COOKIE = "ss_oauth_state";
const SESSION_TTL = 30 * 24 * 3600;
const RECHECK_AFTER = 24 * 3600;

const SSO = "https://login.eveonline.com";
const AUTHORIZE_URL = `${SSO}/v2/oauth/authorize`;
const TOKEN_URL = `${SSO}/v2/oauth/token`;
const JWKS_URL = `${SSO}/oauth/jwks`;
const ESI = "https://esi.evetech.net/latest";
const USER_AGENT = "scrimSimulator web (EVE scrim replay tool)";

export interface Affiliation {
  allianceId: number | null;
  corporationId: number | null;
}

/** Overridable in tests. */
export const deps = {
  fetch: (input: RequestInfo, init?: RequestInit) => fetch(input, init),
};

// --- login flow --------------------------------------------------------------------------

export function login(req: Request, env: Env): Response {
  const url = new URL(req.url);
  const state = randomToken(24);
  const params = new URLSearchParams({
    response_type: "code",
    redirect_uri: `${url.origin}/auth/callback`,
    client_id: env.EVE_CLIENT_ID,
    state,
  });
  return redirect(`${AUTHORIZE_URL}?${params}`, { "Set-Cookie": cookie(STATE_COOKIE, state, 600, "/auth") });
}

/** Result of the SSO callback: a session cookie to set, or why login was refused. */
export type CallbackResult =
  | { ok: true; setCookie: string; user: User }
  | { ok: false; status: number; message: string };

export async function callback(req: Request, env: Env): Promise<CallbackResult> {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const expected = getCookie(req, STATE_COOKIE);
  if (!code || !state || !expected || state !== expected) {
    return { ok: false, status: 400, message: "Login expired or was started elsewhere. Please try again." };
  }
  const tokenRes = await deps.fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${env.EVE_CLIENT_ID}:${env.EVE_CLIENT_SECRET}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": USER_AGENT,
    },
    body: new URLSearchParams({ grant_type: "authorization_code", code }),
  });
  if (!tokenRes.ok) {
    return { ok: false, status: 502, message: `EVE SSO token exchange failed (HTTP ${tokenRes.status}).` };
  }
  const token = (await tokenRes.json()) as { access_token?: string };
  const claims = token.access_token ? await verifyJwt(token.access_token, env.EVE_CLIENT_ID) : null;
  if (!claims) {
    return { ok: false, status: 502, message: "EVE SSO returned a token that didn't verify." };
  }
  const id = parseInt(String(claims.sub).replace(/^CHARACTER:EVE:/, ""), 10);
  const name = String(claims.name ?? "");
  if (!Number.isFinite(id) || id <= 0) {
    return { ok: false, status: 502, message: "EVE SSO token has no character." };
  }
  return startSession(env, id, name);
}

/** Checks `id` against the whitelist and, if allowed, makes a session for it. `known` skips the
 * ESI affiliation lookup (the development login's made-up character has none). */
export async function startSession(env: Env, id: number, name: string, known?: Affiliation): Promise<CallbackResult> {
  const aff = known ?? (await affiliation(id));
  if (aff === null) {
    return { ok: false, status: 502, message: "Couldn't look up your alliance on ESI. Please try again." };
  }
  if (!(await allowed(env, id, aff.allianceId))) {
    return { ok: false, status: 403, message: `${name} isn't on this site's whitelist.` };
  }
  const sid = randomToken(32);
  const t = now();
  await env.DB.prepare(
    "INSERT INTO sessions (id_hash, char_id, char_name, alliance_id, created_at, checked_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(await sha256Hex(sid), id, name, aff.allianceId, t, t, t + SESSION_TTL)
    .run();
  return {
    ok: true,
    setCookie: cookie(SESSION_COOKIE, sid, SESSION_TTL),
    user: { id, name, allianceId: aff.allianceId, admin: adminIds(env).has(id) },
  };
}

export async function logout(req: Request, env: Env): Promise<Response> {
  const sid = getCookie(req, SESSION_COOKIE);
  if (sid) await env.DB.prepare("DELETE FROM sessions WHERE id_hash = ?").bind(await sha256Hex(sid)).run();
  return redirect("/", { "Set-Cookie": cookie(SESSION_COOKIE, "", 0) });
}

/** Local development: log in as DEV_LOGIN_CHAR ("<id>:<name>") without EVE SSO. Only on
 * localhost, and only when that variable is set (it never is in production). */
export function devLoginAllowed(req: Request, env: Env): boolean {
  const host = new URL(req.url).hostname;
  return !!env.DEV_LOGIN_CHAR && (host === "localhost" || host === "127.0.0.1");
}

// --- sessions ----------------------------------------------------------------------------

/** The request's logged-in user: null when there is no valid session, "denied" when the
 * session's character is no longer allowed (the session is then deleted). */
export async function currentUser(req: Request, env: Env): Promise<User | null | "denied"> {
  const sid = getCookie(req, SESSION_COOKIE);
  if (!sid) return null;
  const hash = await sha256Hex(sid);
  const row = await env.DB.prepare(
    "SELECT char_id, char_name, alliance_id, checked_at, expires_at FROM sessions WHERE id_hash = ?",
  )
    .bind(hash)
    .first<{ char_id: number; char_name: string; alliance_id: number | null; checked_at: number; expires_at: number }>();
  const t = now();
  if (!row || row.expires_at < t) return null;
  let allianceId = row.alliance_id;
  if (t - row.checked_at > RECHECK_AFTER) {
    const aff = await affiliation(row.char_id);
    // ESI down: keep the session on its last known affiliation until it next succeeds.
    if (aff !== null) {
      allianceId = aff.allianceId;
      if (!(await allowed(env, row.char_id, allianceId))) {
        await env.DB.prepare("DELETE FROM sessions WHERE char_id = ?").bind(row.char_id).run();
        return "denied";
      }
      await env.DB.prepare("UPDATE sessions SET alliance_id = ?, checked_at = ? WHERE id_hash = ?")
        .bind(allianceId, t, hash)
        .run();
    }
  }
  return { id: row.char_id, name: row.char_name, allianceId, admin: adminIds(env).has(row.char_id) };
}

export async function allowed(env: Env, charId: number, allianceId: number | null): Promise<boolean> {
  if (adminIds(env).has(charId)) return true;
  const row = await env.DB.prepare(
    "SELECT 1 FROM whitelist WHERE (kind = 'character' AND id = ?) OR (kind = 'alliance' AND id = ?) LIMIT 1",
  )
    .bind(charId, allianceId ?? -1)
    .first();
  return row !== null;
}

/** The character's current alliance, from ESI's public affiliation endpoint; null on failure. */
export async function affiliation(charId: number): Promise<Affiliation | null> {
  try {
    const res = await deps.fetch(`${ESI}/characters/affiliation/`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "User-Agent": USER_AGENT },
      body: JSON.stringify([charId]),
    });
    if (!res.ok) return null;
    const rows = (await res.json()) as { character_id: number; alliance_id?: number; corporation_id?: number }[];
    const row = rows.find((r) => r.character_id === charId);
    if (!row) return null;
    return { allianceId: row.alliance_id ?? null, corporationId: row.corporation_id ?? null };
  } catch {
    return null;
  }
}

// --- JWT verification ----------------------------------------------------------------------

let jwksCache: { keys: JsonWebKey[]; at: number } | null = null;

export function resetJwksCache(): void {
  jwksCache = null;
}

async function jwks(refresh = false): Promise<JsonWebKey[]> {
  if (!refresh && jwksCache && Date.now() - jwksCache.at < 3600_000) return jwksCache.keys;
  const res = await deps.fetch(JWKS_URL, { headers: { "User-Agent": USER_AGENT } });
  if (!res.ok) throw new Error(`JWKS HTTP ${res.status}`);
  const body = (await res.json()) as { keys: JsonWebKey[] };
  jwksCache = { keys: body.keys, at: Date.now() };
  return body.keys;
}

/** Claims of EVE SSO access token `jwt` if its RS256 signature, issuer, audience and expiry
 * check out, else null. */
export async function verifyJwt(jwt: string, clientId: string): Promise<Record<string, unknown> | null> {
  const parts = jwt.split(".");
  if (parts.length !== 3) return null;
  let header: { alg?: string; kid?: string };
  let claims: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[1])));
  } catch {
    return null;
  }
  if (header.alg !== "RS256") return null;
  const data = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const sig = base64urlDecode(parts[2]);
  let verified = false;
  for (const refresh of [false, true]) {
    let keys: JsonWebKey[];
    try {
      keys = await jwks(refresh);
    } catch {
      return null;
    }
    const jwk = keys.find((k) => (k as { kid?: string }).kid === header.kid && k.kty === "RSA");
    if (!jwk) continue;
    const key = await crypto.subtle.importKey(
      "jwk",
      { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    verified = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sig, data);
    break;
  }
  if (!verified) return null;
  const iss = String(claims.iss ?? "");
  if (iss !== "login.eveonline.com" && iss !== "https://login.eveonline.com") return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(clientId)) return null;
  if (typeof claims.exp !== "number" || claims.exp < now()) return null;
  return claims;
}
