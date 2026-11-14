import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '../reseller-bot/worker.js';

const sqlite = new DatabaseSync(':memory:');
for (const file of ['../license-server/migrations/0001_init.sql', '../license-server/migrations/0002_patch_mode.sql', '../reseller-bot/schema.sql']) {
  sqlite.exec(readFileSync(new URL(file, import.meta.url), 'utf8'));
}
class Statement {
  constructor(sql, values = []) { this.sql = sql; this.values = values; }
  bind(...values) { return new Statement(this.sql, values); }
  async first() { return sqlite.prepare(this.sql).get(...this.values) ?? null; }
  async all() { return { results: sqlite.prepare(this.sql).all(...this.values) }; }
  async run() { return { meta: { changes: Number(sqlite.prepare(this.sql).run(...this.values).changes) } }; }
}
const env = {
  DB: { prepare: sql => new Statement(sql), batch: statements => Promise.all(statements.map(statement => statement.all())) },
  TELEGRAM_BOT_TOKEN: 'fixture-only-token', ADMIN_ID: '777',
  WEBHOOK_SECRET: 'fixture-only-webhook', KEY_SECRET: 'fixture-only-key-secret', API_TOKEN: 'fixture-only-api-token'
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
    assert.doesNotMatch(JSON.stringify(call.body), /Купить ключ|Сумма покупок|закупка|розница|доход|150\s*₸/i);
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
      assert.match(out.find(call => call.method === 'sendMessage').body.text, /Покупка ключей через бота отключена/);
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
    assert.equal(catalog.reply_markup.inline_keyboard[0][0].callback_data, 'buy:1:150');
    assert.match(catalog.reply_markup.inline_keyboard[0][0].text, /150/);
    assert.doesNotMatch(catalog.text, /розница|закупка|доход/i);
  }
  assert.equal(orders(), 0, 'opening the owner catalog does not purchase a key');
  assert.equal(sqlite.prepare('SELECT price FROM shop_plans WHERE days=1').get().price, 150);
  const ownerButton = (data = 'buy:1:150', messageID = 70, runtime = env) => telegram({ callback_query: {
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
  assert.doesNotMatch(card.text, /списано|стоимость|150\s*₸/i);
  assert.match(card.text, /1 день/);
  assert.deepEqual(card.reply_markup.inline_keyboard[0][0].copy_text, { text: issuedKey });
  assert.deepEqual(issued.find(call => call.method === 'editMessageReplyMarkup').body.reply_markup.inline_keyboard, []);
  assert.equal(ownerWallet(), 850, 'the existing wallet accounting is preserved');
  assert.equal(wallet(), 1000, 'the owner purchase cannot charge someone else');
  assert.equal(orders(), 1);
  const repeatedCard = (await ownerButton()).find(call => call.method === 'sendMessage').body;
  assert.match(repeatedCard.text, new RegExp(issuedKey));
  assert.equal(ownerWallet(), 850, 'repeated owner callbacks cannot debit twice');
  assert.equal(orders(), 1);
  for (const data of ['buy:1:1', 'buy:1:0', 'buy:1:-1', 'buy:60:150', 'buy:30:3000']) {
    const rejected = await ownerButton(data, 71);
    assert.ok(!rejected.some(call => call.body.parse_mode === 'HTML'), data);
    assert.equal(orders(), 1, 'forged prices, unsupported plans and insufficient funds cannot create an order');
    assert.equal(ownerWallet(), 850);
  }
  const missingOwner = await ownerButton('buy:1:150', 72, { ...env, ADMIN_ID: '' });
  noPrices(missingOwner);
  assert.equal(orders(), 1, 'an unset ADMIN_ID denies purchase');
  const newCard = (await ownerButton('buy:3:420', 73)).find(call => call.method === 'sendMessage').body;
  assert.match(newCard.text, /3 дня/);
  assert.ok(!newCard.text.includes(issuedKey), 'a new catalog message creates a separate order');
  assert.equal(orders(), 2);
  assert.equal(ownerWallet(), 430);
  const ownerOrderCount = orders();

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
  assert.equal(orders(), ownerOrderCount);
  const purchase = await api();
  assert.equal(purchase.status, 200, 'authorized external API purchases remain supported');
  const bought = await purchase.json();
  assert.equal(bought.cost, 150);
  assert.match(bought.key, /^VL-[A-F0-9]{32}$/);
  assert.equal(wallet(), 860);
  const retry = await api();
  assert.equal((await retry.json()).key, bought.key);
  assert.equal(wallet(), 860, 'API retries preserve the existing idempotency contract');
  assert.equal(orders(), ownerOrderCount + 1);
  noPrices(await message('Моя статистика'));
  noPrices(await message('Статистика магазина', env.ADMIN_ID));
  const wrongSecret = await worker.fetch(new Request('https://fixture.test/telegram', {
    method: 'POST', headers: { 'X-Telegram-Bot-Api-Secret-Token': 'wrong' }, body: '{}'
  }), env);
  assert.equal(wrongSecret.status, 403);
  console.log('PASS: owner-only Telegram purchases, private catalog, formatted copyable receipts without debit text, denied forged prices, idempotent wallet accounting, public bonus and expiry flows, authenticated external API');
} finally {
  globalThis.fetch = realFetch;
  sqlite.close();
}
