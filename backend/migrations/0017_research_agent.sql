CREATE TABLE IF NOT EXISTS research_answers (
  question_id TEXT PRIMARY KEY,
  answered_at TEXT NOT NULL,
  question TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('confirmed', 'contradicted', 'unresolved')),
  answer TEXT NOT NULL,
  market_effect TEXT NOT NULL CHECK (market_effect IN ('lower', 'higher', 'none', 'unclear')),
  channel TEXT,
  confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  sources_json TEXT NOT NULL,
  model TEXT NOT NULL,
  tool_calls INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS research_answers_recent ON research_answers(answered_at DESC);

CREATE TABLE IF NOT EXISTS agent_predictions (
  id TEXT PRIMARY KEY,
  symbol TEXT NOT NULL,
  session_date TEXT NOT NULL,
  capture_window TEXT NOT NULL CHECK (capture_window IN ('premarket', 'late')),
  horizon TEXT NOT NULL CHECK (horizon IN ('to_open', 'to_close', 'next_close')),
  made_at TEXT NOT NULL,
  target_session TEXT NOT NULL,
  target_end_at TEXT NOT NULL,
  baseline_price REAL NOT NULL CHECK (baseline_price > 0),
  baseline_at TEXT NOT NULL,
  baseline_source TEXT NOT NULL,
  probability_up REAL NOT NULL CHECK (probability_up >= 0 AND probability_up <= 1),
  direction INTEGER NOT NULL CHECK (direction IN (-1, 0, 1)),
  expected_move_pct REAL NOT NULL,
  rationale TEXT NOT NULL,
  drivers_json TEXT NOT NULL,
  sources_json TEXT NOT NULL,
  model TEXT NOT NULL,
  tool_calls INTEGER NOT NULL DEFAULT 0,
  UNIQUE(symbol, session_date, capture_window, horizon)
);
CREATE INDEX IF NOT EXISTS agent_predictions_recent ON agent_predictions(symbol, made_at DESC);
CREATE INDEX IF NOT EXISTS agent_predictions_due ON agent_predictions(target_end_at);

CREATE TABLE IF NOT EXISTS agent_prediction_outcomes (
  prediction_id TEXT PRIMARY KEY REFERENCES agent_predictions(id),
  endpoint_price REAL NOT NULL CHECK (endpoint_price > 0),
  endpoint_at TEXT NOT NULL,
  return_pct REAL NOT NULL,
  direction INTEGER NOT NULL CHECK (direction IN (-1, 0, 1)),
  source TEXT NOT NULL,
  source_retrieved_at TEXT NOT NULL,
  ingested_at TEXT NOT NULL
);
