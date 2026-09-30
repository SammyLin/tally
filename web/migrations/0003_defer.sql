-- A recording put back in the queue by a runner (e.g. Groq quota) is not claimable before not_before; note says why.
ALTER TABLE recordings ADD COLUMN not_before TEXT;
ALTER TABLE recordings ADD COLUMN note TEXT;
