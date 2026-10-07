export interface Env {
  DB: D1Database;
  BUCKET: R2Bucket;
  EVE_CLIENT_ID: string;
  EVE_CLIENT_SECRET: string;
  ADMIN_CHAR_IDS?: string;
  MAX_UPLOAD_BYTES?: string;
  DEV_LOGIN_CHAR?: string;
}

/** The logged-in character a request is made by. */
export interface User {
  id: number;
  name: string;
  allianceId: number | null;
  admin: boolean;
}

/** Headers every response carries. Cross-origin isolation (COOP + COEP) is what lets the
 * threaded Godot web build use SharedArrayBuffer; everything the page loads is same-origin. */
export const SECURITY_HEADERS: Record<string, string> = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
  "Cross-Origin-Resource-Policy": "same-origin",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "same-origin",
};

export function withSecurity(res: Response): Response {
  const out = new Response(res.body, res);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) out.headers.set(k, v);
  return out;
}

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });
}

export function html(body: string, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", ...headers },
  });
}

export function text(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

export function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store", ...headers } });
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/** JSON safe to embed in an inline <script>. */
export function scriptJson(data: unknown): string {
  return JSON.stringify(data)
    .replace(/</g, "\\u003c")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

export function getCookie(req: Request, name: string): string | null {
  const header = req.headers.get("Cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return null;
}

export function cookie(name: string, value: string, maxAge: number, path = "/"): string {
  return `${name}=${encodeURIComponent(value)}; Path=${path}; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;
}

export function randomToken(bytes = 32): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(b);
}

export function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(s: string): Uint8Array {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

export async function sha256Hex(data: string | ArrayBuffer | Uint8Array): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function now(): number {
  return Math.floor(Date.now() / 1000);
}

export function adminIds(env: Env): Set<number> {
  return new Set(
    (env.ADMIN_CHAR_IDS ?? "")
      .split(",")
      .map((s) => parseInt(s.trim(), 10))
      .filter((n) => Number.isFinite(n) && n > 0),
  );
}

/** Whether a state-changing request comes from this site (SameSite=Lax cookies already stop
 * cross-site POSTs; this also covers same-site subdomains). */
export function sameOrigin(req: Request): boolean {
  const origin = req.headers.get("Origin");
  if (origin === null) return req.headers.get("Sec-Fetch-Site") !== "cross-site";
  return origin === new URL(req.url).origin;
}

export async function audit(env: Env, user: User, action: string, detail: unknown): Promise<void> {
  await env.DB.prepare("INSERT INTO audit (at, char_id, char_name, action, detail) VALUES (?, ?, ?, ?, ?)")
    .bind(now(), user.id, user.name, action, JSON.stringify(detail))
    .run();
}
