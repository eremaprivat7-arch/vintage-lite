CREATE TABLE IF NOT EXISTS reseller_access (
 uid TEXT PRIMARY KEY,
 token_hash TEXT UNIQUE,
 prices TEXT NOT NULL
);
