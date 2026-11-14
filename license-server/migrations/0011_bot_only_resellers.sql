CREATE TABLE IF NOT EXISTS bot_resellers (
  uid TEXT PRIMARY KEY,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  created INTEGER NOT NULL DEFAULT (unixepoch())
);
