CREATE TABLE market_data_cache (
  provider TEXT NOT NULL,
  resource TEXT NOT NULL,
  body TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (provider, resource)
);
CREATE TABLE market_data_usage (
  provider TEXT PRIMARY KEY,
  day TEXT NOT NULL,
  minute INTEGER NOT NULL,
  minute_used INTEGER NOT NULL,
  day_used INTEGER NOT NULL
);
