// /admin: who is a member (sees private matches and may change the library; anyone else who
// logs in only views public matches). Admins (ADMIN_CHAR_IDS) add or remove whitelisted
// characters and alliances by name or ID; names are resolved through ESI. Admins can also download any library
// folder as a zip, which the page builds in the browser from the blobs (a Worker has too little
// CPU time to checksum audio files).

import { summary } from "./activity";
import { deps } from "./auth";
import { FileRow, isFolder, manifest } from "./library";
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
  const lib = folders((await manifest(env)).files)
    .map((f) => {
      const depth = f.path === "" ? 0 : f.path.split("/").length - 1;
      const name = f.path === "" ? "(whole library)" : f.path.slice(0, -1).split("/").pop()!;
      return `<tr><td style="padding-left:${8 + 16 * Math.max(depth - 1, 0)}px">${escapeHtml(name)}</td><td>${f.matches}</td>
<td>${(f.bytes / 1e6).toFixed(1)} MB</td><td><button data-folder="${escapeHtml(f.path)}"${f.files ? "" : " disabled"}>Download</button></td></tr>`;
    })
    .join("");
  const act = await summary(env);
  const pilots = act.pilots
    .map((p) => `<tr><td>${escapeHtml(p.char_name)}</td><td>${p.days}</td><td>${p.visits}</td><td>${p.opens}</td><td>${p.last_day}</td></tr>`)
    .join("");
  const matches = act.matches
    .map((m) => `<tr><td>${escapeHtml(m.match)}</td><td>${m.viewers}</td><td>${m.opens}</td></tr>`)
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
    '<tr><td colspan="5">Nobody yet: only admins see private matches and change the library.</td></tr>'}</table>
<h1>Library</h1>
<table><tr><th>Folder</th><th>Matches</th><th>Size</th><th></th></tr>${lib}</table>
<h1>Activity (last ${act.days} days)</h1>
<table><tr><th>Pilot</th><th>Days</th><th>Visits</th><th>Matches opened</th><th>Last seen</th></tr>${pilots ||
    '<tr><td colspan="5">No visits yet.</td></tr>'}</table>
<h2>Most watched</h2>
<table><tr><th>Match</th><th>Pilots</th><th>Opens</th></tr>${matches ||
    '<tr><td colspan="3">No matches opened yet.</td></tr>'}</table>
</main><script>${DOWNLOAD_JS}</script></body></html>`);
}

interface Folder {
  path: string;
  matches: number;
  files: number;
  bytes: number;
}

/** Every library folder ("" is the whole library), whether it has its own row or is only implied
 * by the paths under it, with the matches, files and bytes it holds. A match's gamelog folder
 * (X.positions.logs/) belongs to the match, so it isn't listed. */
export function folders(files: FileRow[]): Folder[] {
  const by = new Map<string, Folder>();
  const get = (path: string): Folder => {
    let f = by.get(path);
    if (!f) by.set(path, (f = { path, matches: 0, files: 0, bytes: 0 }));
    return f;
  };
  get("");
  for (const row of files) {
    const within = [get("")];
    for (let i = row.path.indexOf("/"); i !== -1; i = row.path.indexOf("/", i + 1)) {
      const dir = row.path.slice(0, i + 1);
      if (dir.toLowerCase().endsWith(".logs/")) break;
      within.push(get(dir));
    }
    if (isFolder(row.path)) continue;
    for (const f of within) {
      f.files++;
      f.bytes += row.size;
      if (row.path.toLowerCase().endsWith(".csv")) f.matches++;
    }
  }
  return [...by.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

// Builds an uncompressed zip of a folder's files from /api/library and /api/blobs/<sha>, holding
// the parts as Blobs (which browsers can keep on disk). Entries are named from the folder itself,
// so unzipping into the desktop app's matches folder recreates it. No ZIP64: up to 4 GB.
const DOWNLOAD_JS = `
const CRC = new Uint32Array(256).map((_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n;
});
function crc32(b) {
  let c = ~0;
  for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 255] ^ (c >>> 8);
  return ~c >>> 0;
}
function dos(mtime) {
  const d = new Date(Math.max(mtime * 1000, Date.UTC(1980, 0, 1, 12)));
  return [(d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1),
    ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()];
}
async function download(btn) {
  const folder = btn.dataset.folder;
  const res = await fetch("/api/library");
  if (!res.ok) throw new Error("library: HTTP " + res.status);
  const rows = (await res.json()).files.filter((f) => f.path.startsWith(folder));
  const total = rows.reduce((s, f) => s + f.size, 0);
  if (total + rows.length * 1024 >= 2 ** 32 || rows.length > 65535) throw new Error("too big for a zip without ZIP64");
  const base = folder.slice(0, folder.slice(0, -1).lastIndexOf("/") + 1);
  const count = rows.filter((f) => !f.path.endsWith("/")).length;
  const enc = new TextEncoder();
  const parts = [], central = [];
  let offset = 0, n = 0;
  for (const f of rows) {
    const name = enc.encode(f.path.slice(base.length));
    const dir = f.path.endsWith("/");
    let data = new Blob([]), crc = 0;
    if (!dir) {
      btn.textContent = ++n + "/" + count;
      const r = await fetch("/api/blobs/" + f.sha);
      if (!r.ok) throw new Error(f.path + ": HTTP " + r.status);
      data = await r.blob();
      crc = crc32(new Uint8Array(await data.arrayBuffer()));
    }
    const [time, date] = dos(f.mtime);
    const loc = new DataView(new ArrayBuffer(30));
    loc.setUint32(0, 0x04034b50, true);
    loc.setUint16(4, 10, true);
    loc.setUint16(6, 0x800, true);
    loc.setUint16(10, time, true);
    loc.setUint16(12, date, true);
    loc.setUint32(14, crc, true);
    loc.setUint32(18, data.size, true);
    loc.setUint32(22, data.size, true);
    loc.setUint16(26, name.length, true);
    const cen = new DataView(new ArrayBuffer(46));
    cen.setUint32(0, 0x02014b50, true);
    cen.setUint16(4, 20, true);
    cen.setUint16(6, 10, true);
    cen.setUint16(8, 0x800, true);
    cen.setUint16(12, time, true);
    cen.setUint16(14, date, true);
    cen.setUint32(16, crc, true);
    cen.setUint32(20, data.size, true);
    cen.setUint32(24, data.size, true);
    cen.setUint16(28, name.length, true);
    cen.setUint32(38, dir ? 0x10 : 0, true);
    cen.setUint32(42, offset, true);
    parts.push(loc, name, data);
    central.push(cen, name);
    offset += 30 + name.length + data.size;
  }
  const size = central.reduce((s, p) => s + p.byteLength, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, rows.length, true);
  end.setUint16(10, rows.length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  const url = URL.createObjectURL(new Blob([...parts, ...central, end], { type: "application/zip" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = (folder ? folder.slice(base.length, -1) : "library") + ".zip";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
document.addEventListener("click", async (ev) => {
  const btn = ev.target.closest("button[data-folder]");
  if (!btn || btn.disabled) return;
  const label = btn.textContent;
  btn.disabled = true;
  try {
    await download(btn);
  } catch (e) {
    alert("Download failed: " + e.message);
  } finally {
    btn.textContent = label;
    btn.disabled = false;
  }
});
`;

export async function adminPost(req: Request, env: Env, user: User, action: string): Promise<Response> {
  const form = await req.formData();
  const kind = String(form.get("kind") ?? "");
  if (kind !== "character" && kind !== "alliance") return adminPage(env, user, "Pick character or alliance.");
  if (action === "remove") {
    const id = parseInt(String(form.get("id") ?? ""), 10);
    // Membership is looked up on every request: they are viewers from their next one.
    await env.DB.prepare("DELETE FROM whitelist WHERE kind = ? AND id = ?").bind(kind, id).run();
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
