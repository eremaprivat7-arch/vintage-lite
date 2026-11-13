CREATE TABLE IF NOT EXISTS app_releases (
  version TEXT NOT NULL,
  build TEXT NOT NULL,
  blocked INTEGER NOT NULL DEFAULT 0 CHECK (blocked IN (0, 1)),
  PRIMARY KEY (version, build)
);

INSERT OR IGNORE INTO app_releases (version, build) VALUES
  ('legacy', 'legacy'),
  ('2.2.4', '15'),
  ('2.2.5', '16'),
  ('2.2.6', '17');
