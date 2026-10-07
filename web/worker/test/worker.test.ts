// Worker tests against local D1/R2 (miniflare), with EVE SSO and ESI faked. Synthetic data only.
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { deps, resetJwksCache, startSession, verifyJwt } from "../src/auth";
import { matchKey, validPath } from "../src/library";
import { route } from "../src/index";
import { Env, base64url, sha256Hex } from "../src/util";

const E = env as unknown as Env;
const ORIGIN = "https://sim.example";
const ADMIN = 9000;

/** Fake ESI: character id -> alliance id (or null). */
let alliances: Record<number, number | null> = {};
let esiNames: Record<string, { id: number; name: string; kind: string }> = {};
let ssoHandler: ((url: string, init?: RequestInit) => Response | Promise<Response>) | null = null;

beforeEach(async () => {
  alliances = {};
  esiNames = {};
  ssoHandler = null;
  resetJwksCache();
  deps.fetch = async (input: RequestInfo, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.url;
    if (url.endsWith("/characters/affiliation/")) {
      const ids = JSON.parse(String(init?.body)) as number[];
      return Response.json(
        ids.filter((id) => id in alliances).map((id) => ({
          character_id: id,
          corporation_id: 1000,
          ...(alliances[id] ? { alliance_id: alliances[id] } : {}),
        })),
      );
    }
    if (url.endsWith("/universe/ids/")) {
      const [name] = JSON.parse(String(init?.body)) as string[];
      const hit = esiNames[name.toLowerCase()];
      return Response.json(hit ? { [hit.kind === "character" ? "characters" : "alliances"]: [{ id: hit.id, name: hit.name }] } : {});
    }
    if (ssoHandler) return ssoHandler(url, init);
    return new Response("unexpected fetch " + url, { status: 599 });
  };
  await E.DB.batch([
    E.DB.prepare("DELETE FROM whitelist"),
    E.DB.prepare("DELETE FROM sessions"),
    E.DB.prepare("DELETE FROM files"),
    E.DB.prepare("DELETE FROM settings"),
    E.DB.prepare("DELETE FROM kv"),
  ]);
});

async function whitelist(kind: "character" | "alliance", id: number) {
  await E.DB.prepare("INSERT INTO whitelist (kind, id, name, added_at) VALUES (?, ?, ?, 0)").bind(kind, id, `${kind} ${id}`).run();
}

async function session(id: number, name = `Pilot ${id}`, alliance: number | null = null): Promise<string> {
  alliances[id] = alliance;
  const r = await startSession(E, id, name);
  if (!r.ok) throw new Error(r.message);
  return r.setCookie.split(";")[0];
}

function call(path: string, opts: { method?: string; cookie?: string; body?: BodyInit; json?: unknown; origin?: string | null; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.cookie) headers.Cookie = opts.cookie;
  const method = opts.method ?? "GET";
  if (method !== "GET" && opts.origin !== null) headers.Origin = opts.origin ?? ORIGIN;
  let body = opts.body;
  if (opts.json !== undefined) {
    body = JSON.stringify(opts.json);
    headers["Content-Type"] = "application/json";
  }
  return route(new Request(ORIGIN + path, { method, headers, body }), E);
}

async function upload(cookie: string, content: string): Promise<{ sha: string; size: number }> {
  const bytes = new TextEncoder().encode(content);
  const sha = await sha256Hex(bytes);
  const r = await call(`/api/blobs/${sha}`, { method: "PUT", cookie, body: bytes, headers: { "Content-Length": String(bytes.length) } });
  expect(r.status).toBe(200);
  return { sha, size: bytes.length };
}

async function manifest(cookie: string) {
  const r = await call("/api/library", { cookie });
  return (await r.json()) as { version: number; files: { path: string; sha: string; owner_id: number }[] };
}

describe("access", () => {
  it("shows the login page and refuses the API without a session", async () => {
    expect(await (await call("/")).text()).toContain("Log in with EVE Online");
    expect((await call("/api/library")).status).toBe(401);
    expect((await call("/assets/ship_sizes.json")).status).toBe(401);
    expect((await call("/index.wasm")).status).toBe(302);
  });

  it("lets in whitelisted characters, alliance members and admins only", async () => {
    await whitelist("character", 1);
    await whitelist("alliance", 500);
    expect((await startSession(E, 1, "A")).ok).toBe(false); // ESI affiliation unknown
    alliances = { 1: null, 2: 500, 3: 600, [ADMIN]: null };
    expect((await startSession(E, 1, "A")).ok).toBe(true);
    expect((await startSession(E, 2, "B")).ok).toBe(true);
    const denied = await startSession(E, 3, "C");
    expect(denied.ok).toBe(false);
    expect(denied.ok === false && denied.status).toBe(403);
    expect((await startSession(E, ADMIN, "Boss")).ok).toBe(true);
  });

  it("drops a session whose pilot left the alliance, at the daily re-check", async () => {
    await whitelist("alliance", 500);
    const cookie = await session(2, "B", 500);
    expect((await call("/api/me", { cookie })).status).toBe(200);
    alliances[2] = 700;
    expect((await call("/api/me", { cookie })).status).toBe(200); // not re-checked yet
    await E.DB.prepare("UPDATE sessions SET checked_at = 0").run();
    const r = await call("/api/me", { cookie });
    expect(r.status).toBe(403);
    expect((await call("/api/me", { cookie })).status).toBe(401);
  });

  it("refuses cross-origin state changes", async () => {
    await whitelist("character", 1);
    const cookie = await session(1);
    const r = await call("/api/settings", { method: "PUT", cookie, body: "x", origin: "https://evil.example" });
    expect(r.status).toBe(403);
  });

  it("logs out", async () => {
    await whitelist("character", 1);
    const cookie = await session(1);
    const r = await call("/auth/logout", { cookie });
    expect(r.status).toBe(302);
    expect((await call("/api/me", { cookie })).status).toBe(401);
  });

  it("allows the development login only when configured and on localhost", async () => {
    expect((await call("/auth/dev")).status).toBe(404);
    const dev = { ...E, DEV_LOGIN_CHAR: `${ADMIN}:Dev` } as Env;
    alliances[ADMIN] = null;
    expect((await route(new Request(ORIGIN + "/auth/dev"), dev)).status).toBe(404);
    const r = await route(new Request("http://localhost:8787/auth/dev"), dev);
    expect(r.status).toBe(302);
    expect(r.headers.get("Set-Cookie")).toContain("ss_session=");
  });
});

describe("EVE SSO", () => {
  async function keyPair() {
    const pair = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
    return { pair, jwk: { ...jwk, kid: "JWT-Signature-Key", alg: "RS256" } };
  }

  async function sign(key: CryptoKey, claims: Record<string, unknown>) {
    const enc = (o: unknown) => base64url(new TextEncoder().encode(JSON.stringify(o)));
    const head = enc({ alg: "RS256", kid: "JWT-Signature-Key", typ: "JWT" });
    const body = enc(claims);
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${body}`));
    return `${head}.${body}.${base64url(new Uint8Array(sig))}`;
  }

  const claims = (over: Record<string, unknown> = {}) => ({
    sub: "CHARACTER:EVE:1",
    name: "Test Pilot",
    iss: "https://login.eveonline.com",
    aud: ["test-client", "EVE Online"],
    exp: Math.floor(Date.now() / 1000) + 600,
    ...over,
  });

  it("verifies signature, issuer, audience and expiry", async () => {
    const { pair, jwk } = await keyPair();
    const other = await keyPair();
    ssoHandler = (url) => (url.endsWith("/oauth/jwks") ? Response.json({ keys: [jwk] }) : new Response("", { status: 404 }));
    expect(await verifyJwt(await sign(pair.privateKey, claims()), "test-client")).not.toBeNull();
    expect(await verifyJwt(await sign(pair.privateKey, claims({ aud: ["someone-else"] })), "test-client")).toBeNull();
    expect(await verifyJwt(await sign(pair.privateKey, claims({ iss: "evil" })), "test-client")).toBeNull();
    expect(await verifyJwt(await sign(pair.privateKey, claims({ exp: 1 })), "test-client")).toBeNull();
    expect(await verifyJwt(await sign(other.pair.privateKey, claims()), "test-client")).toBeNull();
  });

  it("logs a whitelisted character in through the callback", async () => {
    const { pair, jwk } = await keyPair();
    const token = await sign(pair.privateKey, claims());
    ssoHandler = (url, init) => {
      if (url.endsWith("/oauth/jwks")) return Response.json({ keys: [jwk] });
      if (url.endsWith("/v2/oauth/token")) {
        expect(new Headers(init?.headers).get("Authorization")).toBe(`Basic ${btoa("test-client:test-secret")}`);
        expect(String(init?.body)).toContain("code=abc");
        return Response.json({ access_token: token });
      }
      return new Response("", { status: 404 });
    };
    const start = await call("/auth/login");
    const loc = new URL(start.headers.get("Location")!);
    expect(loc.host).toBe("login.eveonline.com");
    expect(loc.searchParams.get("redirect_uri")).toBe(`${ORIGIN}/auth/callback`);
    const state = loc.searchParams.get("state")!;
    const stateCookie = start.headers.get("Set-Cookie")!.split(";")[0];

    alliances[1] = null;
    expect((await call(`/auth/callback?code=abc&state=wrong`, { cookie: stateCookie })).status).toBe(400);
    expect((await call(`/auth/callback?code=abc&state=${state}`, { cookie: stateCookie })).status).toBe(403);
    await whitelist("character", 1);
    const ok = await call(`/auth/callback?code=abc&state=${state}`, { cookie: stateCookie });
    expect(ok.status).toBe(302);
    const cookie = ok.headers.get("Set-Cookie")!.split(";")[0];
    expect(await (await call("/api/me", { cookie })).json()).toEqual({ id: 1, name: "Test Pilot", admin: false });
  });
});

describe("library", () => {
  it("validates paths and groups a match's files", () => {
    expect(validPath("Season 1/m.positions.csv")).toBe(true);
    expect(validPath("Season 1/")).toBe(true);
    for (const bad of ["", "/abs", "a/../b", "a//b", "./a", "a\\b", "C:x", " a"]) expect(validPath(bad)).toBe(false);
    expect(matchKey("a/m.positions.csv")).toBe("a/m.positions");
    expect(matchKey("a/m.positions.json")).toBe("a/m.positions");
    expect(matchKey("a/m.positions.logs/x.txt")).toBe("a/m.positions");
    expect(matchKey("a/M.Positions.LOGS/x.txt")).toBe("a/M.Positions");
  });

  it("stores blobs only when the content matches the sha", async () => {
    await whitelist("character", 1);
    const cookie = await session(1);
    const bytes = new TextEncoder().encode("hello");
    const wrong = "0".repeat(64);
    const r = await call(`/api/blobs/${wrong}`, { method: "PUT", cookie, body: bytes, headers: { "Content-Length": "5" } });
    expect(r.status).toBe(400);
    const { sha } = await upload(cookie, "hello");
    expect(await (await call(`/api/blobs/${sha}`, { cookie })).text()).toBe("hello");
    const missing = await call("/api/blobs/missing", { method: "POST", cookie, json: { shas: [sha, wrong] } });
    expect(await missing.json()).toEqual({ missing: [wrong] });
  });

  it("commits files, keeps uploaders on moves and guards other people's matches", async () => {
    await whitelist("character", 1);
    await whitelist("character", 2);
    const a = await session(1, "Alice");
    const b = await session(2, "Bob");
    const csv = await upload(a, "t,pilot\n0,x\n");
    const meta = await upload(a, '{"teams":{}}');

    // Blob must exist first.
    const notYet = await call("/api/library/commit", {
      method: "POST",
      cookie: a,
      json: { ops: [{ op: "put", path: "m.positions.csv", sha: "1".repeat(64), size: 3, prev: null }] },
    });
    expect(notYet.status).toBe(409);
    expect(((await notYet.json()) as { status: string }).status).toBe("missing");

    let r = await call("/api/library/commit", {
      method: "POST",
      cookie: a,
      json: {
        ops: [
          { op: "put", path: "S1/", sha: "", size: 0, prev: null },
          { op: "put", path: "S1/m.positions.csv", ...csv, prev: null },
          { op: "put", path: "S1/m.positions.json", ...meta, prev: null },
        ],
      },
    });
    expect(r.status).toBe(200);
    let m = await manifest(b);
    expect(m.files.map((f) => [f.path, f.owner_id])).toEqual([
      ["S1/", 1],
      ["S1/m.positions.csv", 1],
      ["S1/m.positions.json", 1],
    ]);

    // Stale prev: conflict, nothing applied.
    r = await call("/api/library/commit", {
      method: "POST",
      cookie: b,
      json: { ops: [{ op: "put", path: "S1/m.positions.json", ...meta, prev: null }] },
    });
    expect(r.status).toBe(409);

    // Anyone may edit the sidecar and add a gamelog...
    const meta2 = await upload(b, '{"teams":{"x":2}}');
    const log = await upload(b, "gamelog");
    r = await call("/api/library/commit", {
      method: "POST",
      cookie: b,
      json: {
        ops: [
          { op: "put", path: "S1/m.positions.json", ...meta2, prev: meta.sha },
          { op: "put", path: "S1/m.positions.logs/b.txt", ...log, prev: null },
        ],
      },
    });
    expect(r.status).toBe(200);

    // ...but not remove or rename someone else's match.
    r = await call("/api/library/commit", {
      method: "POST",
      cookie: b,
      json: {
        ops: [
          { op: "delete", path: "S1/m.positions.csv", prev: csv.sha },
          { op: "put", path: "S1/renamed.positions.csv", ...csv, prev: null },
        ],
      },
    });
    expect(r.status).toBe(403);
    const body = (await r.json()) as { paths: string[]; reasons: Record<string, string> };
    expect(body.paths).toEqual(["S1/m.positions.csv"]);
    expect(body.reasons["S1/m.positions.csv"]).toContain("Alice");

    // The uploader renames it; the new path stays theirs.
    r = await call("/api/library/commit", {
      method: "POST",
      cookie: a,
      json: {
        ops: [
          { op: "delete", path: "S1/m.positions.csv", prev: csv.sha },
          { op: "put", path: "S1/renamed.positions.csv", ...csv, prev: null },
        ],
      },
    });
    expect(r.status).toBe(200);
    m = await manifest(a);
    expect(m.files.find((f) => f.path === "S1/renamed.positions.csv")?.owner_id).toBe(1);

    // Admins may remove anything.
    alliances[ADMIN] = null;
    const admin = await session(ADMIN, "Boss");
    r = await call("/api/library/commit", {
      method: "POST",
      cookie: admin,
      json: { ops: [{ op: "delete", path: "S1/renamed.positions.csv", prev: csv.sha }] },
    });
    expect(r.status).toBe(200);
    expect(m.version).toBeGreaterThan(0);
  });

  it("rejects malformed commits", async () => {
    await whitelist("character", 1);
    const cookie = await session(1);
    for (const ops of [[], [{ op: "put", path: "../x", sha: "a".repeat(64), size: 1, prev: null }], [{ op: "nope", path: "x" }]]) {
      expect((await call("/api/library/commit", { method: "POST", cookie, json: { ops } })).status).toBe(400);
    }
  });
});

describe("settings", () => {
  it("round-trips each character's settings", async () => {
    await whitelist("character", 1);
    await whitelist("character", 2);
    const a = await session(1);
    const b = await session(2);
    expect((await call("/api/settings", { cookie: a })).status).toBe(404);
    const cfg = '[display]\n\nui_scale=1.25\n';
    expect((await call("/api/settings", { method: "PUT", cookie: a, body: cfg })).status).toBe(200);
    expect(await (await call("/api/settings", { cookie: a })).text()).toBe(cfg);
    expect((await call("/api/settings", { cookie: b })).status).toBe(404);
  });
});

describe("admin", () => {
  it("is for admins only and adds whitelist entries by name", async () => {
    await whitelist("character", 1);
    const user = await session(1);
    expect((await call("/admin", { cookie: user })).status).toBe(403);
    alliances[ADMIN] = null;
    const admin = await session(ADMIN, "Boss");
    esiNames["some alliance"] = { id: 99000001, name: "Some Alliance", kind: "alliance" };
    const form = new URLSearchParams({ kind: "alliance", who: "some alliance" });
    const r = await call("/admin/add", {
      method: "POST",
      cookie: admin,
      body: form,
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
    });
    expect(await r.text()).toContain("Added alliance Some Alliance");
    const row = await E.DB.prepare("SELECT name FROM whitelist WHERE kind = 'alliance' AND id = 99000001").first();
    expect(row).toEqual({ name: "Some Alliance" });
  });
});

describe("site", () => {
  it("serves the current build with boot data, and assets with revalidation", async () => {
    await whitelist("character", 1);
    const cookie = await session(1, "Alice");
    expect((await call("/", { cookie })).status).toBe(503);
    await E.DB.prepare("INSERT INTO kv (key, value) VALUES ('current_build', 'v9.9.9')").run();
    await E.BUCKET.put("builds/v9.9.9/index.html", "<html><head><title>x</title></head><body></body></html>");
    await E.BUCKET.put("builds/v9.9.9/index.wasm", "wasm");
    await E.BUCKET.put("assets/ship_sizes.json", "{}");
    const page = await (await call("/", { cookie })).text();
    expect(page).toContain("window.scrimBoot = ");
    expect(page).toContain('"name":"Alice"');
    const wasm = await call("/index.wasm", { cookie });
    expect(wasm.headers.get("Content-Type")).toBe("application/wasm");
    const a = await call("/assets/ship_sizes.json", { cookie });
    const etag = a.headers.get("ETag")!;
    expect((await call("/assets/ship_sizes.json", { cookie, headers: { "If-None-Match": etag } })).status).toBe(304);
    expect((await call("/assets/../builds/v9.9.9/index.html", { cookie })).status).not.toBe(200);
  });
});
