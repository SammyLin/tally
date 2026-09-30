-- Last contact per runner (updated on claim and on every lease-holding call); powers the UI's runner status.
CREATE TABLE runners(
  name TEXT PRIMARY KEY,
  last_seen TEXT NOT NULL DEFAULT (datetime('now')),
  stt TEXT
);
