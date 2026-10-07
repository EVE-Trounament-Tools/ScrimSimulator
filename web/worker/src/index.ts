// Scrim Simulator website. Every route but the login flow needs a session of an allowed
// character (see auth.ts). Layout:
//   /auth/*               EVE SSO login, logout (and /auth/dev for local development)
//   /admin                whitelist management (admins only)
//   /api/*                shared match library, blobs, per-character settings (library.ts)
//   /assets/*             server-side SDE / ship model / icon mirror (R2 assets/*)
//   / and /<file>         the Godot web build named by kv current_build (R2 builds/<tag>/*)

import { adminPage, adminPost } from "./admin";
import { SESSION_COOKIE, callback, currentUser, devLoginAllowed, login, logout, startSession } from "./auth";
import {
  commit,
  commitResponse,
  getBlob,
  getSettings,
  manifest,
  missingBlobs,
  putBlob,
  putSettings,
} from "./library";
import { errorPage, loginPage, noBuildPage } from "./pages";
import { Env, User, cookie, escapeHtml, json, redirect, sameOrigin, scriptJson, withSecurity } from "./util";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    return withSecurity(await route(req, env));
  },
} satisfies ExportedHandler<Env>;

export async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;
  const method = req.method;

  if (method !== "GET" && method !== "HEAD" && !sameOrigin(req)) {
    return json({ error: "cross-origin request refused" }, 403);
  }

  if (path === "/auth/login") return login(req, env);
  if (path === "/auth/logout") return logout(req, env);
  if (path === "/auth/callback" || path === "/auth/dev") {
    let result;
    if (path === "/auth/dev") {
      if (!devLoginAllowed(req, env)) return json({ error: "not found" }, 404);
      const [id, ...name] = env.DEV_LOGIN_CHAR!.split(":");
      result = await startSession(env, parseInt(id, 10), name.join(":") || "Dev Pilot", {
        allianceId: null,
        corporationId: null,
      });
    } else {
      result = await callback(req, env);
    }
    if (!result.ok) return errorPage(result.message, result.status);
    return redirect("/", { "Set-Cookie": result.setCookie });
  }

  const user = await currentUser(req, env);
  if (user === "denied") {
    const res = errorPage("Your character is no longer on this site's whitelist.", 403);
    res.headers.append("Set-Cookie", cookie(SESSION_COOKIE, "", 0));
    return res;
  }
  if (user === null) {
    if (path.startsWith("/api/") || path.startsWith("/assets/")) return json({ error: "not logged in" }, 401);
    if (path === "/") return loginPage(devLoginAllowed(req, env));
    return redirect("/");
  }

  if (path === "/admin" || path.startsWith("/admin/")) {
    if (!user.admin) return json({ error: "admins only" }, 403);
    if (method === "GET" && path === "/admin") return adminPage(env, user);
    if (method === "POST" && (path === "/admin/add" || path === "/admin/remove")) {
      return adminPost(req, env, user, path.slice("/admin/".length));
    }
    return json({ error: "not found" }, 404);
  }
  if (path.startsWith("/api/")) return api(req, env, user, path.slice("/api/".length));
  if (path.startsWith("/assets/")) return asset(req, env, path.slice("/assets/".length));
  if (method !== "GET" && method !== "HEAD") return json({ error: "method not allowed" }, 405);
  return build(req, env, user, path === "/" ? "index.html" : path.slice(1));
}

async function api(req: Request, env: Env, user: User, sub: string): Promise<Response> {
  const m = req.method;
  if (sub === "me" && m === "GET") return json({ id: user.id, name: user.name, admin: user.admin });
  if (sub === "library" && m === "GET") return json(await manifest(env));
  if (sub === "library/commit" && m === "POST") {
    const body = (await req.json().catch(() => null)) as { ops?: unknown } | null;
    return commitResponse(await commit(env, user, body?.ops));
  }
  if (sub === "blobs/missing" && m === "POST") {
    const body = (await req.json().catch(() => null)) as { shas?: unknown } | null;
    return missingBlobs(env, body?.shas);
  }
  const blob = /^blobs\/([0-9a-f]{64})$/.exec(sub);
  if (blob && m === "GET") return getBlob(env, blob[1]);
  if (blob && m === "PUT") return putBlob(req, env, blob[1]);
  if (sub === "settings" && m === "GET") {
    const body = await getSettings(env, user);
    return body === null ? json({ error: "no settings yet" }, 404) : new Response(body, { headers: { "Cache-Control": "no-store" } });
  }
  if (sub === "settings" && m === "PUT") return putSettings(req, env, user);
  return json({ error: "not found" }, 404);
}

const TYPES: Record<string, string> = {
  html: "text/html; charset=utf-8",
  js: "text/javascript",
  wasm: "application/wasm",
  pck: "application/octet-stream",
  png: "image/png",
  svg: "image/svg+xml",
  ico: "image/x-icon",
  json: "application/json",
  zip: "application/zip",
  glb: "model/gltf-binary",
};

function contentType(key: string): string {
  return TYPES[key.slice(key.lastIndexOf(".") + 1).toLowerCase()] ?? "application/octet-stream";
}

/** Streams R2 object `key` with ETag revalidation (a matching If-None-Match gets a 304). */
async function serveObject(req: Request, env: Env, key: string, cacheControl: string): Promise<Response> {
  const obj = await env.BUCKET.get(key, { onlyIf: req.headers });
  if (obj === null) return json({ error: "not found" }, 404);
  const headers = new Headers({ "Content-Type": contentType(key), "Cache-Control": cacheControl, ETag: obj.httpEtag });
  if (!("body" in obj)) return new Response(null, { status: 304, headers });
  headers.set("Content-Length", String(obj.size));
  return new Response(req.method === "HEAD" ? null : obj.body, { headers });
}

function safeKey(rest: string): boolean {
  return rest.length > 0 && rest.split("/").every((s) => s !== "" && s !== "." && s !== "..");
}

async function asset(req: Request, env: Env, rest: string): Promise<Response> {
  if (!safeKey(rest)) return json({ error: "not found" }, 404);
  return serveObject(req, env, `assets/${rest}`, "private, no-cache");
}

async function currentBuild(env: Env): Promise<string | null> {
  const row = await env.DB.prepare("SELECT value FROM kv WHERE key = 'current_build'").first<{ value: string }>();
  return row?.value ?? null;
}

async function build(req: Request, env: Env, user: User, file: string): Promise<Response> {
  const tag = await currentBuild(env);
  if (tag === null) return noBuildPage();
  if (!safeKey(file)) return json({ error: "not found" }, 404);
  const key = `builds/${tag}/${file}`;
  if (file !== "index.html") return serveObject(req, env, key, "private, no-cache");

  const obj = await env.BUCKET.get(key);
  if (obj === null) return noBuildPage();
  // Boot data the web build reads synchronously at startup (web_backend.gd): who is logged in,
  // their saved settings and the library manifest, so the first frame already shows the library.
  const boot = {
    build: tag,
    character: { id: user.id, name: user.name },
    admin: user.admin,
    settings: await getSettings(env, user),
    library: await manifest(env),
  };
  const bar = `<div id="scrim-user" style="position:fixed;right:6px;bottom:4px;z-index:10;font:11px system-ui,sans-serif;color:#aab;opacity:.75">
${escapeHtml(user.name)}${user.admin ? ' · <a href="/admin" style="color:#8fc3ff">admin</a>' : ""} · <a href="/auth/logout" style="color:#8fc3ff">log out</a></div>`;
  const res = new HTMLRewriter()
    .on("head", {
      element(el) {
        el.prepend(`<script>window.scrimBoot = ${scriptJson(boot)};</script>`, { html: true });
      },
    })
    .on("body", {
      element(el) {
        el.append(bar, { html: true });
      },
    })
    .transform(new Response(obj.body, { headers: { "Content-Type": TYPES.html, "Cache-Control": "no-store" } }));
  return res;
}

