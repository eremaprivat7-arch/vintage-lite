CREATE TABLE IF NOT EXISTS shop_plans(days INTEGER PRIMARY KEY, price INTEGER CHECK(price>cash), hours INTEGER NOT NULL, cash INTEGER NOT NULL);
INSERT INTO shop_plans(days,price,hours,cash) VALUES
 (1,150,1,10),(3,420,3,20),(7,900,6,40),(15,2100,24,70),(30,3000,48,100)
 ON CONFLICT(days) DO UPDATE SET price=excluded.price;
CREATE TABLE IF NOT EXISTS shop_wallet(uid TEXT PRIMARY KEY, balance INTEGER NOT NULL DEFAULT 0 CHECK(balance>=0));
CREATE TABLE IF NOT EXISTS shop_adjust(event TEXT PRIMARY KEY,uid TEXT NOT NULL,delta INTEGER NOT NULL);
CREATE TRIGGER IF NOT EXISTS shop_adjust_apply AFTER INSERT ON shop_adjust BEGIN
 INSERT INTO shop_wallet(uid) VALUES(NEW.uid) ON CONFLICT DO NOTHING;
 UPDATE shop_wallet SET balance=balance+NEW.delta WHERE uid=NEW.uid;
END;
CREATE TABLE IF NOT EXISTS shop_orders(event TEXT PRIMARY KEY,uid TEXT NOT NULL,days INTEGER NOT NULL,cost INTEGER NOT NULL,digest TEXT UNIQUE NOT NULL);
CREATE TRIGGER IF NOT EXISTS shop_purchase AFTER INSERT ON shop_orders BEGIN
 SELECT CASE WHEN COALESCE((SELECT balance FROM shop_wallet WHERE uid=NEW.uid),0)<NEW.cost THEN RAISE(ABORT,'low_balance') END;
 UPDATE shop_wallet SET balance=balance-NEW.cost WHERE uid=NEW.uid;
 INSERT INTO licenses(digest,label,seats,lifetime,created) VALUES(NEW.digest,'Telegram '||NEW.uid,1,NEW.days*86400,unixepoch());
END;
CREATE TABLE IF NOT EXISTS shop_bonus(license INTEGER PRIMARY KEY,uid TEXT NOT NULL, hours INTEGER NOT NULL,cash INTEGER NOT NULL);
CREATE TRIGGER IF NOT EXISTS shop_reward AFTER INSERT ON shop_bonus BEGIN
 UPDATE licenses SET lifetime=lifetime+NEW.hours*3600,expires=expires+NEW.hours*3600 WHERE id=NEW.license;
 INSERT INTO shop_wallet(uid,balance) VALUES(NEW.uid,NEW.cash) ON CONFLICT(uid) DO UPDATE SET balance=balance+excluded.balance;
END;
