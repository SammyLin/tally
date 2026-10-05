-- Settings: one row per key, value = JSON (a missing row = the default in src/settings.ts).
CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- Per-recording transcription language; NULL = settings.stt_lang.
ALTER TABLE recordings ADD COLUMN language TEXT;
