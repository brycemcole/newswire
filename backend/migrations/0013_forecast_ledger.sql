CREATE TABLE IF NOT EXISTS forecasts (
  id TEXT PRIMARY KEY,
  symbol TEXT NOT NULL CHECK (symbol IN ('SPY', 'QQQ')),
  session_date TEXT NOT NULL,
  horizon TEXT NOT NULL CHECK (horizon IN ('opening_gap', 'cutoff_to_open', 'open_to_close')),
  forecast_at TEXT NOT NULL,
  target_start_at TEXT NOT NULL,
  target_end_at TEXT NOT NULL,
  model_version TEXT NOT NULL,
  input_version TEXT NOT NULL,
  score REAL,
  baseline_price REAL,
  baseline_at TEXT,
  price_only_direction INTEGER CHECK (price_only_direction IN (-1, 0, 1)),
  tilt TEXT NOT NULL CHECK (tilt IN ('up', 'down', 'neutral', 'unavailable')),
  probabilities_json TEXT,
  features_json TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(symbol, session_date, horizon)
);
CREATE INDEX IF NOT EXISTS forecasts_recent ON forecasts(symbol, forecast_at DESC);
CREATE INDEX IF NOT EXISTS forecasts_due ON forecasts(target_end_at, symbol);

CREATE TABLE IF NOT EXISTS forecast_outcomes (
  forecast_id TEXT PRIMARY KEY REFERENCES forecasts(id),
  baseline_price REAL NOT NULL CHECK (baseline_price > 0),
  baseline_at TEXT NOT NULL,
  endpoint_price REAL NOT NULL CHECK (endpoint_price > 0),
  endpoint_at TEXT NOT NULL,
  return_pct REAL NOT NULL,
  direction INTEGER NOT NULL CHECK (direction IN (-1, 0, 1)),
  source TEXT NOT NULL,
  source_retrieved_at TEXT NOT NULL,
  ingested_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS research_questions (
  id TEXT PRIMARY KEY,
  query TEXT NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('open', 'queued', 'answered', 'dismissed')) DEFAULT 'open',
  created_at TEXT NOT NULL,
  event_id TEXT
);
CREATE INDEX IF NOT EXISTS research_questions_status ON research_questions(status, created_at DESC);

CREATE TABLE IF NOT EXISTS forecast_models (
  id TEXT PRIMARY KEY,
  symbol TEXT NOT NULL CHECK (symbol IN ('SPY', 'QQQ')),
  horizon TEXT NOT NULL CHECK (horizon IN ('opening_gap', 'cutoff_to_open', 'open_to_close')),
  model_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('shadow', 'promoted', 'rejected')),
  coefficients_json TEXT NOT NULL,
  evaluation_json TEXT NOT NULL,
  train_through TEXT NOT NULL,
  created_at TEXT NOT NULL,
  promoted_at TEXT
);
CREATE INDEX IF NOT EXISTS forecast_models_active ON forecast_models(symbol, horizon, status, created_at DESC);

CREATE TABLE IF NOT EXISTS forecast_candidate_predictions (
  forecast_id TEXT NOT NULL REFERENCES forecasts(id),
  candidate_id TEXT NOT NULL REFERENCES forecast_models(id),
  probability_up REAL NOT NULL CHECK (probability_up >= 0 AND probability_up <= 1),
  price_only_probability_up REAL NOT NULL CHECK (price_only_probability_up >= 0 AND price_only_probability_up <= 1),
  predicted_at TEXT NOT NULL,
  outcome INTEGER CHECK (outcome IN (0, 1)),
  PRIMARY KEY (forecast_id, candidate_id)
);
