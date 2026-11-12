const utf8 = new TextEncoder();
const hex = bytes => Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, "0")).join("");

export async function issuedKey(secret, event) {
  const signingKey = await crypto.subtle.importKey("raw", utf8.encode(secret),
    {name:"HMAC", hash:"SHA-256"}, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", signingKey, utf8.encode(event));
  return "VL-" + hex(signature).slice(0,32).toUpperCase();
}

export async function reveal(env, id, uid) {
  const row = await env.DB.prepare(`SELECT l.digest, o.event, m.seed FROM licenses l
    LEFT JOIN shop_orders o ON o.digest=l.digest LEFT JOIN portal_manual_keys m ON m.digest=l.digest
    WHERE l.id=? AND (? IS NULL OR o.uid=?)`).bind(id,uid,uid).first();
  if (!row) return {error:"Ключ не найден"};
  const seed = row.event || row.seed;
  if (!seed || !env.KEY_SECRET) return {error:"Полный ключ недоступен. Используйте выданную копию."};
  const key = await issuedKey(env.KEY_SECRET,seed);
  const digest = hex(await crypto.subtle.digest("SHA-256",utf8.encode(key)));
  return digest === row.digest ? {key} : {error:"Для этого ключа использовался другой секрет выдачи."};
}

export async function report(env,uid) {
  const now = Math.floor(Date.now()/1000);
  const today = Math.floor((now+18000)/86400)*86400-18000;
  const [keys,sales,names,mode,devices,manual] = await env.DB.batch([
    env.DB.prepare(`SELECT NOT EXISTS(SELECT 1 FROM reseller_access r WHERE r.uid=o.uid) AS owner,l.id,l.lifetime,l.seats,l.created,l.expires,l.revoked,o.uid,o.days,
       CASE WHEN o.event IS NOT NULL OR m.seed IS NOT NULL THEN 1 ELSE 0 END AS revealable,
       CASE WHEN l.label NOT LIKE 'Telegram %' THEN substr(l.label,-8) END AS suffix,
       (SELECT count(*) FROM devices d WHERE d.license=l.id) AS devices,
       (SELECT count(*) FROM devices d WHERE d.license=l.id AND blocked=0) AS used
       FROM licenses l LEFT JOIN shop_orders o ON o.digest=l.digest
       LEFT JOIN portal_manual_keys m ON m.digest=l.digest
       WHERE (? IS NULL OR o.uid=?) ORDER BY l.id DESC`).bind(uid,uid),
    env.DB.prepare(`SELECT NOT EXISTS(SELECT 1 FROM reseller_access r WHERE r.uid=o.uid) AS owner,o.uid,count(*) AS total, sum(cost) AS amount,
       sum(CASE WHEN sold>=? THEN 1 ELSE 0 END) AS today,
       sum(CASE WHEN sold>=? THEN 1 ELSE 0 END) AS week,
       sum(CASE WHEN sold IS NULL THEN 1 ELSE 0 END) AS undated
       FROM shop_orders o LEFT JOIN portal_sale_dates s ON s.event=o.event
       WHERE (? IS NULL OR o.uid=?) GROUP BY o.uid`).bind(today,today-6*86400,uid,uid),
    env.DB.prepare(`WITH accounts AS (SELECT r.uid FROM reseller_access r LEFT JOIN portal_tokens t USING(uid) WHERE coalesce(t.removed,0)=0)
       SELECT a.uid,n.name,coalesce(w.balance,0) AS balance,r.prices,r.token_hash IS NOT NULL AS enabled
       FROM accounts a LEFT JOIN portal_names n USING(uid) LEFT JOIN shop_wallet w USING(uid)
       LEFT JOIN reseller_access r USING(uid) WHERE (? IS NULL OR a.uid=?) ORDER BY coalesce(n.name,a.uid)`).bind(uid,uid),
    env.DB.prepare("SELECT started FROM patch_mode WHERE id=1"),
    env.DB.prepare("SELECT license,device,blocked FROM devices WHERE ? IS NULL").bind(uid),
    env.DB.prepare(`SELECT count(*) AS total,
      coalesce(sum(CASE WHEN created>=? THEN 1 ELSE 0 END),0) AS today,
      coalesce(sum(CASE WHEN created>=? THEN 1 ELSE 0 END),0) AS week
      FROM licenses l WHERE ? IS NULL AND NOT EXISTS(SELECT 1 FROM shop_orders o WHERE o.digest=l.digest)`).bind(today,today-6*86400,uid)
  ]);
  return {manual:manual.results[0],devices:devices.results,keys:keys.results,sales:sales.results,accounts:names.results,started:mode.results[0]?.started ?? null};
}
