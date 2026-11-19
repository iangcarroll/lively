-- The join key is a hash of the random UUID passed to StoreKit at checkout.
CREATE TABLE apple_ads_installs (
  install_hash TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  campaign_id INTEGER NOT NULL,
  ad_group_id INTEGER NOT NULL,
  keyword_id INTEGER,
  claim_type TEXT,
  conversion_type TEXT,
  received_at INTEGER NOT NULL
);

-- Apple can deliver the first charge before the original purchase notification
-- (or before the phone comes back online to deliver its attribution).
CREATE TABLE apple_ads_subscriptions (
  subscription_hash TEXT PRIMARY KEY,
  original_install_hash TEXT,
  first_paid_at INTEGER
);
CREATE INDEX apple_ads_subscriptions_install ON apple_ads_subscriptions (original_install_hash);

-- Apple supplies IDs in attribution responses. Names come from the campaign's
-- All Keywords > Actions > Download Keywords export on November 19, 2026.
CREATE TABLE apple_ads_keywords (
  campaign_id INTEGER NOT NULL,
  ad_group_id INTEGER NOT NULL,
  keyword_id INTEGER NOT NULL,
  keyword TEXT NOT NULL,
  match_type TEXT NOT NULL,
  PRIMARY KEY (campaign_id, ad_group_id, keyword_id)
);
INSERT INTO apple_ads_keywords (campaign_id, ad_group_id, keyword_id, keyword, match_type) VALUES
  (2145166595, 2153003314, 2408175165, 'lively translator', 'EXACT'),
  (2145166595, 2153003314, 2408175166, 'lively live translator', 'EXACT'),
  (2145166596, 2153003317, 2408170241, 'live translator', 'EXACT'),
  (2145166596, 2153003317, 2408177992, 'voice translator', 'EXACT'),
  (2145166596, 2153003317, 2408177993, 'interpreter', 'EXACT'),
  (2145166596, 2153003317, 2408177994, 'face to face translator', 'EXACT'),
  (2145166596, 2153003317, 2408177995, 'conversation translator', 'EXACT'),
  (2145166596, 2153003319, 2408175516, 'offline voice translator', 'EXACT'),
  (2145166596, 2153003319, 2408175517, 'offline travel translator', 'EXACT'),
  (2145166597, 2153003320, 2408176202, 'itranslate translator', 'EXACT'),
  (2145166597, 2153003320, 2408176203, 'microsoft translator', 'EXACT'),
  (2145166598, 2153003315, 2408176058, 'travel translator', 'BROAD'),
  (2145166598, 2153003315, 2408176059, 'two way translator', 'BROAD'),
  (2145166598, 2153003315, 2408176060, 'speech translation', 'BROAD'),
  (2145166599, 2153003316, 2408175313, 'chinese translator', 'EXACT'),
  (2145166599, 2153003316, 2408175314, 'english to chinese translator', 'EXACT'),
  (2145166599, 2153003316, 2408175315, 'chinese voice translator', 'EXACT'),
  (2145166599, 2153003318, 2408175808, 'english to japanese translator', 'EXACT'),
  (2145166599, 2153003318, 2408175809, 'japanese voice translator', 'EXACT'),
  (2145166599, 2153003318, 2408175810, 'japanese to english translator', 'EXACT');

CREATE VIEW apple_ads_keyword_conversions AS
SELECT i.campaign_id, i.ad_group_id, i.keyword_id, k.keyword, k.match_type, i.claim_type, i.conversion_type,
       date(i.received_at, 'unixepoch') AS install_cohort_utc,
       count(DISTINCT i.install_hash) AS installs,
       count(s.first_paid_at) AS paid_subscriptions
FROM apple_ads_installs i
LEFT JOIN apple_ads_keywords k USING (campaign_id, ad_group_id, keyword_id)
LEFT JOIN apple_ads_subscriptions s ON s.original_install_hash = i.install_hash
GROUP BY i.campaign_id, i.ad_group_id, i.keyword_id, i.claim_type, i.conversion_type, install_cohort_utc;
