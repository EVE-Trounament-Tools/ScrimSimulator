-- Public matches and folders: viewable by every logged-in character, not just whitelisted ones.
-- Set on a match's CSV row or on a folder row (which makes everything under it public); only
-- admins change it (library.ts setVisibility). Existing and newly uploaded files are private.
ALTER TABLE files ADD COLUMN public INTEGER NOT NULL DEFAULT 0;
