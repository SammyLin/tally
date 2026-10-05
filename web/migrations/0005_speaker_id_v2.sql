-- Speaker ID v2: embeddings carry their model id (only VOICE_MODEL ones are matched), and an open speaker
-- whose best voiceprint is close but not sure enough gets a suggestion for the user to confirm or dismiss.
ALTER TABLE speakers ADD COLUMN emb_model TEXT;
UPDATE speakers SET emb_model='campplus-zh-cn' WHERE embedding IS NOT NULL;
ALTER TABLE speakers ADD COLUMN suggest_person_id INTEGER REFERENCES people(id) ON DELETE SET NULL;
ALTER TABLE speakers ADD COLUMN suggest_score REAL;
ALTER TABLE voiceprints ADD COLUMN emb_model TEXT NOT NULL DEFAULT 'campplus-zh-cn';
