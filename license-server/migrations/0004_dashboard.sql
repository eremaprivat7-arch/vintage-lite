CREATE TABLE IF NOT EXISTS portal_names(uid TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS portal_manual_keys(digest TEXT PRIMARY KEY, seed TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS portal_sale_dates(event TEXT PRIMARY KEY, sold INTEGER);
INSERT OR IGNORE INTO portal_sale_dates(event,sold)
 SELECT o.event,l.created FROM shop_orders o LEFT JOIN licenses l ON l.digest=o.digest;
CREATE TRIGGER IF NOT EXISTS portal_order_date AFTER INSERT ON shop_orders BEGIN
 INSERT OR IGNORE INTO portal_sale_dates(event,sold) VALUES(NEW.event,unixepoch());
END;
