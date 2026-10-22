-- Accounts with Pro for free, without a subscription. Every account that
-- existed before Pro is grandfathered in; grant more with
--   UPDATE users SET free_pro = 1 WHERE email = '<email>'
ALTER TABLE users ADD COLUMN free_pro INTEGER NOT NULL DEFAULT 0;
UPDATE users SET free_pro = 1;

-- Subscriptions the App Store refunded or revoked, by original transaction ID,
-- from App Store Server Notifications. The app may still hold a signed
-- transaction for them that hasn't expired.
CREATE TABLE revoked_subscriptions (
  original_transaction_id TEXT PRIMARY KEY,
  reason TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
