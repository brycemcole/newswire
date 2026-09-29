CREATE TABLE stories (
  id TEXT PRIMARY KEY NOT NULL,
  external_id TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  body TEXT NOT NULL,
  source TEXT NOT NULL,
  url TEXT NOT NULL UNIQUE,
  published_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  category TEXT NOT NULL,
  priority TEXT NOT NULL,
  tickers TEXT NOT NULL CHECK (json_valid(tickers)),
  tags TEXT NOT NULL CHECK (json_valid(tags)),
  agent TEXT NOT NULL
);
CREATE INDEX stories_order ON stories(published_at DESC, id DESC);
CREATE INDEX stories_category_order ON stories(category, published_at DESC, id DESC);
CREATE INDEX stories_priority_order ON stories(priority, published_at DESC, id DESC);
