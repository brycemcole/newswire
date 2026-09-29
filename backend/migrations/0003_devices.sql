CREATE TABLE devices (
  token TEXT PRIMARY KEY NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
