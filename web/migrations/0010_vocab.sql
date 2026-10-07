-- Vocabulary suggestions (詞彙建議): a runner scans recordings for terms worth adding to settings.vocab; the user accepts or dismisses each.
CREATE TABLE vocab_scans(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_id INTEGER NOT NULL,                     -- recording id range covered, inclusive
  to_id INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',        -- queued|running|done|error
  error TEXT,
  runner TEXT,
  lease_until TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE vocab_suggestions(
  term TEXT PRIMARY KEY,
  misheard TEXT NOT NULL DEFAULT '[]',          -- JSON array of raw (pre-cleanup) variants
  kind TEXT,                                    -- product|company|person|term|other
  hits INTEGER NOT NULL DEFAULT 0,              -- segments whose cleaned text contains term, all recordings
  fixes INTEGER NOT NULL DEFAULT 0,             -- segments whose raw text has a misheard variant and cleaned text has term
  recordings INTEGER NOT NULL DEFAULT 0,        -- distinct recordings among the hits
  status TEXT NOT NULL DEFAULT 'new',           -- new|added|dismissed
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
