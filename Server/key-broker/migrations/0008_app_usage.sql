-- Cumulative, install-local counters. A retry replaces an older snapshot.
CREATE TABLE app_usage_days (
  day INTEGER NOT NULL,
  install_hash TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('ios', 'macos', 'android')),
  opens INTEGER NOT NULL,
  closes INTEGER NOT NULL,
  seconds INTEGER NOT NULL,
  PRIMARY KEY (day, platform, install_hash)
) WITHOUT ROWID;
