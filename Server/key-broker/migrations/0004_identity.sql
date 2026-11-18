-- Sign in with Apple and Google (identity.ts). An account is still one email;
-- these are the provider's stable ID for the person, so the account is found
-- again if the email at the provider changes.
ALTER TABLE users ADD COLUMN apple_sub TEXT;
ALTER TABLE users ADD COLUMN google_sub TEXT;
CREATE UNIQUE INDEX users_apple_sub ON users (apple_sub) WHERE apple_sub IS NOT NULL;
CREATE UNIQUE INDEX users_google_sub ON users (google_sub) WHERE google_sub IS NOT NULL;

-- Apple's refresh token for the account, kept only to revoke the app's
-- access at Apple when the account is deleted.
ALTER TABLE users ADD COLUMN apple_refresh_token TEXT;
