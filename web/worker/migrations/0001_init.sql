-- Small key/value settings of the site itself: current_build (the build tag served at /),
-- library_version (bumped by every library commit).
CREATE TABLE kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Who may log in: a character, or every member of an alliance.
CREATE TABLE whitelist (
    kind TEXT NOT NULL CHECK (kind IN ('character', 'alliance')),
    id INTEGER NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    added_by INTEGER,
    added_at INTEGER NOT NULL,
    PRIMARY KEY (kind, id)
);

-- Logged-in browsers. id_hash is the SHA-256 of the session cookie, so a database leak can't be
-- replayed. Affiliation is re-checked against the whitelist when checked_at gets old.
CREATE TABLE sessions (
    id_hash TEXT PRIMARY KEY,
    char_id INTEGER NOT NULL,
    char_name TEXT NOT NULL,
    alliance_id INTEGER,
    created_at INTEGER NOT NULL,
    checked_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_char ON sessions (char_id);

-- The shared match library: one row per file (path relative to the library, as in the desktop
-- app's user://matches) or folder (path ending in "/", sha ''). File contents are R2 objects
-- blobs/<sha>.
CREATE TABLE files (
    path TEXT PRIMARY KEY,
    sha TEXT NOT NULL,
    size INTEGER NOT NULL,
    owner_id INTEGER NOT NULL,
    owner_name TEXT NOT NULL,
    mtime INTEGER NOT NULL
);

-- Each character's simulator settings (the desktop app's settings.cfg, as text).
CREATE TABLE settings (
    char_id INTEGER PRIMARY KEY,
    body TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Who changed what in the library or the whitelist.
CREATE TABLE audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL,
    char_id INTEGER NOT NULL,
    char_name TEXT NOT NULL,
    action TEXT NOT NULL,
    detail TEXT NOT NULL
);
