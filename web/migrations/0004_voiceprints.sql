-- Voiceprints: per-speaker embedding (JSON float array, L2-normalized), the person it was matched/named to,
-- and auto=1 while that label came from a voiceprint match the user has not confirmed.
ALTER TABLE speakers ADD COLUMN embedding TEXT;
ALTER TABLE speakers ADD COLUMN person_id INTEGER REFERENCES people(id) ON DELETE SET NULL;
ALTER TABLE speakers ADD COLUMN auto INTEGER NOT NULL DEFAULT 0;

-- One enrolled (user-named) speaker = one voiceprint of that person.
CREATE TABLE voiceprints(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  speaker_id INTEGER NOT NULL UNIQUE REFERENCES speakers(id) ON DELETE CASCADE,
  embedding TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX vp_person ON voiceprints(person_id);
