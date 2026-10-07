-- Ask (問問看): cross-recording Q&A answered by a runner's local LLM, with [[recording_id@mm:ss]] citations.
CREATE TABLE asks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  question TEXT NOT NULL,
  answer_md TEXT,
  sources TEXT,                                 -- JSON array of recording ids used
  status TEXT NOT NULL DEFAULT 'queued',        -- queued|running|done|error
  error TEXT,
  runner TEXT,
  lease_until TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
