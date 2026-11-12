// Private payload delivery. All writes use CONTENT_DB; licensing DB is read-only here.
import {releaseIdentity,releaseBlocked} from './releases.js';
const enc=new TextEncoder(), PART=262144, MAX=8*1024*1024;
const uid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
const hash=v=>crypto.subtle.digest('SHA-256',typeof v==='string'?enc.encode(v):v).then(v=>hex(v));
const hex=v=>Array.from(bytes(v),b=>b.toString(16).padStart(2,'0')).join('');
const bytes=v=>v instanceof Uint8Array?v:new Uint8Array(v);
const now=()=>Math.floor(Date.now()/1000);
function b64(v){const a=bytes(v);if(a.toBase64)return a.toBase64();let s='';for(let i=0;i<a.length;i+=8192)s+=String.fromCharCode(...a.subarray(i,i+8192));return btoa(s);}
function un64(v,max=MAX){if(typeof v!=='string'||v.length>Math.ceil(max/3)*4+4||!/^[A-Za-z0-9+/]*={0,2}$/.test(v))throw fail('invalid',400);let a;try{a=Uint8Array.fromBase64?Uint8Array.fromBase64(v):Uint8Array.from(atob(v),c=>c.charCodeAt(0));}catch{throw fail('invalid',400);}if(a.length>max||b64(a)!==v)throw fail('invalid',400);return a;}
function fail(error,status=403){return Object.assign(new Error(error),{status});}
const headers={'Cache-Control':'private, no-store','CDN-Cache-Control':'no-store','X-Content-Type-Options':'nosniff','X-Frame-Options':'DENY','Referrer-Policy':'no-referrer'};
const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{...headers,'Content-Type':'application/json; charset=utf-8'}});
export async function boundedJSON(request,max=4096){
  const length=Number(request.headers.get('Content-Length'));
  if(Number.isFinite(length)&&length>max)throw fail('too_large',413);
  const reader=request.body?.getReader();let total=0,chunks=[];
  if(reader){try{for(;;){const {done,value}=await reader.read();if(done)break;total+=value.byteLength;if(total>max){await reader.cancel();throw fail('too_large',413);}chunks.push(value);}}finally{reader.releaseLock();}}
  const data=new Uint8Array(total);let offset=0;for(const chunk of chunks){data.set(chunk,offset);offset+=chunk.length;}
  let raw,value;try{raw=new TextDecoder('utf-8',{fatal:true}).decode(data);value=JSON.parse(raw);}catch{throw fail('invalid',400);}
  if(!value||typeof value!=='object'||Array.isArray(value))throw fail('invalid',400);
  return {raw,value};
}
async function limit(env,scope,maximum,seconds=60){
  const bucket=Math.floor(now()/seconds);
  const row=await env.CONTENT_DB.prepare('INSERT INTO pc_limits(scope,bucket,hits,expires) VALUES(?,?,1,?) ON CONFLICT(scope,bucket) DO UPDATE SET hits=hits+1 RETURNING hits').bind(scope,bucket,(bucket+1)*seconds).first();
  if(row.hits>maximum)throw fail('rate_limited',429);
}
export async function limitAdminLogin(request,env){
  if(!env.CONTENT_DB)return;
  const ip=request.headers.get('CF-Connecting-IP')||'unknown';
  await limit(env,'admin:'+await hash(ip),10,600);
}
async function liveLicense(env,key,device,version,build,licenseID=null){
  const identity=releaseIdentity(version,build);
  if(!identity)throw fail('invalid_version',400);
  if(await releaseBlocked(env,identity))throw fail('update_required',503);
  const patch=await env.DB.prepare('SELECT started FROM patch_mode WHERE id=1').first();
  if(patch?.started!==null&&patch?.started!==undefined)throw fail('maintenance',503);
  let row;
  if(licenseID!==null){row=await env.DB.prepare('SELECT l.id,l.expires,l.revoked,d.blocked FROM licenses l JOIN devices d ON d.license=l.id WHERE l.id=? AND d.device=?').bind(licenseID,device).first();}
  else{
    if(typeof key!=='string'||key.length>96||key.trim().length<16||!uid(device))throw fail('invalid');
    row=await env.DB.prepare('SELECT l.id,l.expires,l.revoked,d.blocked FROM licenses l JOIN devices d ON d.license=l.id WHERE l.digest=? AND d.device=?').bind(await hash(key.trim().toUpperCase()),device.toLowerCase()).first();
  }
  if(!row||row.revoked||row.blocked||row.expires===null||row.expires<=now())throw fail('license_denied');
  return row;
}
async function verifyProof(request,raw,token,signing){
  const nonce=request.headers.get('X-VL-Nonce'), stamp=request.headers.get('X-VL-Time');
  if(!uid(nonce)||!/^\d{10}$/.test(stamp||''))throw fail('invalid_proof');
  if(Math.abs(Number(stamp)-now())>90)throw fail('clock_skew',409);
  const sig=un64(request.headers.get('X-VL-Signature'),64);
  if(sig.length!==64)throw fail('invalid_proof');
  const publicBytes=un64(signing,65);
  if(publicBytes.length!==65||publicBytes[0]!==4)throw fail('invalid_proof');
  const key=await crypto.subtle.importKey('raw',publicBytes,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  const message=['VL1',request.method,new URL(request.url).pathname,nonce,stamp,await hash(token),await hash(raw)].join('\n');
  if(!await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,sig,enc.encode(message)))throw fail('invalid_proof');
  return {nonce,expires:Number(stamp)+91};
}
async function claim(env,proof){
  const result=await env.CONTENT_DB.prepare('INSERT INTO pc_nonces(nonce,expires) VALUES(?,?) ON CONFLICT DO NOTHING').bind(proof.nonce,proof.expires).run();
  if(!result.meta?.changes)throw fail('replayed',409);
}
async function clean(env){
  await env.CONTENT_DB.batch([
    env.CONTENT_DB.prepare('DELETE FROM pc_nonces WHERE nonce IN (SELECT nonce FROM pc_nonces WHERE expires<? LIMIT 100)').bind(now()),
    env.CONTENT_DB.prepare('DELETE FROM pc_sessions WHERE digest IN (SELECT digest FROM pc_sessions WHERE expires<? LIMIT 100)').bind(now()),
    env.CONTENT_DB.prepare('DELETE FROM pc_limits WHERE expires<?').bind(now()-3600),
  ]);
}
async function session(request,env){
  const {raw,value:b}=await boundedJSON(request);
  if(!uid(b.device)||typeof b.app_version!=='string'||typeof b.app_build!=='string')throw fail('invalid',400);
  const device=b.device.toLowerCase();
  const lic=await liveLicense(env,b.key,device,b.app_version,b.app_build);
  await limit(env,'session:'+lic.id+':'+device,10);
  const proof=await verifyProof(request,raw,'',b.signing);
  const agreement=un64(b.agreement,65);
  if(agreement.length!==65||agreement[0]!==4)throw fail('invalid_proof');
  await crypto.subtle.importKey('raw',agreement,{name:'ECDH',namedCurve:'P-256'},false,[]);
  const existing=await env.CONTENT_DB.prepare('SELECT signing,agreement FROM pc_devices WHERE license=? AND device=?').bind(lic.id,device).first();
  if(existing&&(existing.signing!==b.signing||existing.agreement!==b.agreement))throw fail('device_key_changed');
  await claim(env,proof);
  await env.CONTENT_DB.prepare('INSERT INTO pc_devices(license,device,signing,agreement,created) VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING').bind(lic.id,device,b.signing,b.agreement,now()).run();
  const bound=await env.CONTENT_DB.prepare('SELECT signing,agreement FROM pc_devices WHERE license=? AND device=?').bind(lic.id,device).first();
  if(bound.signing!==b.signing||bound.agreement!==b.agreement)throw fail('device_key_changed');
  const token=b64(crypto.getRandomValues(new Uint8Array(32))),expires=Math.min(lic.expires,now()+300);
  await env.CONTENT_DB.prepare('INSERT INTO pc_sessions(digest,license,device,app_version,app_build,expires) VALUES(?,?,?,?,?,?)').bind(await hash(token),lic.id,device,b.app_version,b.app_build,expires).run();
  await clean(env);
  return json({token,expires,server_time:now()});
}
async function authorize(request,env,raw){
  const match=(request.headers.get('Authorization')||'').match(/^Bearer ([A-Za-z0-9+/]{43}=)$/);
  if(!match)throw fail('unauthorized',401);
  const digest=await hash(match[1]);
  const s=await env.CONTENT_DB.prepare('SELECT s.*,d.signing,d.agreement FROM pc_sessions s JOIN pc_devices d ON s.license=d.license AND s.device=d.device WHERE s.digest=? AND s.expires>?').bind(digest,now()).first();
  if(!s)throw fail('session_expired',401);
  const proof=await verifyProof(request,raw,match[1],s.signing);
  await liveLicense(env,null,s.device,s.app_version,s.app_build,s.license);
  await claim(env,proof);
  return s;
}
async function master(env){
  let data;try{data=un64(env.CONTENT_MASTER_KEY?.trim(),32);}catch{throw fail('content_setup',503);}
  if(data.length!==32)throw fail('content_setup',503);
  return crypto.subtle.importKey('raw',data,'AES-GCM',false,['encrypt','decrypt']);
}
async function seal(key,data,aad){
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:enc.encode(aad)},key,data));
  const joined=new Uint8Array(12+cipher.length);joined.set(iv);joined.set(cipher,12);return joined;
}
async function unseal(key,data,aad){const a=bytes(data);return new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:a.subarray(0,12),additionalData:enc.encode(aad)},key,a.subarray(12)));}
async function deliver(env,id,s){
  if(!uid(id))throw fail('not_found',404);
  const asset=await env.CONTENT_DB.prepare('SELECT a.* FROM pc_heads h JOIN pc_assets a ON a.id=h.id AND a.revision=h.revision WHERE h.id=? AND h.enabled=1').bind(id).first();
  if(!asset)throw fail('not_found',404);
  const dataKey=await unseal(await master(env),asset.wrapped_key,'VL-master-v1:'+id+':'+asset.revision);
  const ephemeral=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},true,['deriveBits']);
  const receiver=await crypto.subtle.importKey('raw',un64(s.agreement,65),{name:'ECDH',namedCurve:'P-256'},false,[]);
  const shared=await crypto.subtle.deriveBits({name:'ECDH',public:receiver},ephemeral.privateKey,256);
  const salt=crypto.getRandomValues(new Uint8Array(32)),info='VL-wrap-v1:'+id+':'+asset.revision;
  const material=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveKey']);
  const wrapping=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt,info:enc.encode(info)},material,{name:'AES-GCM',length:256},false,['encrypt']);
  const wrap={public_key:b64(await crypto.subtle.exportKey('raw',ephemeral.publicKey)),salt:b64(salt),key:b64(await seal(wrapping,dataKey,info)),revision:asset.revision,parts:asset.parts,size:asset.size};
  dataKey.fill(0);
  return new Response(null,{headers:{...headers,'Content-Type':'application/octet-stream','X-VL-Key':b64(enc.encode(JSON.stringify(wrap))),'Content-Length':'0'}});
}
async function deliverChunk(env,b){
  if(!uid(b.id)||typeof b.revision!=='string'||!/^[a-f0-9]{64}$/.test(b.revision)||typeof b.part!=='string'||!/^(0|[1-9]\d?)$/.test(b.part))throw fail('invalid',400);
  const part=Number(b.part);if(part>=32)throw fail('invalid',400);
  const row=await env.CONTENT_DB.prepare('SELECT c.payload,c.digest FROM pc_chunks c JOIN pc_heads h ON h.id=c.asset AND h.revision=c.revision WHERE h.id=? AND h.revision=? AND h.enabled=1 AND c.part=?').bind(b.id,b.revision,part).first();
  if(!row)throw fail('stale',409);
  const data=bytes(row.payload);if(data.length>PART||!/^[a-f0-9]{64}$/.test(row.digest))throw fail('content_unavailable',503);
  return new Response(data,{headers:{...headers,'Content-Type':'application/octet-stream','X-VL-Part-SHA256':row.digest,'Content-Length':String(data.length)}});
}
export async function privateContent(request,env,url){
  try{
    if(!env.CONTENT_DB)throw fail('content_setup',503);
    await master(env);
    if(request.method!=='POST')return json({error:'method_not_allowed'},405);
    await limit(env,'ip:'+await hash(request.headers.get('CF-Connecting-IP')||'unknown'),600);
    if(url.pathname==='/api/content/session')return await session(request,env);
    const {raw,value}=await boundedJSON(request);
    const s=await authorize(request,env,raw);
    await limit(env,'read:'+s.license+':'+s.device,90);
    if(url.pathname==='/api/content/catalog'){
      const assets=await env.CONTENT_DB.prepare('SELECT a.id,a.title,a.category,a.package_id,a.size,a.revision FROM pc_heads h JOIN pc_assets a ON a.id=h.id AND a.revision=h.revision WHERE h.enabled=1 ORDER BY a.category,a.title LIMIT 300').all();
      return json({assets:assets.results||[],server_time:now()});
    }
    if(url.pathname==='/api/content/package')return await deliver(env,value.id,s);
    if(url.pathname==='/api/content/chunk')return await deliverChunk(env,value);
    return json({error:'not_found'},404);
  }catch(e){return json({error:e.status?e.message:'content_unavailable',server_time:now()},e.status||503);}
}
export async function manageContent(request,env,url){
  try{
    if(!env.CONTENT_DB)throw fail('content_setup',503);
    if(url.pathname==='/admin/api/content/status'&&request.method==='GET'){
      const assets=await env.CONTENT_DB.prepare('SELECT h.id,h.enabled,a.title,a.category,a.size,a.revision FROM pc_heads h JOIN pc_assets a ON a.id=h.id AND a.revision=h.revision ORDER BY a.title').all();
      await master(env);return json({assets:assets.results||[],ready:true});
    }
    if(request.method!=='POST')return json({error:'method_not_allowed'},405);
    const {value:b}=await boundedJSON(request,url.pathname.endsWith('/chunk')?710000:4096);
    if(url.pathname==='/admin/api/content/begin'){
      if(!uid(b.id)||!uid(b.package_id)||typeof b.revision!=='string'||!/^[a-f0-9]{64}$/.test(b.revision)||typeof b.title!=='string'||!b.title.trim()||b.title.length>120||/[\x00-\x1f]/.test(b.title)||!['Boost','Mod Skin','FPS','Holo'].includes(b.category)||!Number.isInteger(b.size)||b.size<48||b.size>MAX||b.parts!==Math.ceil(b.size/PART)||!Array.isArray(b.hashes)||b.hashes.length!==b.parts||!b.hashes.every(v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v)))throw fail('invalid',400);
      const key=un64(b.key,32);if(key.length!==32)throw fail('invalid',400);
      const wrapped=await seal(await master(env),key,'VL-master-v1:'+b.id+':'+b.revision);key.fill(0);
      await env.CONTENT_DB.prepare('INSERT INTO pc_assets(id,revision,title,category,package_id,size,parts,manifest,wrapped_key,created) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING').bind(b.id,b.revision,b.title.trim(),b.category,b.package_id,b.size,b.parts,JSON.stringify(b.hashes),wrapped.buffer,now()).run();
      return json({ok:true});
    }
    if(url.pathname==='/admin/api/content/chunk'){
      if(!uid(b.id)||typeof b.revision!=='string'||!/^[a-f0-9]{64}$/.test(b.revision)||!Number.isInteger(b.part)||b.part<0||b.part>=32)throw fail('invalid',400);
      const asset=await env.CONTENT_DB.prepare('SELECT size,parts,manifest FROM pc_assets WHERE id=? AND revision=?').bind(b.id,b.revision).first();
      if(!asset||b.part>=asset.parts)throw fail('invalid',400);
      const active=await env.CONTENT_DB.prepare('SELECT id FROM pc_heads WHERE id=? AND revision=?').bind(b.id,b.revision).first();
      if(active)throw fail('already_published',409);
      const data=un64(b.data,PART),expected=Math.min(PART,asset.size-b.part*PART);
      if(data.length!==expected)throw fail('invalid',400);
      const digest=await hash(data);if(digest!==JSON.parse(asset.manifest)[b.part])throw fail('integrity',409);
      await env.CONTENT_DB.prepare('INSERT INTO pc_chunks(asset,revision,part,payload,digest) VALUES(?,?,?,?,?) ON CONFLICT(asset,revision,part) DO UPDATE SET payload=excluded.payload,digest=excluded.digest').bind(b.id,b.revision,b.part,data.buffer,digest).run();
      return json({ok:true});
    }
    if(url.pathname==='/admin/api/content/commit'){
      if(!uid(b.id)||typeof b.revision!=='string'||!/^[a-f0-9]{64}$/.test(b.revision))throw fail('invalid',400);
      const a=await env.CONTENT_DB.prepare('SELECT size,parts,manifest FROM pc_assets WHERE id=? AND revision=?').bind(b.id,b.revision).first();
      if(!a)throw fail('invalid',400);
      const rows=(await env.CONTENT_DB.prepare('SELECT part,digest,length(payload) AS size FROM pc_chunks WHERE asset=? AND revision=? ORDER BY part').bind(b.id,b.revision).all()).results;
      const manifest=JSON.parse(a.manifest);let offset=0;
      if(rows.length!==a.parts)throw fail('incomplete_upload',409);
      for(let i=0;i<rows.length;i++){if(rows[i].part!==i||rows[i].size!==Math.min(PART,a.size-i*PART)||rows[i].digest!==manifest[i])throw fail('incomplete_upload',409);offset+=rows[i].size;}
      if(offset!==a.size)throw fail('integrity',409);
      await env.CONTENT_DB.batch([
        env.CONTENT_DB.prepare('INSERT INTO pc_heads(id,revision,enabled) VALUES(?,?,1) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,enabled=1').bind(b.id,b.revision),
        env.CONTENT_DB.prepare('DELETE FROM pc_assets WHERE id=? AND revision<>?').bind(b.id,b.revision),
      ]);
      return json({ok:true});
    }
    if(url.pathname==='/admin/api/content/disable'){
      if(!uid(b.id))throw fail('invalid',400);
      await env.CONTENT_DB.prepare('UPDATE pc_heads SET enabled=0 WHERE id=?').bind(b.id).run();return json({ok:true});
    }
    if(url.pathname==='/admin/api/content/reset-device'){
      if(!Number.isSafeInteger(b.license)||!uid(b.device))throw fail('invalid',400);
      await env.CONTENT_DB.batch([
        env.CONTENT_DB.prepare('DELETE FROM pc_sessions WHERE license=? AND device=?').bind(b.license,b.device.toLowerCase()),
        env.CONTENT_DB.prepare('DELETE FROM pc_devices WHERE license=? AND device=?').bind(b.license,b.device.toLowerCase()),
      ]);return json({ok:true});
    }
    return json({error:'not_found'},404);
  }catch(e){return json({error:e.status?e.message:'content_unavailable'},e.status||503);}
}
