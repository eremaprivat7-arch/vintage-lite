const enc = new TextEncoder();
const hex = data => Array.from(new Uint8Array(data), b => b.toString(16).padStart(2,'0')).join('');
const digest = async value => hex(await crypto.subtle.digest('SHA-256',enc.encode(value)));
const menu = {keyboard:[['Получить бонус','Проверить срок'],['Мой баланс','Мои ключи']],resize_keyboard:true};
const purchaseUnavailable = 'Покупка ключей через бота отключена. Бонус и проверка срока доступны в меню.';
const dayLabel = days => days === 1 ? '1 день' : days === 3 ? '3 дня' : days+' дней';
const escapeHTML = value => String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');

async function saleKey(secret,event){
  const key = await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return 'VL-'+hex(await crypto.subtle.sign('HMAC',key,enc.encode(event))).slice(0,32).toUpperCase();
}

async function purchase(env,uid,days,event,price){
  const key = await saleKey(env.KEY_SECRET,event);
  const hash = await digest(key);
  try {
    await env.DB.prepare(`INSERT INTO shop_orders(event,uid,days,cost,digest)
      SELECT ?,?,days,price,? FROM shop_plans WHERE days=? AND price=?
      ON CONFLICT(event) DO NOTHING`).bind(event,uid,hash,days,price).run();
  } catch(e){
    if(String(e).includes('low_balance')) return {error:'Недостаточно средств.'};
    throw e;
  }
  const order = await env.DB.prepare('SELECT uid,days,cost,digest FROM shop_orders WHERE event=?').bind(event).first();
  if(!order || order.uid!==uid || order.days!==days || order.cost!==price || order.digest!==hash)
    return {error:'Обнови список тарифов или создай новый заказ.'};
  return {key,days,cost:price};
}

async function reward(env,uid,key){
  const hash = await digest(key.toUpperCase());
  const result = await env.DB.prepare(`INSERT INTO shop_bonus(license,uid,hours,cash)
    SELECT l.id,?,p.hours,p.cash FROM licenses l JOIN shop_plans p ON l.lifetime=p.days*86400
    WHERE l.digest=? AND l.seats=1 AND l.revoked=0 AND (l.expires IS NULL OR l.expires>COALESCE((SELECT started FROM patch_mode WHERE id=1),unixepoch()))
    ON CONFLICT(license) DO NOTHING`).bind(uid,hash).run();
  const row = await env.DB.prepare('SELECT b.* FROM shop_bonus b JOIN licenses l ON l.id=b.license WHERE l.digest=?').bind(hash).first();
  if(row?.uid!==uid) return 'Бонус недоступен. Нужен действующий личный ключ одного из пяти тарифов со свободным бонусом.';
  return (result.meta.changes?'Бонус начислен':'Бонус уже получен')+' · +'+row.hours+' ч к ключу и +'+row.cash+' ₸ на баланс.';
}

function keyStatus(row, now){
  if(!row || row.revoked===null) return 'Ключ не найден';
  if(row.revoked) return 'Ключ отозван';
  const clock=row.started ?? now;
  const seconds=row.expires===null ? row.lifetime : row.expires-clock;
  if(seconds<=0) return 'Срок истёк';
  const time=Math.floor(seconds/86400)+' д '+Math.floor(seconds%86400/3600)+' ч '+Math.floor(seconds%3600/60)+' мин '+seconds%60+' с';
  if(row.expires===null) return 'Ещё не активирован · '+time+' с первой активации';
  return (row.started===null?'Осталось: ':'Пауза · осталось: ')+time;
}

async function telegram(env,method,body){
  const r=await fetch('https://api.telegram.org/bot'+env.TELEGRAM_BOT_TOKEN+'/'+method,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  if(!r.ok) throw Error('Telegram '+r.status);
}

const money = amount => new Intl.NumberFormat('ru-RU').format(amount)+' ₸';
const adminMenu = {keyboard:[['🔑 Получить ключ'],...menu.keyboard,['Пополнить баланс','Списать с баланса'],['Статистика магазина','История баланса']],resize_keyboard:true};
const userMenu = {keyboard:[...menu.keyboard,['Моя статистика']],resize_keyboard:true};
const forceReply = {force_reply:true, selective:true};
const amountPattern = /^[1-9]\d{0,7}$/;

async function balance(env,uid){
  const wallet = await env.DB.prepare('SELECT balance FROM shop_wallet WHERE uid=?').bind(uid).first();
  return wallet?.balance ?? 0;
}

async function adjustBalance(env,event,uid,delta){
  try {
    await env.DB.prepare('INSERT INTO shop_adjust(event,uid,delta) VALUES(?,?,?) ON CONFLICT(event) DO NOTHING').bind(event,uid,delta).run();
  } catch(error){
    if(/CHECK/i.test(String(error)+' '+String(error.cause))) return 'Недостаточно средств для списания. На балансе '+money(await balance(env,uid));
    throw error;
  }
  return ['Операция проведена','Telegram ID: '+uid,'Изменение: '+(delta>0?'+':'')+money(delta),'Текущий баланс: '+money(await balance(env,uid))].join('\n');
}

async function statistics(env,uid){
  const where=uid?' WHERE uid=?':'';
  function query(sql){
    const stmt=env.DB.prepare(sql+where);
    return uid?stmt.bind(uid):stmt;
  }
  const [orders,bonuses,adjustments]=await env.DB.batch([
    query('SELECT COUNT(*) AS count, COUNT(DISTINCT uid) AS buyers FROM shop_orders'),
    query('SELECT COALESCE(SUM(cash),0) AS total FROM shop_bonus'),
    query('SELECT COALESCE(SUM(CASE WHEN delta>0 THEN delta ELSE 0 END),0) AS added, COALESCE(SUM(CASE WHEN delta<0 THEN -delta ELSE 0 END),0) AS removed FROM shop_adjust')
  ]);
  const sales=orders.results[0], wallet=adjustments.results[0];
  return [uid?'Моя статистика · за всё время':'Магазин · за всё время',
    'Куплено ключей: '+sales.count,
    ...uid?[]:['Покупателей: '+sales.buyers],
    'Ручные пополнения: '+money(wallet.added),'Ручные списания: '+money(wallet.removed),
    'Начислено бонусов: '+money(bonuses.results[0].total)].join('\n');
}

async function handle(env,u){
  const cb=u.callback_query;
  const msg=cb?.message ?? u.message;
  if(!msg || msg.chat.type!=='private') return;
  const uid=String((cb?.from ?? msg.from).id);
  const ownerID=String(env.ADMIN_ID ?? '').trim();
  const admin=/^[1-9]\d{0,15}$/.test(ownerID) && uid===ownerID;
  const send=(text,reply_markup=admin?adminMenu:userMenu,options={})=>telegram(env,'sendMessage',{...options,chat_id:uid,text,reply_markup});
  async function showOwnerPlans(){
    const {results}=await env.DB.prepare('SELECT days,price FROM shop_plans WHERE price IS NOT NULL ORDER BY days').all();
    const plans=results.filter(p=>[1,3,7,15,30].includes(p.days) && Number.isSafeInteger(p.price) && p.price>0 && p.price<=99999999);
    if(!plans.length) return send('Тарифы пока не настроены.');
    return send('🔑 VINTAGE LITE · ключи владельца\n\nБаланс: '+money(await balance(env,uid))+'\nВыбери срок и цену ключа.',{
      inline_keyboard:plans.map(p=>[{text:dayLabel(p.days)+' · '+money(p.price),callback_data:'buy:'+p.days+':'+p.price}])
    });
  }
  async function sendOwnerKey(result){
    const row=await env.DB.prepare('SELECT expires,lifetime,revoked,(SELECT started FROM patch_mode WHERE id=1) AS started FROM licenses WHERE digest=?').bind(await digest(result.key)).first();
    const inactive=row && !row.revoked && row.expires===null;
    const text=[
      '<b>VINTAGE LITE</b>',
      '🔑 <b>Ключ доступа</b>',
      '',
      '<code>'+escapeHTML(result.key)+'</code>',
      '',
      '🗓 Срок: <b>'+escapeHTML(dayLabel(result.days))+'</b>',
      '⚡ Статус: <b>'+escapeHTML(inactive?'Не активирован':keyStatus(row,Math.floor(Date.now()/1000)))+'</b>',
      '',
      ...(inactive?['<i>Отсчёт начнётся после первой активации.</i>','']:[]),
      'Нажми кнопку ниже, чтобы скопировать ключ.'
    ].join('\n');
    return send(text,{inline_keyboard:[[{text:'📋 Скопировать ключ',copy_text:{text:result.key}}]]},{parse_mode:'HTML'});
  }
  if(cb){
    await telegram(env,'answerCallbackQuery',{callback_query_id:cb.id}).catch(()=>{});
    if(/^buy:/.test(cb.data ?? '')){
      if(admin){
        const selected=/^buy:(1|3|7|15|30):([1-9]\d{0,7})$/.exec(cb.data);
        if(!selected) return send('Открой «🔑 Получить ключ» и выбери актуальный тариф.');
        const result=await purchase(env,uid,Number(selected[1]),'tg:'+uid+':'+msg.message_id,Number(selected[2]));
        if(result.error) return send(result.error);
        await telegram(env,'editMessageReplyMarkup',{
          chat_id:msg.chat.id,message_id:msg.message_id,reply_markup:{inline_keyboard:[]}
        }).catch(()=>{});
        return sendOwnerKey(result);
      }
      // Old catalog messages must not create orders or keep showing tariffs
      // after their buttons are pressed. Refresh the cached reply keyboard too.
      await telegram(env,'editMessageText',{
        chat_id:msg.chat.id,message_id:msg.message_id,text:purchaseUnavailable,
        reply_markup:{inline_keyboard:[]}
      }).catch(()=>{});
      return send(purchaseUnavailable);
    }
    const change=/^adjust:(\d{1,16}):(-?[1-9]\d{0,7})$/.exec(cb.data);
    if(change && admin) return send(await adjustBalance(env,'confirm:'+uid+':'+msg.message_id,change[1],Number(change[2])));
    return;
  }
  const t=(msg.text ?? '').trim();
  const prompt=msg.reply_to_message?.from?.is_bot ? (msg.reply_to_message.text ?? '') : '';
  if(/^(?:🔑\s*)?(Купить ключ|Получить ключ|Цены|Тарифы)$/i.test(t) || /^\/(buy|purchase|prices|price)(?:@\w+)?(?:\s|$)/i.test(t)){
    if(!admin) return send(purchaseUnavailable);
    return showOwnerPlans();
  }
  if(t==='Моя статистика') return send(await statistics(env,uid));
  if(admin && t==='Статистика магазина') return send(await statistics(env,null));
  if(admin && t==='История баланса'){
    const {results}=await env.DB.prepare('SELECT uid,delta FROM shop_adjust ORDER BY rowid DESC LIMIT 15').all();
    return send(results.length?['Последние ручные операции',...results.map(r=>r.uid+' · '+(r.delta>0?'+':'')+money(r.delta))].join('\n'):'Ручных операций пока нет.');
  }
  if(admin && ['Пополнить баланс','Списать с баланса'].includes(t)){
    return send(t+' · введи Telegram ID реселлера',forceReply);
  }
  if(admin && /^(Пополнить баланс|Списать с баланса) · введи Telegram ID реселлера$/.test(prompt)){
    if(!/^[1-9]\d{0,15}$/.test(t)) return send(prompt,forceReply);
    return send(prompt.split(' · ')[0]+' · ID '+t+' · введи сумму в тенге',forceReply);
  }
  const target=/^(Пополнить баланс|Списать с баланса) · ID (\d+) · введи сумму в тенге$/.exec(prompt);
  if(admin && target){
    const digits=t.replace(/\s/g,'');
    if(!amountPattern.test(digits)) return send(prompt,forceReply);
    const delta=Number(digits)*(target[1]==='Пополнить баланс'?1:-1);
    return send(target[1]+' на '+money(Math.abs(delta))+'?\nTelegram ID: '+target[2]+'\nСейчас на балансе: '+money(await balance(env,target[2])),{inline_keyboard:[[{text:'Подтвердить',callback_data:'adjust:'+target[2]+':'+delta}]]});
  }
  const statusPrompt='Ответь на это сообщение ключом VL-…, чтобы проверить оставшееся время.';
  if(t==='Проверить срок') return send(statusPrompt,forceReply);
  if(prompt===statusPrompt){
    if(!/^VL-[0-9a-f]{32}$/i.test(t)) return send(statusPrompt,forceReply);
    const row=await env.DB.prepare('SELECT expires,lifetime,revoked,(SELECT started FROM patch_mode WHERE id=1) AS started FROM licenses WHERE digest=?').bind(await digest(t.toUpperCase())).first();
    return send(keyStatus(row,Math.floor(Date.now()/1000)));
  }
  if(t==='Получить бонус') return send('Пришли личный ключ VL-… в этот чат. Бонус получает первый предъявитель ключа.');
  if(/^VL-[0-9a-f]{32}$/i.test(t)) return send(await reward(env,uid,t));
  if(t==='Мой баланс'){
    const row=await env.DB.prepare('SELECT balance FROM shop_wallet WHERE uid=?').bind(uid).first();
    return send('Баланс '+(row?.balance ?? 0)+' ₸\nТвой ID '+uid);
  }
  if(t==='Мои ключи'){
    const {results}=await env.DB.prepare('SELECT o.event,o.days,l.expires,l.lifetime,l.revoked,(SELECT started FROM patch_mode WHERE id=1) AS started FROM shop_orders o LEFT JOIN licenses l ON l.digest=o.digest WHERE o.uid=? ORDER BY o.rowid DESC LIMIT 20').bind(uid).all();
    const lines=await Promise.all(results.map(async o=>dayLabel(o.days)+' · '+await saleKey(env.KEY_SECRET,o.event)+'\n'+keyStatus(o,Math.floor(Date.now()/1000))));
    return send(lines.join('\n') || 'Покупок пока нет.');
  }
  if(admin){
    const adjust=/^\/balance(?:@\w+)?\s+([1-9]\d{0,15})\s+([+-]?[\d\s]+)(?:\s*₸)?$/i.exec(t);
    if(adjust){
      const delta=Number(adjust[2].replace(/\s/g,''));
      if(Number.isSafeInteger(delta) && delta!==0 && Math.abs(delta)<=99999999)
        return send(await adjustBalance(env,String(u.update_id),adjust[1],delta));
    }
    if(/^\/balance/i.test(t)) return send('Нажми «Пополнить баланс» или введи /balance 123456789 +1000');
  }
  if(!admin && /^\/(?:admin|balance)/i.test(t))
    return send('Для этого действия нужен администратор. Твой Telegram ID: '+uid+'. Владелец может сверить его с ADMIN_ID в Cloudflare.');
  return send('Vintage Lite\nБаланс: '+money(await balance(env,uid))+'\nТвой Telegram ID: '+uid+'\n'+(admin?'Меню владельца. Для ключа нажми «🔑 Получить ключ».':'Для бонуса пришли свой личный ключ. Для проверки нажми «Проверить срок».'));
}

export default {async fetch(req,env){
  const path=new URL(req.url).pathname;
  if(req.method!=='POST') return new Response(null,{status:405});
  if(!env.KEY_SECRET) return new Response(null,{status:503});
  if(path==='/api/purchase'){
    if(!env.API_TOKEN || req.headers.get('Authorization')!=='Bearer '+env.API_TOKEN) return new Response(null,{status:403});
    const b=await req.json().catch(()=>null);
    if(!b || !/^\d{1,16}$/.test(String(b.uid)) || !/^[\w-]{1,80}$/.test(b.order_id ?? '') || typeof b.order_id!=='string' || !Number.isSafeInteger(b.price) || ![1,3,7,15,30].includes(b.days)) return new Response(null,{status:400});
    const out=await purchase(env,String(b.uid),b.days,'api:'+b.uid+':'+b.order_id,b.price);
    return Response.json(out,{status:out.error?409:200,headers:{'Cache-Control':'no-store'}});
  }
  if(path!=='/telegram' || !env.WEBHOOK_SECRET || req.headers.get('X-Telegram-Bot-Api-Secret-Token')!==env.WEBHOOK_SECRET) return new Response(null,{status:403});
  await handle(env,await req.json());
  return new Response('ok');
}};
