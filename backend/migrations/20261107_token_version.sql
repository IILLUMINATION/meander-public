-- SEC-02: token revocation.
-- authMiddleware compares the JWT `tv` claim with this column. Increment it on
-- ban, unban, role change, password reset, or any other credential change to
-- invalidate every previously issued token for the account.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS token_version INTEGER NOT NULL DEFAULT 0;