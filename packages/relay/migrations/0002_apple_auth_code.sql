-- Store the most-recent Apple authorizationCode per user so the
-- relay can call Apple's /auth/revoke endpoint during account
-- deletion. Apple's revoke flow needs a fresh auth_code (or a
-- valid refresh_token); we keep the auth_code we received on the
-- last sign-in event for that user, server-only.
ALTER TABLE users ADD COLUMN apple_auth_code TEXT;
