-- Daily usage counts: who loaded the site (match = '') and which library matches they opened.
-- One row per character, day and match, so heavy use costs a counter bump, not a new row.
-- Rows older than 90 days are pruned daily (activity.ts, the scheduled handler).
CREATE TABLE activity (
    day TEXT NOT NULL,
    char_id INTEGER NOT NULL,
    char_name TEXT NOT NULL,
    match TEXT NOT NULL,
    n INTEGER NOT NULL,
    PRIMARY KEY (day, char_id, match)
) WITHOUT ROWID;
