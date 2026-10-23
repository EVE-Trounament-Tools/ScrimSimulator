# Scrim Simulator website

The simulator's Godot web build, hosted on Cloudflare's free tier: one Worker, a D1 database
and an R2 bucket.

- **Login** goes through EVE SSO and needs no scopes. Any character can log in. Whitelisted
  characters, members of whitelisted alliances and admins are *members*. Everyone else is a
  *viewer*. Membership is looked up on every request, and affiliation is re-checked daily.
- **Shared match library.** Everything members upload (match CSVs, audio, gamelogs, team edits)
  is kept on the site and visible to every member. Only members can upload or change anything.
  Only a match's uploader or an admin can rename, move, replace or remove it.
- **Public matches.** Everything starts private. An admin can make a match or a folder public
  by right-clicking it in the match list. Public rows have a green background. Viewers see only
  public matches and read-only, with no edit buttons. Anything a viewer changes in the viewer
  (team swaps, names) stays in their browser. A public folder makes everything in it public,
  including matches uploaded or moved into it later. Matches and folders keep their flag when
  moved or renamed, except an empty folder, which starts private again. A season's team db is
  only shown to viewers when its folder is public. Otherwise their browser builds one from the
  public matches. Admins can download any folder, or the whole library, as a
  zip at `/admin`.
- **Basic usage tracking.** Each day's page loads and match opens are counted per character
  (one small row per character, day and match) and shown to admins at `/admin`. Counts older
  than 90 days are pruned daily.
- **Settings follow the character.** They are saved on the site, not in the browser.
- **Assets are prepared server-side.** The SDE and the ship models are downloaded and decoded
  once by a scheduled workflow. Browsers fetch only the hulls of the match they open, and cache
  them.
- **Auto-deploy.** Every `v*` tag on master publishes a new build. Each deploy also adds the
  checked-in demo match to the library as a public "Demo match" at the top level, unless it is
  already there (also when renamed or moved), so every visitor has something to watch
  (`scripts/seed_demo_web.sh`).

The desktop app is unaffected. The web build reuses its scripts, and the browser-only code
lives in `simulator/scripts/web/`. Each existing script reaches it only through a short
`if OS.has_feature("web"):` branch.

## How it fits together

```
browser ──> Worker (web/worker, one origin)
             /auth/*    EVE SSO login, logout
             /admin     whitelist, usage, folder downloads (admins: ADMIN_CHAR_IDS)
             /api/*     library manifest + commits, blobs, settings,     D1 + R2 blobs/<sha>
                        match visibility (admins)
             /assets/*  ship_sizes.json, icons.zip, gallery/…, types/…   R2 assets/
             /, /<f>    Godot web export of kv current_build             R2 builds/<tag>/
```

**Library.** The library is a manifest in D1 mapping each path to the sha256 of its contents.
Paths are laid out like the desktop `user://matches`. The contents are content-addressed R2
blobs, so renames and moves cost nothing.
- In the browser, `WebLibrary` (`simulator/scripts/web/web_library.gd`) mirrors the library
  into `user://matches`, which is IndexedDB. It does a three-way sync on startup, after every
  change and every 20 s, so `MatchLibrary` and the menu work unchanged.
- Files not needed yet are small placeholders. A match's CSV and audio download when it's
  opened.
- Commits carry each path's expected sha, so concurrent edits are detected, not lost.
- Folder downloads are zipped in the admin's browser from the manifest and blobs, since a
  free-tier Worker has too little CPU time to checksum large audio files. The zips are
  uncompressed and have no ZIP64, so each is capped at 4 GB.
- Blobs are never deleted, so a removed match can be restored by an admin re-committing its sha
  (see the `audit` table).

**Assets.** `simulator/tools/web_assets.gd` runs the desktop downloaders headless:
- The SDE becomes `ship_sizes.json`.
- Overview icons are repacked into a small `icons.zip`.
- Every hull is Draco-decoded with `glb-undraco`.
- The output mirrors the upstream layout, and the web build's `Http.fetch` rewrites upstream URLs
  to `/assets/…` (`WebBackend.rewrite_url`).

The full hull set is roughly 1.5–2 GB.

**Threads.** The web build uses Godot's threaded template. The Worker sends COOP/COEP headers
on everything, and the browser only ever talks to this one origin.

## One-time setup

1. **Cloudflare** (free account). In `web/worker/`:
   ```sh
   npm ci
   npx wrangler login
   npx wrangler d1 create scrim-simulator      # note the database_id
   npx wrangler r2 bucket create scrim-simulator
   ```
2. **EVE application.** Create one at <https://developers.eveonline.com/applications>.
   Choose "Authentication only" (no scopes) and set the callback URL to
   `https://<your worker host>/auth/callback`, for example
   `https://scrim-simulator.<you>.workers.dev/auth/callback` or your custom domain.
3. **Worker secrets.** Set these once:
   ```sh
   npx wrangler secret put EVE_CLIENT_ID
   npx wrangler secret put EVE_CLIENT_SECRET
   npx wrangler secret put ADMIN_CHAR_IDS     # your character ID(s), comma-separated
   ```
4. **GitHub repository settings.**
   - Secrets:
     - `CLOUDFLARE_API_TOKEN`: a token with *Workers Scripts: Edit*, *D1: Edit* and
       *Workers R2 Storage: Edit*.
     - `CLOUDFLARE_ACCOUNT_ID`
     - `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`: an R2 API token with Object Read & Write on
       the bucket, used by `rclone`.
   - Variable: `D1_DATABASE_ID`, the id from step 1. It is substituted into `wrangler.toml` at
     deploy time.
5. **Fill the asset mirror.** Run the **assets-sync** workflow once by hand (Actions →
   assets-sync → Run workflow). The first run downloads the whole SDE and every hull, so it
   takes a while. After that it runs weekly and only fetches changes.
6. **Deploy.** Push a version tag on master (`git tag v1.1.0 && git push origin v1.1.0`), or run
   **deploy-web** by hand.
7. **Whitelist.** Log in as an admin character and add characters and alliances at `/admin`.
   The whitelist decides who sees private matches and may upload. Anyone else who logs in sees
   only the public ones.

## Local development

```sh
cd web/worker
cat > .dev.vars <<'EOF'
EVE_CLIENT_ID=dev
EVE_CLIENT_SECRET=dev
ADMIN_CHAR_IDS=9000
DEV_LOGIN_CHAR=9000:Dev Pilot
EOF
npx wrangler d1 migrations apply DB --local
../../scripts/seed_demo_web.sh --local
npx wrangler d1 execute DB --local --command \
  "INSERT INTO kv (key, value) VALUES ('current_build', 'dev')"
../../scripts/build.sh web
for f in ../../dist/web/*; do
  npx wrangler r2 object put "scrim-simulator/builds/dev/$(basename "$f")" --local --file "$f"
done
# Optional: a small asset mirror (the named hulls only), uploaded under assets/ the same way.
godot --headless --path ../../simulator -s tools/web_assets.gd -- /tmp/mirror --ships Venture,Procurer
npx wrangler dev
```

Then open <http://localhost:8787/auth/dev>. It logs you in as `DEV_LOGIN_CHAR` without EVE SSO.
This only works on localhost and only when that variable is set; never set it in production.

Tests:
- `npm test` runs the Worker tests (local D1/R2, with EVE SSO and ESI faked).
- `scripts/test.sh web` runs the web build's GDScript helpers.

## Limits and costs

All of this fits Cloudflare's free tier:
- Workers: 100k requests/day.
- D1: 5 GB and 5M reads/day.
- R2: 10 GB stored, 1M writes and 10M reads a month, and no egress fees.

Free Workers accept request bodies up to 100 MB, so a single upload (usually an audio file) is
capped there (`MAX_UPLOAD_BYTES`). Watch R2 storage if a lot of audio piles up.

Usage tracking costs one D1 write per page load or match open, well inside the free tier's
100k writes a day.

Since any EVE character can log in, viewers also load the build and the ship models of the
public matches they open. Their requests count against the same daily limits.
