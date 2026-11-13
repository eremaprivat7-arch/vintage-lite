import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import {privateContent,manageContent,boundedJSON,limitAdminLogin} from '../license-server/src/private-content.js';
import worker from '../license-server/src/index.js';
import {recordRelease,releaseList,saveRelease} from '../license-server/src/releases.js';
const base=new DatabaseSync(':memory:'),content=new DatabaseSync(':memory:');
content.exec('PRAGMA foreign_keys=ON');
base.exec(readFileSync(new URL('../license-server/migrations/0001_init.sql',import.meta.url),'utf8'));
base.exec(readFileSync(new URL('../license-server/migrations/0002_patch_mode.sql',import.meta.url),'utf8'));
base.exec(readFileSync(new URL('../license-server/migrations/0006_app_releases.sql',import.meta.url),'utf8'));
base.exec(readFileSync(new URL('../license-server/migrations/0007_release_discovery.sql',import.meta.url),'utf8'));
content.exec(readFileSync(new URL('../license-server/private-content/schema.sql',import.meta.url),'utf8'));
const encoder=new TextEncoder(),td=new TextDecoder();
const hex=x=>Buffer.from(x).toString('hex'),b64=x=>Buffer.from(x).toString('base64');
const hash=x=>crypto.subtle.digest('SHA-256',typeof x==='string'?encoder.encode(x):x).then(hex);
const rawKey='VL-0123456789ABCDEF0123456789ABCDEF',device='11111111-1111-4111-8111-111111111111';
const stamp=()=>Math.floor(Date.now()/1000);
base.prepare('INSERT INTO licenses(digest,label,seats,lifetime,expires,created) VALUES(?,?,1,604800,?,?)').run(await hash(rawKey),'old-key',stamp()+604800,stamp()-1000);
base.prepare('INSERT INTO devices VALUES(1,?,0)').run(device);
base.exec("CREATE TABLE existing_balances(uid TEXT,balance INTEGER); INSERT INTO existing_balances VALUES('123',5000)");
const snapshot=()=>JSON.stringify(['licenses','devices','existing_balances'].map(t=>base.prepare('SELECT * FROM '+t).all()));
const original=snapshot();
function binding(database,readOnly=false){
  const d1row=row=>row?Object.fromEntries(Object.entries(row).map(([name,value])=>[name,ArrayBuffer.isView(value)?Array.from(value):value])):null;
  function prepare(sql,args=[]){
    if(readOnly&&!/^\s*SELECT\b/i.test(sql))throw Error('Licensing DB write attempted: '+sql);
    const values=()=>args.map(a=>a instanceof ArrayBuffer?new Uint8Array(a):a);
    return {sql,bind:(...p)=>prepare(sql,p),first:async()=>d1row(database.prepare(sql).get(...values())),
      all:async()=>({results:database.prepare(sql).all(...values()).map(d1row)}),
      run:async()=>({meta:database.prepare(sql).run(...values())})};
  }
  return {prepare,batch:async statements=>{database.exec('BEGIN');try{const results=[];for(const s of statements)results.push(/^\s*SELECT\b/i.test(s.sql)?await s.all():await s.run());database.exec('COMMIT');return results;}catch(e){database.exec('ROLLBACK');throw e;}}};
}
const env={DB:binding(base,true),CONTENT_DB:binding(content),CONTENT_MASTER_KEY:b64(crypto.getRandomValues(new Uint8Array(32)))};
const signing=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const agreement=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},true,['deriveBits']);
const identity={key:rawKey,device,app_version:'2.1.0',app_build:'10',signing:b64(await crypto.subtle.exportKey('raw',signing.publicKey)),agreement:b64(await crypto.subtle.exportKey('raw',agreement.publicKey))};
async function request(path,body,token='',options={}){
  const raw=JSON.stringify(body),time=String(options.time??stamp()),nonce=options.nonce??crypto.randomUUID();
  const message=['VL1','POST',path,nonce,time,await hash(token),await hash(raw)].join('\n');
  const signature=await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},options.key??signing.privateKey,encoder.encode(message));
  return new Request('https://example.test'+path,{method:'POST',body:raw,headers:{'Content-Type':'application/json','CF-Connecting-IP':'192.0.2.1','X-VL-Nonce':nonce,'X-VL-Time':time,'X-VL-Signature':b64(signature),...(token?{Authorization:'Bearer '+token}:{})}});
}
const call=req=>privateContent(req,env,new URL(req.url));
const admin=async(path,body)=>manageContent(new Request('https://example.test'+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}),env,new URL('https://example.test'+path));
const sessionResponse=await call(await request('/api/content/session',identity));
assert.equal(sessionResponse.status,200);
const lease=await sessionResponse.json();
const asset=crypto.randomUUID(),packageID=crypto.randomUUID(),key=crypto.getRandomValues(new Uint8Array(32));
const data=encoder.encode('private-package-not-in-ipa'.repeat(50000));
const iv=crypto.getRandomValues(new Uint8Array(12));
const cipher=new Uint8Array(12+data.length+16);cipher.set(iv);
cipher.set(new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode('VL-content-v1:'+asset)},await crypto.subtle.importKey('raw',key,'AES-GCM',false,['encrypt']),data)),12);
const revision=await hash(cipher);
const PART=262144,hashes=[];
for(let start=0;start<cipher.length;start+=PART)hashes.push(await hash(cipher.subarray(start,start+PART)));
const meta={id:asset,package_id:packageID,revision,title:'Private test',category:'Boost',size:cipher.length,parts:Math.ceil(cipher.length/PART),key:b64(key),hashes};
assert.equal((await admin('/admin/api/content/begin',meta)).status,200);
assert.equal((await admin('/admin/api/content/commit',{id:asset,revision})).status,409,'partial uploads cannot publish');
assert.equal((await admin('/admin/api/content/chunk',{id:asset,revision,part:0,data:b64(new Uint8Array(PART))})).status,409,'modified upload piece rejected');
for(let part=0;part<meta.parts;part++)assert.equal((await admin('/admin/api/content/chunk',{id:asset,revision,part,data:b64(cipher.subarray(part*PART,(part+1)*PART))})).status,200);
assert.equal((await admin('/admin/api/content/commit',{id:asset,revision})).status,200);
assert.equal((await admin('/admin/api/content/chunk',{id:asset,revision,part:0,data:b64(cipher.subarray(0,PART))})).status,409,'published objects are immutable');
const catalogRequest=await request('/api/content/catalog',{},lease.token);
const replay=catalogRequest.clone();
const catalog=await call(catalogRequest);assert.equal(catalog.status,200);
assert.equal((await catalog.json()).assets[0].id,asset);
assert.equal((await call(replay)).status,409,'proof cannot be replayed');
const delivery=await call(await request('/api/content/package',{id:asset},lease.token));assert.equal(delivery.status,200);
assert.match(delivery.headers.get('Cache-Control'),/no-store/);
const wrapped=JSON.parse(Buffer.from(delivery.headers.get('X-VL-Key'),'base64').toString('utf8'));
const pub=await crypto.subtle.importKey('raw',Buffer.from(wrapped.public_key,'base64'),{name:'ECDH',namedCurve:'P-256'},false,[]);
const shared=await crypto.subtle.deriveBits({name:'ECDH',public:pub},agreement.privateKey,256);
const material=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveKey']);
const info=encoder.encode('VL-wrap-v1:'+asset+':'+revision);
const unwrap=await crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:Buffer.from(wrapped.salt,'base64'),info},material,{name:'AES-GCM',length:256},false,['decrypt']);
const w=Buffer.from(wrapped.key,'base64');
const received=await crypto.subtle.decrypt({name:'AES-GCM',iv:w.subarray(0,12),additionalData:info},unwrap,w.subarray(12));
assert.equal(hex(received),hex(key));
assert.equal((await delivery.arrayBuffer()).byteLength,0,'grant has no bulk payload');
const returned=new Uint8Array(wrapped.size);let receivedOffset=0;
for(let part=0;part<wrapped.parts;part++){
 const piece=await call(await request('/api/content/chunk',{id:asset,revision,part:String(part)},lease.token));assert.equal(piece.status,200);
 const bytes=new Uint8Array(await piece.arrayBuffer());assert.ok(bytes.length<=PART);
 assert.equal(piece.headers.get('X-VL-Part-SHA256'),await hash(bytes));returned.set(bytes,receivedOffset);receivedOffset+=bytes.length;
}
assert.equal(await hash(returned),revision);
const clear=await crypto.subtle.decrypt({name:'AES-GCM',iv:returned.subarray(0,12),additionalData:encoder.encode('VL-content-v1:'+asset)},await crypto.subtle.importKey('raw',received,'AES-GCM',false,['decrypt']),returned.subarray(12));
assert.equal(td.decode(clear),td.decode(data),'only the bound ECDH recipient unwraps the package key');
const attacker=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
assert.equal((await call(await request('/api/content/package',{id:asset},lease.token,{key:attacker.privateKey}))).status,403,'stolen token without private device key denied');
const changed={...identity,signing:b64(await crypto.subtle.exportKey('raw',attacker.publicKey))};
assert.equal((await call(await request('/api/content/session',changed,'',{key:attacker.privateKey}))).status,403,'copied UUID cannot replace registered device key');
assert.equal((await call(await request('/api/content/catalog',{},lease.token,{time:stamp()-1000}))).status,409,'stale proof denied');
base.prepare('UPDATE devices SET blocked=1 WHERE license=1').run();
assert.equal((await call(await request('/api/content/package',{id:asset},lease.token))).status,403,'revocation enforced during live session');
assert.equal((await call(await request('/api/content/chunk',{id:asset,revision,part:'0'},lease.token))).status,403,'revocation enforced for every file piece');
base.prepare('UPDATE devices SET blocked=0 WHERE license=1').run();
base.exec('UPDATE patch_mode SET started=unixepoch() WHERE id=1');
assert.equal((await call(await request('/api/content/package',{id:asset},lease.token))).status,503,'maintenance enforced');
base.exec('UPDATE patch_mode SET started=NULL WHERE id=1');
base.exec("INSERT INTO app_releases(version,build,blocked) VALUES('2.1.0','10',1)");
assert.equal((await call(await request('/api/content/package',{id:asset},lease.token))).status,503,'release block enforced');
base.exec("DELETE FROM app_releases WHERE version='2.1.0'");
assert.equal(snapshot(),original,'existing licenses, bindings, expiry and balances unchanged');
const rawEnv={...env,DB:binding(base),ADMIN_PASSWORD:'only-for-tests',SESSION_SECRET:'test-secret-that-is-longer-than-thirty-two-characters'};
const statusFor=async(version,build)=>worker.fetch(
  new Request('https://example.test/api/status?'+new URLSearchParams({app_version:version,app_build:build})),rawEnv);
const seeded=await releaseList(rawEnv);
assert.ok(seeded.releases.some(r=>r.version==='2.2.5'&&r.build==='16'),'2.2.5 is present before a client reconnects');
assert.ok(seeded.releases.some(r=>r.version==='2.2.6'&&r.build==='17'),'the hotfix is present in the admin catalog');
for(const [version,build] of [['2.2.5','16'],['2.2.6','17']]){
  assert.equal((await saveRelease(rawEnv,{version,build,blocked:true})).ok,true);
  await recordRelease(rawEnv,{version,build});
  base.exec(readFileSync(new URL('../license-server/migrations/0007_release_discovery.sql',import.meta.url),'utf8'));
  assert.equal((await (await statusFor(version,build)).json()).update_required,true,'discovery and migration never reopen a blocked release');
  assert.notEqual((await (await statusFor('2.2.4','15')).json()).update_required,true,'the release block leaves older versions enabled');
  const checked=await worker.fetch(new Request('https://example.test/api/check',{
    method:'POST',body:JSON.stringify({key:rawKey,device,app_version:version,app_build:build})}),rawEnv);
  assert.equal(checked.status,503,'per-release patch mode blocks the selected build');
  assert.equal((await saveRelease(rawEnv,{version,build,blocked:false})).ok,true);
  assert.notEqual((await (await statusFor(version,build)).json()).update_required,true,'the admin can reopen a release');
}
base.exec('UPDATE patch_mode SET started=unixepoch() WHERE id=1');
assert.equal((await (await statusFor('2.2.5','16')).json()).maintenance,true,'global patch mode also covers the new build');
base.exec('UPDATE patch_mode SET started=NULL WHERE id=1');
assert.notEqual((await (await statusFor('2.2.5','16')).json()).maintenance,true,'the new build resumes when patch mode ends');
const unauth=new Request('https://example.test/admin/api/content/status');
assert.equal((await worker.fetch(unauth,rawEnv)).status,401,'owner uploads are not public');
const oldCheck=await worker.fetch(new Request('https://example.test/api/check',{method:'POST',body:JSON.stringify({key:rawKey,device,app_version:'2.0.0',app_build:'9'})}),rawEnv);
assert.equal(oldCheck.status,200,'legacy app still validates existing key');
assert.equal((await oldCheck.json()).valid,true);
assert.equal(base.prepare('SELECT blocked FROM app_releases WHERE version=? AND build=?').get('2.0.0','9').blocked,0,'successful key validation discovers a release');
const rejectedVersion=await worker.fetch(new Request('https://example.test/api/check',{method:'POST',body:JSON.stringify({key:'VL-INVALID-INVALID',device,app_version:'2.9.9',app_build:'99'})}),rawEnv);
assert.equal(rejectedVersion.status,403);
assert.equal(base.prepare('SELECT COUNT(*) AS count FROM app_releases WHERE version=?').get('2.9.9').count,0,'invalid keys cannot populate the release list');
await recordRelease(rawEnv,{version:'2.2.10',build:'21'});
const ordered=(await releaseList(rawEnv)).releases;
assert.ok(ordered.findIndex(r=>r.version==='2.2.10')<ordered.findIndex(r=>r.version==='2.2.6'),'versions use numeric ordering');
assert.equal(ordered.at(-1).version,'legacy','the legacy group stays after numbered releases');
await statusFor('2.8.8','88');
assert.equal(base.prepare('SELECT COUNT(*) AS count FROM app_releases WHERE version=?').get('2.8.8').count,0,'public status probes do not register versions');
assert.equal(snapshot(),original);
await assert.rejects(boundedJSON(new Request('https://example.test',{method:'POST',body:'x'.repeat(5000)})),/too_large/);
for(let i=0;i<10;i++)await limitAdminLogin(new Request('https://example.test',{headers:{'CF-Connecting-IP':'192.0.2.99'}}),env);
await assert.rejects(limitAdminLogin(new Request('https://example.test',{headers:{'CF-Connecting-IP':'192.0.2.99'}}),env),/rate_limited/);
console.log('PASS device proof, encrypted delivery, replay denial, binding, revocation, release/patch blocks, admin authorization, rate limits, input limits, legacy license/data preservation');
