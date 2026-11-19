-- Dates in Apple notifications can precede their delivery or a later sign-in.
ALTER TABLE users ADD COLUMN apple_authorized_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN apple_email_event_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN apple_email_disabled INTEGER NOT NULL DEFAULT 0;
