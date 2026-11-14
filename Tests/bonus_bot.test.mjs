import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '../reseller-bot/worker.js';
import { manage } from '../license-server/src/reseller.js';
import licenseWorker from '../license-server/src/index.js';

const sqlite = new DatabaseSync(':memory:');
for (const file of ['../license-server/migrations/0001_init.sql', '../license-server/migrations/0002_patch_mode.sql', '../license-server/migrations/0003_reseller_api.sql', '../reseller-bot/schema.sql', '../license-server/migrations/0004_dashboard.sql', '../license-server/migrations/0005_reseller_profiles.sql', '../license-server/migrations/0011_bot_only_resellers.sql']) {
  sqlite.exec(readFileSync(new URL(file, import.meta.url), 'utf8'));
}
let beforeOrderWrite;
class Statement {
  constructor(sql, values = []) { this.sql = sql; this.values = values; }
  bind(...values) { return new Statement(this.sql, values); }
  async first() { return sqlite.prepare(this.sql).get(...this.values) ?? null; }
  async all() { return { results: sqlite.prepare(this.sql).all(...this.values) }; }
  async run() {
    if (beforeOrderWrite && this.sql.includes('INSERT INTO shop_orders')) {
      const callback = beforeOrderWrite; beforeOrderWrite = undefined; await callback();
    }
    return { meta: { changes: Number(sqlite.prepare(this.sql).run(...this.values).changes) } };
  }
}
const env = {
  DB: { prepare: sql => new Statement(sql), batch: statements => Promise.all(statements.map(statement => statement.all())) },
  TELEGRAM_BOT_TOKEN: 'fixture-only-token', ADMIN_ID: '777',
  WEBHOOK_SECRET: 'fixture-only-webhook', KEY_SECRET: 'fixture-only-key-secret', API_TOKEN: 'fixture-only-api-token',
  SESSION_SECRET: 'fixture-only-session-secret-for-token-vault', ADMIN_PASSWORD: 'fixture-only-admin-password'
};
const user = '123';
sqlite.prepare('INSERT INTO shop_wallet(uid,balance) VALUES(?,?)').run(user, 1000);
sqlite.prepare('INSERT INTO shop_wallet(uid,balance) VALUES(?,?)').run(env.ADMIN_ID, 1000);
const key = 'VL-' + 'A'.repeat(32);
const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key))), byte => byte.toString(16).padStart(2, '0')).join('');
sqlite.prepare('INSERT INTO licenses(digest,label,seats,lifetime,created) VALUES(?,?,?,?,unixepoch())').run(hash, 'fixture', 1, 86400);
const calls = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, options) => {
  assert.ok(String(url).startsWith('https://api.telegram.org/botfixture-only-token/'), 'no external API is called during this test');
  calls.push({ method: String(url).split('/').at(-1), body: JSON.parse(options.body) });
  return Response.json({ ok: true, result: {} });
};
let updateID = 0;
async function telegram(update, runtime = env) {
  const start = calls.length;
  const response = await worker.fetch(new Request('https://fixture.test/telegram', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Telegram-Bot-Api-Secret-Token': env.WEBHOOK_SECRET },
    body: JSON.stringify({ update_id: ++updateID, ...update })
  }), runtime);
  assert.equal(response.status, 200);
  return calls.slice(start);
}
const message = (text, uid = user, extra = {}) => telegram({ message: {
  message_id: 10, chat: { id: Number(uid), type: 'private' }, from: { id: Number(uid) }, text, ...extra
} });
const wallet = () => sqlite.prepare('SELECT balance FROM shop_wallet WHERE uid=?').get(user).balance;
const orders = () => sqlite.prepare('SELECT COUNT(*) AS count FROM shop_orders').get().count;
function noPrices(out) {
  for (const call of out) {
    assert.doesNotMatch(JSON.stringify(call.body), /Купить ключ|Сумма покупок|закупка|розница|доход|(?:250|700|1500|3500|5000)\s*₸/i);
  }
}

try {
  for (const uid of [user]) {
    const start = await message('/start', uid);
    noPrices(start);
    const menu = start.find(call => call.method === 'sendMessage').body.reply_markup.keyboard.flat();
    assert.ok(menu.includes('Получить бонус') && menu.includes('Проверить срок'));
    assert.ok(!menu.some(label => label.includes('Получить ключ')));
    for (const command of ['Купить ключ', 'Получить ключ', '🔑 Получить ключ', 'Цены', 'Тарифы', '/buy', '/purchase', '/prices@vintagelite_bot', '/price 1 222']) {
      const out = await message(command, uid);
      noPrices(out);
      assert.match(out.find(call => call.method === 'sendMessage').body.text, /добавленным администратором/);
    }
    const oldButton = await telegram({ callback_query: {
      id: 'fixture-callback', from: { id: Number(uid) }, data: 'buy:1:150',
      message: { message_id: 7, chat: { id: Number(uid), type: 'private' }, text: '1 день · 150 ₸' }
    } });
    noPrices(oldButton);
    const edited = oldButton.find(call => call.method === 'editMessageText');
    assert.equal(edited.body.message_id, 7, 'old catalog text is replaced when its button is pressed');
    assert.deepEqual(edited.body.reply_markup.inline_keyboard, []);
  }
  assert.equal(wallet(), 1000, 'blocked Telegram purchases cannot debit the wallet');
  assert.equal(orders(), 0, 'old callbacks cannot create orders');
  assert.equal(sqlite.prepare('SELECT price FROM shop_plans WHERE days=1').get().price, 150, 'disabled price commands cannot change API tariffs');

  const owner = env.ADMIN_ID;
  const ownerWallet = () => sqlite.prepare('SELECT balance FROM shop_wallet WHERE uid=?').get(owner).balance;
  const ownerMenu = (await message('/start', owner)).find(call => call.method === 'sendMessage').body.reply_markup.keyboard.flat();
  assert.ok(ownerMenu.includes('🔑 Получить ключ'));
  for (const command of ['🔑 Получить ключ', 'Купить ключ', '/buy@vintagelite_bot', '/price 1 222']) {
    const catalog = (await message(command, owner)).find(call => call.method === 'sendMessage').body;
    assert.equal(catalog.chat_id, owner);
    assert.equal(catalog.reply_markup.inline_keyboard.length, 5);
    assert.deepEqual(catalog.reply_markup.inline_keyboard.map(row => row[0].callback_data), ['buy:1:250', 'buy:3:700', 'buy:7:1500', 'buy:15:3500', 'buy:30:5000']);
    assert.match(catalog.reply_markup.inline_keyboard[0][0].text, /250/);
    assert.doesNotMatch(catalog.text, /розница|закупка|доход/i);
  }
  assert.equal(orders(), 0, 'opening the owner catalog does not purchase a key');
  assert.equal(sqlite.prepare('SELECT price FROM shop_plans WHERE days=1').get().price, 150);
  const ownerButton = (data = 'buy:1:250', messageID = 70, runtime = env) => telegram({ callback_query: {
    id: 'owner-fixture-callback', from: { id: Number(owner) }, data,
    message: { message_id: messageID, chat: { id: Number(owner), type: 'private' } }
  } }, runtime);
  const issued = await ownerButton();
  const card = issued.find(call => call.method === 'sendMessage').body;
  assert.equal(card.chat_id, owner);
  assert.equal(card.parse_mode, 'HTML');
  assert.match(card.text, /<b>VINTAGE LITE<\/b>/);
  const issuedKey = /<code>(VL-[A-F0-9]{32})<\/code>/.exec(card.text)?.[1];
  assert.ok(issuedKey, 'the key is separate and copyable');
  assert.doesNotMatch(card.text, /списано|стоимость|250\s*₸/i);
  assert.match(card.text, /1 день/);
  assert.deepEqual(card.reply_markup.inline_keyboard[0][0].copy_text, { text: issuedKey });
  assert.deepEqual(issued.find(call => call.method === 'editMessageReplyMarkup').body.reply_markup.inline_keyboard, []);
  assert.equal(ownerWallet(), 750, 'the requested Telegram rate is charged');
  assert.equal(wallet(), 1000, 'the owner purchase cannot charge someone else');
  assert.equal(orders(), 1);
  const repeatedCard = (await ownerButton()).find(call => call.method === 'sendMessage').body;
  assert.match(repeatedCard.text, new RegExp(issuedKey));
  assert.equal(ownerWallet(), 750, 'repeated owner callbacks cannot debit twice');
  assert.equal(orders(), 1);
  for (const data of ['buy:1:1', 'buy:1:150', 'buy:1:0', 'buy:1:-1', 'buy:60:250', 'buy:30:5000']) {
    const rejected = await ownerButton(data, 71);
    assert.ok(!rejected.some(call => call.body.parse_mode === 'HTML'), data);
    assert.equal(orders(), 1, 'forged prices, unsupported plans and insufficient funds cannot create an order');
    assert.equal(ownerWallet(), 750);
  }
  const missingOwner = await ownerButton('buy:1:250', 72, { ...env, ADMIN_ID: '' });
  noPrices(missingOwner);
  assert.equal(orders(), 1, 'an unset ADMIN_ID denies purchase');
  const newCard = (await ownerButton('buy:3:700', 73)).find(call => call.method === 'sendMessage').body;
  assert.match(newCard.text, /3 дня/);
  assert.ok(!newCard.text.includes(issuedKey), 'a new catalog message creates a separate order');
  assert.equal(orders(), 2);
  assert.equal(ownerWallet(), 50);

  const resellerID = '456';
  const apiPrices = { 1: 75, 3: 225, 7: 500, 15: 1750, 30: 2500 };
  sqlite.prepare('INSERT INTO shop_wallet(uid,balance) VALUES(?,?)').run(resellerID, 6000);
  const resellerWallet = () => sqlite.prepare('SELECT balance FROM shop_wallet WHERE uid=?').get(resellerID).balance;
  const resellerButton = (messageID = 80) => telegram({ callback_query: {
    id: 'reseller-callback', from: { id: Number(resellerID) }, data: 'buy:30:5000',
    message: { message_id: messageID, chat: { id: Number(resellerID), type: 'private' } }
  } });
  const resellerAdminAction = async action => {
    const response = await manage(new Request('https://fixture.test/admin/reseller', {
      method: 'POST', body: JSON.stringify({ uid: resellerID, action, name: 'Fixture reseller', prices: apiPrices })
    }), env);
    assert.equal(response.status, 200, 'the real admin handler updates reseller access');
    return response.json();
  };
  noPrices(await message('🔑 Получить ключ', resellerID));
  noPrices(await resellerButton());
  assert.equal(resellerWallet(), 6000, 'a wallet alone does not grant reseller access');
  assert.equal(orders(), 2);
  await resellerAdminAction('create');
  noPrices(await message('/buy', resellerID));
  noPrices(await resellerButton());
  assert.equal(orders(), 2, 'an API token does not grant Telegram purchase access');

  // Exercise the actual protected admin route, not a handler without its auth wrapper.
  const adminURL = 'https://fixture.test/admin/api/bot-resellers';
  const adminHeaders = { 'Content-Type': 'application/json', 'X-Requested-With': 'vintage-admin', Origin: 'https://fixture.test' };
  const login = await licenseWorker.fetch(new Request('https://fixture.test/admin/api/login', {
    method: 'POST', headers: adminHeaders, body: JSON.stringify({ password: env.ADMIN_PASSWORD })
  }), env);
  assert.equal(login.status, 200);
  const cookie = login.headers.get('Set-Cookie').split(';')[0];
  const botAdmin = (body, options = {}) => licenseWorker.fetch(new Request(adminURL, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { ...adminHeaders, Cookie: cookie, ...options.headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), ...options
  }), env);
  for (const method of ['GET', 'POST']) {
    assert.equal((await licenseWorker.fetch(new Request(adminURL, { method }), env)).status, 401);
  }
  assert.equal((await botAdmin({ uid: resellerID }, { headers: { Cookie: cookie } })).status, 403, 'mutation requires the admin request header');
  assert.equal((await botAdmin({ uid: resellerID }, { headers: { ...adminHeaders, Cookie: cookie, Origin: 'https://foreign.test' } })).status, 403, 'cross-origin mutation denied');
  assert.equal((await botAdmin(undefined, { method: 'DELETE' })).status, 405);
  for (const bad of [null, [], {}, { uid: 123 }, { uid: '0' }, { uid: '-12' }, { uid: '1'.repeat(17) }, { uid: '12x' }, { uid: '123', action: 'issue' }]) {
    assert.equal((await botAdmin(bad)).status, 400);
  }
  assert.equal((await botAdmin({ uid: resellerID, junk: 'x'.repeat(5000) })).status, 400);
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS n FROM bot_resellers').get().n, 0, 'unauthorized or invalid requests do not add users');
  const apiSnapshot = () => JSON.stringify(['reseller_access', 'portal_tokens', 'portal_names'].map(table => sqlite.prepare('SELECT * FROM '+table+' ORDER BY uid').all()));
  const apiBeforeAdd = apiSnapshot();
  const botAdminAction = async (action, uid = resellerID) => {
    const response = await botAdmin({ uid, action });
    assert.equal(response.status, 200);
    return response.json();
  };
  await botAdminAction('add');
  await botAdminAction('add');
  assert.equal(apiSnapshot(), apiBeforeAdd, 'adding by Telegram ID neither issues nor edits an API token or API prices');
  assert.equal(resellerWallet(), 6000, 'duplicate add preserves the existing wallet');
  assert.equal((await (await botAdmin()).json()).items[0].uid, resellerID);
  const resellerStart = (await message('/start', resellerID)).find(call => call.method === 'sendMessage').body;
  const resellerKeyboard = resellerStart.reply_markup.keyboard.flat();
  assert.ok(resellerKeyboard.includes('🔑 Получить ключ'));
  assert.ok(!resellerKeyboard.includes('Пополнить баланс'), 'reseller access does not grant owner controls');
  const resellerPlans = (await message('🔑 Получить ключ', resellerID)).find(call => call.method === 'sendMessage').body;
  assert.deepEqual(resellerPlans.reply_markup.inline_keyboard.map(row => row[0].callback_data), ['buy:1:250', 'buy:3:700', 'buy:7:1500', 'buy:15:3500', 'buy:30:5000']);
  const resellerCard = (await resellerButton()).find(call => call.method === 'sendMessage').body;
  assert.equal(resellerCard.chat_id, resellerID);
  assert.equal(resellerCard.parse_mode, 'HTML');
  assert.match(resellerCard.text, /30 дней/);
  assert.doesNotMatch(resellerCard.text, /списано|стоимость|5000\s*₸/i);
  assert.ok(resellerCard.reply_markup.inline_keyboard[0][0].copy_text.text.startsWith('VL-'));
  assert.equal(resellerWallet(), 1000);
  assert.equal(ownerWallet(), 50, 'reseller purchases debit only the reseller');
  const resellerOrders = orders();
  await resellerButton();
  assert.equal(resellerWallet(), 1000);
  assert.equal(orders(), resellerOrders);
  await resellerAdminAction('revoke');
  assert.ok((await message('/buy', resellerID)).some(call => call.body.reply_markup?.inline_keyboard?.length === 5), 'API revocation does not disable bot access');
  await resellerAdminAction('delete');
  assert.ok((await message('/buy', resellerID)).some(call => call.body.reply_markup?.inline_keyboard?.length === 5), 'API deletion does not disable bot access');
  await resellerAdminAction('issue');
  const apiBeforeRemove = apiSnapshot();
  await botAdminAction('remove');
  noPrices(await message('🔑 Получить ключ', resellerID));
  noPrices(await resellerButton(81));
  assert.equal(resellerWallet(), 1000);
  assert.equal(orders(), resellerOrders);
  assert.equal(apiSnapshot(), apiBeforeRemove, 'removing bot permission leaves API token, prices and profile intact');
  const { token: apiToken } = await resellerAdminAction('issue');
  noPrices(await message('/buy', resellerID));
  assert.equal(sqlite.prepare('SELECT enabled FROM bot_resellers WHERE uid=?').get(resellerID).enabled, 0, 'reissuing an API token cannot restore bot permission');
  await botAdminAction('add');
  beforeOrderWrite = () => botAdminAction('remove');
  const raced = await telegram({ callback_query: {
    id: 'revocation-race', from: { id: Number(resellerID) }, data: 'buy:1:250',
    message: { message_id: 82, chat: { id: Number(resellerID), type: 'private' } }
  } });
  assert.ok(!raced.some(call => call.body.parse_mode === 'HTML'));
  assert.equal(resellerWallet(), 1000, 'revocation between the menu check and insert prevents debit');
  assert.equal(orders(), resellerOrders);
  assert.equal(sqlite.prepare('SELECT prices FROM reseller_access WHERE uid=?').get(resellerID).prices, JSON.stringify(apiPrices), 'Telegram rates do not rewrite individual API prices');
  assert.equal(sqlite.prepare('SELECT price FROM shop_plans WHERE days=1').get().price, 150, 'legacy API plan prices are preserved');

  const botOnlyID = '789';
  await botAdminAction('add', botOnlyID);
  assert.equal(sqlite.prepare('SELECT balance FROM shop_wallet WHERE uid=?').get(botOnlyID).balance, 0);
  assert.equal(sqlite.prepare('SELECT * FROM reseller_access WHERE uid=?').get(botOnlyID), undefined);
  assert.equal(sqlite.prepare('SELECT * FROM portal_tokens WHERE uid=?').get(botOnlyID), undefined);
  await message('/balance '+botOnlyID+' +3000', owner);
  const botOnlyCard = (await telegram({ callback_query: {
    id: 'bot-only-purchase', from: { id: Number(botOnlyID) }, data: 'buy:7:1500',
    message: { message_id: 90, chat: { id: Number(botOnlyID), type: 'private' } }
  } })).find(call => call.body.parse_mode === 'HTML').body;
  assert.match(botOnlyCard.text, /7 дней/);
  assert.equal(sqlite.prepare('SELECT balance FROM shop_wallet WHERE uid=?').get(botOnlyID).balance, 1500, 'bot-only reseller can buy after a normal owner top-up');
  assert.equal(sqlite.prepare('SELECT * FROM reseller_access WHERE uid=?').get(botOnlyID), undefined, 'bot purchases do not silently issue API access');
  assert.equal(sqlite.prepare('SELECT * FROM portal_tokens WHERE uid=?').get(botOnlyID), undefined);
  assert.equal(sqlite.prepare('SELECT * FROM portal_names WHERE uid=?').get(botOnlyID), undefined);
  const beforeMigration = apiSnapshot();
  sqlite.exec(readFileSync(new URL('../license-server/migrations/0011_bot_only_resellers.sql', import.meta.url), 'utf8'));
  assert.equal(apiSnapshot(), beforeMigration, 'rerunning the migration preserves all API settings');
  assert.equal(sqlite.prepare('SELECT enabled FROM bot_resellers WHERE uid=?').get(resellerID).enabled, 0, 'rerunning the migration does not reapprove removed users');
  assert.equal(sqlite.prepare('SELECT COUNT(*) AS n FROM bot_resellers').get().n, 2, 'migration never copies API users into bot access');

  const apiRequest = (path, payload) => licenseWorker.fetch(new Request('https://fixture.test/reseller/api/'+path, {
    method: payload ? 'POST' : 'GET', headers: { Authorization: 'Bearer '+apiToken },
    ...(payload ? { body: JSON.stringify(payload) } : {})
  }), env);
  const apiAccount = await (await apiRequest('account')).json();
  assert.deepEqual(apiAccount.prices, apiPrices, 'the same API token still exposes the original individual rates');
  const apiPayload = { order_id: 'after-bot-removal', days: 1, price: 75 };
  const apiKey = await (await apiRequest('purchase', apiPayload)).json();
  assert.equal(apiKey.cost, 75);
  assert.match(apiKey.key, /^VL-[A-F0-9]{32}$/);
  assert.equal(resellerWallet(), 925, 'API purchase still works at its old rate after bot permission is removed');
  assert.equal((await (await apiRequest('purchase', apiPayload)).json()).key, apiKey.key);
  assert.equal(resellerWallet(), 925, 'API order retries do not debit twice');

  const legacyUID = '555';
  const legacyEvent = 'tg:' + legacyUID + ':60';
  const hmac = await crypto.subtle.importKey('raw', new TextEncoder().encode(env.KEY_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const hex = bytes => Buffer.from(bytes).toString('hex');
  const legacyKey = 'VL-' + hex(await crypto.subtle.sign('HMAC', hmac, new TextEncoder().encode(legacyEvent))).slice(0, 32).toUpperCase();
  const legacyHash = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(legacyKey)));
  sqlite.prepare('INSERT INTO shop_wallet(uid,balance) VALUES(?,?)').run(legacyUID, 1000);
  sqlite.prepare('INSERT INTO shop_orders(event,uid,days,cost,digest) VALUES(?,?,?,?,?)').run(legacyEvent, legacyUID, 1, 150, legacyHash);
  const oldReceipt = (await telegram({ callback_query: {
    id: 'legacy-owner', from: { id: Number(legacyUID) }, data: 'buy:1:150',
    message: { message_id: 60, chat: { id: Number(legacyUID), type: 'private' } }
  } }, { ...env, ADMIN_ID: legacyUID })).find(call => call.method === 'sendMessage').body;
  assert.ok(oldReceipt.text.includes(legacyKey), 'retrying an already paid older order returns its original key');
  assert.equal(sqlite.prepare('SELECT balance FROM shop_wallet WHERE uid=?').get(legacyUID).balance, 850);
  const existingOrderCount = orders();

  const prompt = await message('Получить бонус');
  assert.match(prompt.find(call => call.method === 'sendMessage').body.text, /Пришли личный ключ/);
  const reward = await message(key);
  assert.match(reward.find(call => call.method === 'sendMessage').body.text, /Бонус начислен/);
  assert.equal(wallet(), 1010);
  assert.equal(sqlite.prepare('SELECT lifetime FROM licenses WHERE digest=?').get(hash).lifetime, 90000);
  const repeat = await message(key);
  assert.match(repeat.find(call => call.method === 'sendMessage').body.text, /Бонус уже получен/);
  assert.equal(wallet(), 1010, 'retries cannot duplicate bonuses');
  const statusPrompt = await message('Проверить срок');
  const text = statusPrompt.find(call => call.method === 'sendMessage').body.text;
  const status = await message(key, user, { reply_to_message: { from: { is_bot: true }, text } });
  assert.match(status.find(call => call.method === 'sendMessage').body.text, /Ещё не активирован/);
  noPrices(reward.concat(repeat, status));

  const body = { uid: user, order_id: 'fixture-order', days: 1, price: 150 };
  async function api(token = env.API_TOKEN) {
    return worker.fetch(new Request('https://fixture.test/api/purchase', {
      method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    }), env);
  }
  assert.equal((await api('invalid')).status, 403);
  assert.equal(orders(), existingOrderCount);
  const purchase = await api();
  assert.equal(purchase.status, 200, 'authorized external API purchases remain supported');
  const bought = await purchase.json();
  assert.equal(bought.cost, 150);
  assert.match(bought.key, /^VL-[A-F0-9]{32}$/);
  assert.equal(wallet(), 860);
  const retry = await api();
  assert.equal((await retry.json()).key, bought.key);
  assert.equal(wallet(), 860, 'API retries preserve the existing idempotency contract');
  assert.equal(orders(), existingOrderCount + 1);
  noPrices(await message('Моя статистика'));
  noPrices(await message('Статистика магазина', env.ADMIN_ID));
  const wrongSecret = await worker.fetch(new Request('https://fixture.test/telegram', {
    method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': 'wrong' }, body: '{}'
  }), env);
  assert.equal(wrongSecret.status, 403);
  console.log('PASS: separate bot-only and API permissions, protected admin CRUD, Telegram-ID-only approval, exact Telegram rates, revocation race, copyable key cards, idempotent billing, legacy orders, bonus and expiry, preserved API tokens/prices/profiles');
} finally {
  globalThis.fetch = realFetch;
  sqlite.close();
}
