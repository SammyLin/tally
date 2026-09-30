CREATE TABLE folders(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
-- one name per parent, top level included (plain UNIQUE(parent_id, name) lets NULL parents repeat)
CREATE UNIQUE INDEX folders_name ON folders(coalesce(parent_id, 0), name);

CREATE TABLE recordings(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  filename TEXT NOT NULL,          -- original filename
  duration_s REAL,
  status TEXT NOT NULL DEFAULT 'queued',  -- uploading|queued|converting|transcribing|cleaning|done|error
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  deleted_at TEXT,
  folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL,
  source_key TEXT,                 -- R2 key of the original; NULL once processed
  play_key TEXT,                   -- R2 key of play.m4a
  size INTEGER,                    -- original size in bytes
  upload_id TEXT,                  -- R2 multipart upload in progress
  runner TEXT,
  lease_until TEXT
);
CREATE INDEX rec_created ON recordings(created_at);
CREATE INDEX rec_folder ON recordings(folder_id);
CREATE INDEX rec_status ON recordings(status);
CREATE INDEX rec_filename ON recordings(filename);

CREATE TABLE speakers(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
  label TEXT NOT NULL,             -- SPEAKER_00 ..., or 'custom'
  display_name TEXT NOT NULL       -- default 'Speaker 1', 'Speaker 2' ...
);
CREATE INDEX spk_rec ON speakers(recording_id);

CREATE TABLE people(
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- REPLACE gives a re-used name a fresh id: id order = recency
  name TEXT NOT NULL UNIQUE,
  last_used_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE segments(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  speaker_id INTEGER REFERENCES speakers(id),
  text_raw TEXT NOT NULL,
  text_clean TEXT                  -- NULL until cleanup; UI falls back to text_raw
);
CREATE INDEX seg_rec ON segments(recording_id, start_ms);
CREATE INDEX seg_spk ON segments(speaker_id);

CREATE TABLE summaries(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
  template_id TEXT NOT NULL,
  language TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',  -- queued|running|done|error
  content_md TEXT,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  runner TEXT,
  lease_until TEXT
);
CREATE INDEX sum_rec ON summaries(recording_id);
CREATE INDEX sum_status ON summaries(status);
