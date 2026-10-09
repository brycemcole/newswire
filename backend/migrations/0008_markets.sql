ALTER TABLE devices ADD COLUMN muted_topics TEXT NOT NULL DEFAULT '[]';
CREATE TABLE econ_events (
  id TEXT PRIMARY KEY NOT NULL,
  country TEXT NOT NULL,
  title TEXT NOT NULL,
  at TEXT NOT NULL,
  impact TEXT NOT NULL,
  forecast TEXT NOT NULL,
  previous TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX econ_events_at ON econ_events(at);
CREATE TABLE ship_positions (
  area TEXT NOT NULL,
  mmsi TEXT NOT NULL,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  speed REAL NOT NULL,
  course REAL NOT NULL,
  at TEXT NOT NULL,
  PRIMARY KEY (area, mmsi)
);
