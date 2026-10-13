CREATE TABLE IF NOT EXISTS research_discovery_runs (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  started_at TEXT,
  finished_at TEXT,
  recorded_at TEXT NOT NULL,
  health TEXT NOT NULL CHECK (health IN ('healthy', 'degraded', 'unhealthy', 'unknown')),
  status TEXT NOT NULL,
  processed INTEGER NOT NULL DEFAULT 0,
  findings INTEGER NOT NULL DEFAULT 0,
  unique_findings INTEGER NOT NULL DEFAULT 0,
  questions_attempted INTEGER NOT NULL DEFAULT 0,
  queued INTEGER NOT NULL DEFAULT 0,
  parent_question_ids_json TEXT NOT NULL DEFAULT '[]',
  failures_json TEXT NOT NULL DEFAULT '[]',
  report_hash TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS research_discovery_attempts (
  question_id TEXT NOT NULL,
  attempted_at TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('searched', 'failed', 'robots-blocked', 'queued', 'unknown')),
  attempts INTEGER NOT NULL DEFAULT 0,
  search_role TEXT,
  PRIMARY KEY (question_id, attempted_at)
);
CREATE INDEX IF NOT EXISTS research_discovery_attempts_recent ON research_discovery_attempts(question_id, attempted_at DESC);

CREATE TABLE IF NOT EXISTS research_discovery_findings (
  id TEXT PRIMARY KEY,
  original_url TEXT NOT NULL,
  title TEXT NOT NULL,
  body_hash TEXT,
  first_discovered_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS research_discovery_findings_recent ON research_discovery_findings(last_seen_at DESC);

CREATE TABLE IF NOT EXISTS research_discovery_finding_questions (
  finding_id TEXT NOT NULL,
  question_id TEXT NOT NULL,
  provenance TEXT,
  PRIMARY KEY (finding_id, question_id)
);
CREATE INDEX IF NOT EXISTS research_discovery_finding_questions_question ON research_discovery_finding_questions(question_id);
