CREATE TABLE IF NOT EXISTS pulse_impacts (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  source TEXT NOT NULL,
  url TEXT NOT NULL,
  published_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  direction INTEGER NOT NULL,
  channel TEXT NOT NULL,
  size TEXT NOT NULL,
  confidence REAL NOT NULL,
  classified_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS pulse_impacts_received ON pulse_impacts (received_at);
