-- Rate-limit counters. `key` names the subject and window, for example
-- `install:<hash>:day:2026-10-20`. Rows past `expires_at` are deleted by the
-- scheduled cleanup.
CREATE TABLE counters (
  key TEXT PRIMARY KEY,
  value INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX counters_expires_at ON counters (expires_at);

-- Installs that may not get keys, by hashed install ID (the same value Soniox
-- sees as `client_reference_id`). Takes effect immediately, no redeploy.
CREATE TABLE denylist (
  install_hash TEXT PRIMARY KEY,
  reason TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
