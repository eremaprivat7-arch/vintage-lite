CREATE TABLE IF NOT EXISTS licenses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  digest TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  seats INTEGER NOT NULL CHECK (seats BETWEEN 1 AND 100000),
  lifetime INTEGER NOT NULL CHECK (lifetime > 0),
  expires INTEGER,
  revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1)),
  created INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  license INTEGER NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
  device TEXT NOT NULL,
  blocked INTEGER NOT NULL DEFAULT 0 CHECK (blocked IN (0, 1)),
  PRIMARY KEY (license, device)
);

CREATE INDEX IF NOT EXISTS devices_license_active
  ON devices (license, blocked);
