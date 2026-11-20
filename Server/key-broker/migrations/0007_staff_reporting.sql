-- One production store observation per subscription. Store references are hashed
-- before storage. Store purchases are independent of Lively accounts.
CREATE TABLE subscription_observations (
  subscription_key TEXT PRIMARY KEY,
  lookup_hash TEXT,
  store TEXT NOT NULL CHECK (store IN ('apple', 'play')),
  product TEXT,
  event TEXT NOT NULL,
  observed_ms INTEGER NOT NULL,
  period_end_ms INTEGER
);
CREATE INDEX subscription_lookup ON subscription_observations (lookup_hash);
CREATE INDEX subscription_recent ON subscription_observations (observed_ms DESC, subscription_key);
CREATE INDEX users_created ON users (created_at);

-- Older verified first payments already have a production-only subscription
-- hash. These records have no product or expiry, and do not imply active Pro.
INSERT INTO subscription_observations
  (subscription_key, lookup_hash, store, event, observed_ms)
SELECT subscription_hash, subscription_hash, 'apple', 'First payment', first_paid_at * 1000
FROM apple_ads_subscriptions WHERE first_paid_at IS NOT NULL;
