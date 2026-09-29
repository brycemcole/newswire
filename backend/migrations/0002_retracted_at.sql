ALTER TABLE stories ADD COLUMN retracted_at TEXT;
CREATE INDEX stories_live_order ON stories(published_at DESC, id DESC) WHERE retracted_at IS NULL;
