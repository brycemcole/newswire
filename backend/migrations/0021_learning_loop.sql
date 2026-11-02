CREATE TABLE IF NOT EXISTS forecast_param_sets (
  id TEXT PRIMARY KEY,
  symbol TEXT NOT NULL CHECK (symbol IN ('SPY', 'QQQ')),
  horizon TEXT NOT NULL CHECK (horizon IN ('opening_gap', 'cutoff_to_open', 'open_to_close')),
  status TEXT NOT NULL CHECK (status IN ('shadow', 'promoted', 'rejected', 'retired')),
  params_json TEXT NOT NULL,
  evaluation_json TEXT NOT NULL,
  train_through TEXT NOT NULL,
  created_at TEXT NOT NULL,
  promoted_at TEXT
);
CREATE INDEX IF NOT EXISTS forecast_param_sets_active ON forecast_param_sets(symbol, horizon, status, created_at DESC);

CREATE TABLE IF NOT EXISTS forecast_param_predictions (
  forecast_id TEXT NOT NULL REFERENCES forecasts(id),
  param_set_id TEXT NOT NULL REFERENCES forecast_param_sets(id),
  score REAL,
  tilt TEXT NOT NULL CHECK (tilt IN ('up', 'down', 'neutral', 'unavailable')),
  predicted_at TEXT NOT NULL,
  PRIMARY KEY (forecast_id, param_set_id)
);

CREATE TABLE IF NOT EXISTS learning_reports (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  symbol TEXT NOT NULL,
  horizon TEXT NOT NULL,
  window_end TEXT NOT NULL,
  report_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS learning_reports_recent ON learning_reports(kind, symbol, horizon, created_at DESC)
;
