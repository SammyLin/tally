-- Kiroku Cloud, Phase 1: users + per-user ownership on every table (runners stay global).
-- Self-host keeps working as user 1 (clerk_id NULL); cloud users start at 2, so a row inserted without user_id
-- (defaults to 1) is orphaned rather than shown to another cloud user.
-- user_id carries no REFERENCES: SQLite refuses ALTER TABLE ADD COLUMN with REFERENCES and a non-NULL default while
-- foreign keys are on (always, in D1). Ownership is enforced by the queries (`AND user_id=?`), not by FK.
-- org_id is reserved (NULL) for team plans.
CREATE TABLE users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  clerk_id TEXT UNIQUE,                         -- Clerk user id (sub); NULL = the self-host user
  email TEXT,                                   -- filled from Clerk's Backend API on first sign-in
  plan TEXT NOT NULL DEFAULT 'free',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
INSERT INTO users(id, clerk_id) VALUES(1, NULL);

ALTER TABLE recordings ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE recordings ADD COLUMN org_id INTEGER;
ALTER TABLE folders ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE folders ADD COLUMN org_id INTEGER;
ALTER TABLE speakers ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE speakers ADD COLUMN org_id INTEGER;
ALTER TABLE segments ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE segments ADD COLUMN org_id INTEGER;
ALTER TABLE voiceprints ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE voiceprints ADD COLUMN org_id INTEGER;
ALTER TABLE summaries ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE summaries ADD COLUMN org_id INTEGER;
ALTER TABLE asks ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE asks ADD COLUMN org_id INTEGER;
-- endpoint stays the key: a shared browser's subscription follows whoever subscribed last
ALTER TABLE push_subscriptions ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE push_subscriptions ADD COLUMN org_id INTEGER;
ALTER TABLE vocab_scans ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1;
ALTER TABLE vocab_scans ADD COLUMN org_id INTEGER;

-- people: name unique per user (rebuild). DROP TABLE people runs an implicit DELETE that fires the FK actions
-- (voiceprints cascade-deleted, speakers.person_id / suggest_person_id nulled), so stash those and restore them after.
CREATE TABLE _stash_voiceprints AS SELECT * FROM voiceprints;
CREATE TABLE _stash_speaker_people AS SELECT id, person_id, suggest_person_id FROM speakers
  WHERE person_id IS NOT NULL OR suggest_person_id IS NOT NULL;
CREATE TABLE people_new(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  last_used_at TEXT NOT NULL DEFAULT (datetime('now')),
  user_id INTEGER NOT NULL DEFAULT 1,
  org_id INTEGER,
  UNIQUE(user_id, name)
);
INSERT INTO people_new(id, name, last_used_at) SELECT id, name, last_used_at FROM people;
DROP TABLE people;
ALTER TABLE people_new RENAME TO people;
INSERT INTO voiceprints SELECT * FROM _stash_voiceprints WHERE id NOT IN (SELECT id FROM voiceprints);
UPDATE speakers SET person_id=s.person_id, suggest_person_id=s.suggest_person_id FROM _stash_speaker_people s WHERE speakers.id=s.id;
DROP TABLE _stash_voiceprints;
DROP TABLE _stash_speaker_people;

-- settings: one row per (user, key) (rebuild; nothing references it)
CREATE TABLE settings_new(user_id INTEGER NOT NULL DEFAULT 1, key TEXT NOT NULL, value TEXT NOT NULL, org_id INTEGER, PRIMARY KEY(user_id, key));
INSERT INTO settings_new(key, value) SELECT key, value FROM settings;
DROP TABLE settings;
ALTER TABLE settings_new RENAME TO settings;

-- vocab_suggestions: one row per (user, term) (rebuild; nothing references it)
CREATE TABLE vocab_suggestions_new(
  user_id INTEGER NOT NULL DEFAULT 1,
  term TEXT NOT NULL,
  misheard TEXT NOT NULL DEFAULT '[]',
  kind TEXT,
  hits INTEGER NOT NULL DEFAULT 0,
  fixes INTEGER NOT NULL DEFAULT 0,
  recordings INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'new',
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  org_id INTEGER,
  PRIMARY KEY(user_id, term)
);
INSERT INTO vocab_suggestions_new(term, misheard, kind, hits, fixes, recordings, status, updated_at)
  SELECT term, misheard, kind, hits, fixes, recordings, status, updated_at FROM vocab_suggestions;
DROP TABLE vocab_suggestions;
ALTER TABLE vocab_suggestions_new RENAME TO vocab_suggestions;

-- per-user uniqueness and list lookups (claims stay global: rec_status, sum_status are kept)
DROP INDEX folders_name;
CREATE UNIQUE INDEX folders_name ON folders(user_id, coalesce(parent_id, 0), name);
DROP INDEX rec_created;
CREATE INDEX rec_user_created ON recordings(user_id, created_at);
DROP INDEX rec_folder;
CREATE INDEX rec_folder ON recordings(user_id, folder_id);
DROP INDEX rec_filename;
CREATE INDEX rec_filename ON recordings(user_id, filename);
CREATE INDEX rec_user_status ON recordings(user_id, status);
CREATE INDEX asks_user ON asks(user_id, id);
CREATE INDEX sum_user ON summaries(user_id, recording_id);
CREATE INDEX vocab_sug_status ON vocab_suggestions(user_id, status);
CREATE INDEX vocab_scans_user ON vocab_scans(user_id, status);
CREATE INDEX vp_user ON voiceprints(user_id, emb_model);
CREATE INDEX spk_user ON speakers(user_id, recording_id);
