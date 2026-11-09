CREATE TABLE IF NOT EXISTS patch_mode (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  started INTEGER
);
INSERT OR IGNORE INTO patch_mode (id, started) VALUES (1, NULL);
