ALTER TABLE posts ADD COLUMN title TEXT;
ALTER TABLE posts ADD COLUMN summary TEXT;
ALTER TABLE posts ADD COLUMN body TEXT;
ALTER TABLE posts ADD COLUMN source TEXT;
ALTER TABLE posts ADD COLUMN image_url TEXT;
CREATE INDEX IF NOT EXISTS posts_created_id ON posts (created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS posts_source_url ON posts (source_url);
CREATE INDEX IF NOT EXISTS interactions_post ON interactions (post_id);
