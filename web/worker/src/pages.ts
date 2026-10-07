// Pages shown outside the simulator: the login page and login errors.

import { escapeHtml, html } from "./util";

function page(title: string, body: string, status = 200): Response {
  return html(
    `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${escapeHtml(title)}</title><style>
body{font:16px system-ui,sans-serif;background:#0f1117;color:#dde;margin:0;min-height:100vh;display:grid;place-items:center}
main{max-width:440px;padding:24px;text-align:center}h1{font-weight:500}a{color:#8fc3ff}
.btn{display:inline-block;margin-top:12px;padding:10px 18px;background:#1f3a5c;color:#fff;border-radius:6px;text-decoration:none}
</style></head><body><main>${body}</main></body></html>`,
    status,
  );
}

export function loginPage(devLogin: boolean): Response {
  return page(
    "Scrim Simulator",
    `<h1>Scrim Simulator</h1><p>Replay viewer for EVE Online scrims. Access is limited to whitelisted
characters and alliances.</p><a class="btn" href="/auth/login">Log in with EVE Online</a>
${devLogin ? '<p><a href="/auth/dev">Development login</a></p>' : ""}`,
  );
}

export function errorPage(message: string, status: number): Response {
  return page(
    "Scrim Simulator",
    `<h1>Can't log in</h1><p>${escapeHtml(message)}</p><p><a href="/auth/logout">Try another character</a></p>`,
    status,
  );
}

export function noBuildPage(): Response {
  return page(
    "Scrim Simulator",
    "<h1>Not deployed yet</h1><p>No simulator build has been published. Push a version tag to deploy one.</p>",
    503,
  );
}
