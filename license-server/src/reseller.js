import {seal,unseal} from "./token-vault.js";
import {report,reveal} from "./dashboard.js";
const days = [1,3,7,15,30];
const hex = bytes => Array.from(new Uint8Array(bytes), x=>x.toString(16).padStart(2,'0')).join('');
const encoder = new TextEncoder();
const hash = async text => hex(await crypto.subtle.digest('SHA-256',encoder.encode(text)));
const reply = (body,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});

export async function manage(req,env){
  const body=await req.json().catch(()=>null);
  if(!body || !/^[1-9]\d{0,15}$/.test(body.uid) || typeof body.uid!=='string') return reply({error:'Введи числовой Telegram ID'},400);
  const {uid,action,prices}=body;
  if(action==='show'){
    const row=await env.DB.prepare("SELECT t.payload FROM portal_tokens t JOIN reseller_access r USING(uid) WHERE t.uid=? AND t.removed=0 AND r.token_hash IS NOT NULL").bind(uid).first();
    if(!row?.payload)return reply({error:"Старый токен хранится только у владельца. Вставьте его в поле сохранения либо перевыпустите."},404);
    try{return reply({token:await unseal(row.payload,env.SESSION_SECRET,uid)})}
    catch{return reply({error:"Не удалось открыть токен. Проверьте прежний SESSION_SECRET."},409)}
  }
  if(action==='save-token'){
    if(typeof body.token!=="string" || !/^vr_[a-f0-9]{64}$/.test(body.token))return reply({error:"Проверьте токен"},400);
    const row=await env.DB.prepare("SELECT uid FROM reseller_access WHERE uid=? AND token_hash=?").bind(uid,await hash(body.token)).first();
    if(!row)return reply({error:"Токен не совпадает с API этого реселлера"},409);
    await env.DB.prepare("INSERT INTO portal_tokens(uid,payload) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET payload=excluded.payload,removed=0").bind(uid,await seal(body.token,env.SESSION_SECRET,uid)).run();
    return reply({message:"Токен сохранён"});
  }
  if(action==='delete'){
    await env.DB.batch([
      env.DB.prepare("UPDATE reseller_access SET token_hash=NULL WHERE uid=?").bind(uid),
      env.DB.prepare("INSERT INTO portal_tokens(uid,removed) VALUES(?,1) ON CONFLICT(uid) DO UPDATE SET removed=1,payload=NULL").bind(uid)
    ]);
    return reply({message:"Реселлер удалён из списка. API отключён. История и баланс сохранены."});
  }
  if(action==='revoke'){
    await env.DB.prepare('UPDATE reseller_access SET token_hash=NULL WHERE uid=?').bind(uid).run();
    return reply({message:'Доступ отключён'});
  }
  if(!['issue','create','prices'].includes(action) || !days.every(d=>Number.isSafeInteger(prices?.[d]) && prices[d]>0 && prices[d]<=99999999)) return reply({error:'Укажи пять положительных цен'},400);
  const encoded=JSON.stringify(Object.fromEntries(days.map(d=>[d,prices[d]])));
  if(action==='prices'){
    const r=await env.DB.prepare('UPDATE reseller_access SET prices=? WHERE uid=?').bind(encoded,uid).run();
    return r.meta.changes?reply({message:'Цены сохранены'}):reply({error:'Сначала выпусти токен'},404);
  }
  if(action==='create'){
    if(typeof body.name!=="string" || !body.name.trim() || body.name.trim().length>64)return reply({error:"Укажите имя реселлера"},400);
    const existing=await env.DB.prepare("SELECT uid FROM reseller_access WHERE uid=? AND token_hash IS NOT NULL").bind(uid).first();
    if(existing)return reply({error:"Реселлер с этим ID уже имеет API"},409);
  }
  const token='vr_'+hex(crypto.getRandomValues(new Uint8Array(32)));
  const statements=[
    env.DB.prepare("INSERT INTO reseller_access(uid,token_hash,prices) VALUES(?,?,?) ON CONFLICT(uid) DO UPDATE SET token_hash=excluded.token_hash,prices=excluded.prices").bind(uid,await hash(token),encoded),
    env.DB.prepare("INSERT INTO portal_tokens(uid,payload) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET payload=excluded.payload,removed=0").bind(uid,await seal(token,env.SESSION_SECRET,uid))
  ];
  if(action==='create')statements.push(env.DB.prepare("INSERT INTO portal_names VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET name=excluded.name").bind(uid,body.name.trim()));
  await env.DB.batch(statements);
  return reply({token});
}

export async function reseller(req,env,path){
  const auth=req.headers.get('Authorization')||'';
  if(!/^Bearer vr_[a-f0-9]{64}$/.test(auth)) return reply({error:'Неверный токен'},401);
  const digest=await hash(auth.slice(7));
  const account=await env.DB.prepare('SELECT r.uid,r.prices,COALESCE(w.balance,0) AS balance FROM reseller_access r LEFT JOIN shop_wallet w ON r.uid=w.uid WHERE r.token_hash=?').bind(digest).first();
  if(!account) return reply({error:'Токен отключён или неверен'},401);
  const prices=JSON.parse(account.prices);
  if(path==='/reseller/api/report' && req.method==='GET') return reply(await report(env,account.uid));
  const show = path.match(/^\/reseller\/api\/show\/(\d+)$/);
  if(show && req.method==='GET') {
    const result=await reveal(env,Number(show[1]),account.uid);
    return reply(result,result.error?404:200);
  }
  if(path==='/reseller/api/account' && req.method==='GET') return reply({...account,prices});
  if(path!=='/reseller/api/purchase' || req.method!=='POST') return reply({error:'Маршрут не найден'},404);
  const b=await req.json().catch(()=>null);
  if(!days.includes(b?.days) || typeof b.order_id!=='string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(b.order_id) || !Number.isSafeInteger(b.price)) return reply({error:'Проверь days, price и order_id'},400);
  if(!env.KEY_SECRET) return reply({error:'Владелец должен настроить KEY_SECRET'},503);
  const event='reseller:'+account.uid+':'+b.order_id;
  const secret=await crypto.subtle.importKey('raw',encoder.encode(env.KEY_SECRET),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const key='VL-'+hex(await crypto.subtle.sign('HMAC',secret,encoder.encode(event))).slice(0,32).toUpperCase();
  const keyHash=await hash(key);
  try{
    await env.DB.prepare(`INSERT INTO shop_orders(event,uid,days,cost,digest)
      SELECT ?,uid,?,json_extract(prices,?),? FROM reseller_access
      WHERE token_hash=? AND json_extract(prices,?)=?
      ON CONFLICT(event) DO NOTHING`).bind(event,b.days,'$."'+b.days+'"',keyHash,digest,'$."'+b.days+'"',b.price).run();
  }catch(e){
    if(String(e).includes('low_balance')) return reply({error:'Недостаточно средств'},409);
    throw e;
  }
  const order=await env.DB.prepare('SELECT days,cost,digest FROM shop_orders WHERE event=?').bind(event).first();
  if(!order || order.days!==b.days || order.cost!==b.price || order.digest!==keyHash) return reply({error:'Обнови тарифы или проверь номер заказа'},409);
  return reply({key,days:order.days,cost:order.cost,order_id:b.order_id});
}
