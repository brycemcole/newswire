CREATE TABLE feedback (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  note TEXT NOT NULL,
  context TEXT NOT NULL DEFAULT '{}',
  device TEXT,
  image_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'new',
  result TEXT,
  pr_url TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX feedback_status ON feedback (status, created_at);
CREATE TABLE feedback_images (
  feedback_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  data TEXT NOT NULL,
  PRIMARY KEY (feedback_id, position)
);
