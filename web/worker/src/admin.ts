// /admin: who may log in. Admins (ADMIN_CHAR_IDS) add or remove whitelisted characters and
// alliances by name or ID; names are resolved through ESI.

import { deps } from "./auth";
import { Env, User, audit, escapeHtml, html, now, redirect } from "./util";

const ESI = "https://esi.evetech.net/latest";

interface Row {
  kind: "character" | "alliance";
  id: number;
  name: string;
  added_at: number;
}

export async function adminPage(env: Env, user: User, message = ""): Promise<Response> {
  const { results } = await env.DB.prepare("SELECT kind, id, name, added_at FROM whitelist ORDER BY kind, name").all<Row>();
  const rows = results
    .map(
      (r) => `<tr><td>${r.kind}</td><td>${escapeHtml(r.name)}</td><td>${r.id}</td>
<td>${new Date(r.added_at * 1000).toISOString().slice(0, 10)}</td>
<td><form method="post" action="/admin/remove"><input type="hidden" name="kind" value="${r.kind}">
<input type="hidden" name="id" value="${r.id}"><button>Remove</button></form></td></tr>`,
    )
    .join("");
  return html(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Scrim Simulator admin</title><style>
body{font:15px system-ui,sans-serif;background:#0f1117;color:#dde;margin:0;padding:24px}
main{max-width:760px;margin:auto}a{color:#8fc3ff}table{border-collapse:collapse;width:100%}
td,th{padding:6px 8px;border-bottom:1px solid #2a2e3a;text-align:left}
input,select,button{font:inherit;padding:4px 8px;background:#1b1f2a;color:#dde;border:1px solid #39405a;border-radius:4px}
.msg{padding:8px;background:#1b2a1f;border-radius:4px}</style></head><body><main>
<p><a href="/">← Simulator</a> · logged in as ${escapeHtml(user.name)}</p>
<h1>Whitelist</h1>
${message ? `<p class="msg">${escapeHtml(message)}</p>` : ""}
<form method="post" action="/admin/add">
<select name="kind"><option value="character">Character</option><option value="alliance">Alliance</option></select>
<input name="who" placeholder="Exact name or ID" required size="32"> <button>Add</button></form>
<table><tr><th>Kind</th><th>Name</th><th>ID</th><th>Added</th><th></th></tr>${rows ||
    '<tr><td colspan="5">Nobody yet: only admins can log in.</td></tr>'}</table>
</main></body></html>`);
}

export async function adminPost(req: Request, env: Env, user: User, action: string): Promise<Response> {
  const form = await req.formData();
  const kind = String(form.get("kind") ?? "");
  if (kind !== "character" && kind !== "alliance") return adminPage(env, user, "Pick character or alliance.");
  if (action === "remove") {
    const id = parseInt(String(form.get("id") ?? ""), 10);
    await env.DB.prepare("DELETE FROM whitelist WHERE kind = ? AND id = ?").bind(kind, id).run();
    // Their sessions are dropped at the next affiliation re-check; drop characters' right away.
    if (kind === "character") await env.DB.prepare("DELETE FROM sessions WHERE char_id = ?").bind(id).run();
    await audit(env, user, "whitelist remove", { kind, id });
    return redirect("/admin");
  }
  const who = String(form.get("who") ?? "").trim();
  const found = await resolve(kind, who);
  if (!found) return adminPage(env, user, `No ${kind} named or numbered "${who}" on ESI.`);
  await env.DB.prepare(
    "INSERT INTO whitelist (kind, id, name, added_by, added_at) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT (kind, id) DO UPDATE SET name = excluded.name",
  )
    .bind(kind, found.id, found.name, user.id, now())
    .run();
  await audit(env, user, "whitelist add", { kind, ...found });
  return adminPage(env, user, `Added ${kind} ${found.name} (${found.id}).`);
}

/** `who` (an exact name or a numeric ID) looked up on ESI as a `kind`. */
async function resolve(kind: "character" | "alliance", who: string): Promise<{ id: number; name: string } | null> {
  if (/^\d+$/.test(who)) {
    const id = parseInt(who, 10);
    const res = await deps.fetch(`${ESI}/universe/names/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify([id]),
    });
    if (!res.ok) return null;
    const rows = (await res.json()) as { id: number; name: string; category: string }[];
    const row = rows.find((r) => r.id === id && r.category === kind);
    return row ? { id, name: row.name } : null;
  }
  const res = await deps.fetch(`${ESI}/universe/ids/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify([who]),
  });
  if (!res.ok) return null;
  const body = (await res.json()) as Record<string, { id: number; name: string }[] | undefined>;
  const list = body[kind === "character" ? "characters" : "alliances"] ?? [];
  const row = list.find((r) => r.name.toLowerCase() === who.toLowerCase()) ?? list[0];
  return row ? { id: row.id, name: row.name } : null;
}
