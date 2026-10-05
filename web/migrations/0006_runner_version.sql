-- Build each runner reports on claim: git commit (short, "+dirty" if built from a modified tree) and commit time.
ALTER TABLE runners ADD COLUMN version TEXT;
ALTER TABLE runners ADD COLUMN version_time TEXT;
