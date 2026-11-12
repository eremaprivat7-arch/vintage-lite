-- Execute ONLY against the new vintage-private-content database, never DB.
CREATE TABLE IF NOT EXISTS pc_devices (
  license INTEGER NOT NULL, device TEXT NOT NULL, signing TEXT NOT NULL,
  agreement TEXT NOT NULL, created INTEGER NOT NULL,
  PRIMARY KEY(license, device)
);
CREATE TABLE IF NOT EXISTS pc_sessions (
  digest TEXT PRIMARY KEY, license INTEGER NOT NULL, device TEXT NOT NULL,
  app_version TEXT NOT NULL, app_build TEXT NOT NULL, expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS pc_sessions_expiry ON pc_sessions(expires);
CREATE TABLE IF NOT EXISTS pc_nonces (nonce TEXT PRIMARY KEY, expires INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS pc_nonces_expiry ON pc_nonces(expires);
CREATE TABLE IF NOT EXISTS pc_limits (
  scope TEXT NOT NULL, bucket INTEGER NOT NULL, hits INTEGER NOT NULL, expires INTEGER NOT NULL,
  PRIMARY KEY(scope,bucket)
);
CREATE INDEX IF NOT EXISTS pc_limits_expiry ON pc_limits(expires);
CREATE TABLE IF NOT EXISTS pc_assets (
  id TEXT NOT NULL, revision TEXT NOT NULL, title TEXT NOT NULL,
  category TEXT NOT NULL CHECK(category IN ('Boost','Mod Skin','FPS','Holo')),
  package_id TEXT NOT NULL, size INTEGER NOT NULL CHECK(size BETWEEN 48 AND 8388608),
  parts INTEGER NOT NULL CHECK(parts BETWEEN 1 AND 32), manifest TEXT NOT NULL,
  wrapped_key BLOB NOT NULL, created INTEGER NOT NULL,
  PRIMARY KEY(id,revision)
);
CREATE TABLE IF NOT EXISTS pc_chunks (
  asset TEXT NOT NULL, revision TEXT NOT NULL, part INTEGER NOT NULL,
  payload BLOB NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(asset,revision,part),
  FOREIGN KEY(asset,revision) REFERENCES pc_assets(id,revision) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS pc_heads (
  id TEXT PRIMARY KEY, revision TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY(id,revision) REFERENCES pc_assets(id,revision)
);
