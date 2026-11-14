import { boundedJSON } from './private-content.js';

const reply = (body, status = 200) => Response.json(body, {
  status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
});

// Called only after the existing admin session and same-origin checks.
export async function manageBotResellers(request, env) {
  if (request.method === 'GET') {
    const rows = await env.DB.prepare(`SELECT b.uid,b.created,COALESCE(w.balance,0) AS balance
      FROM bot_resellers b LEFT JOIN shop_wallet w USING(uid)
      WHERE b.enabled=1 ORDER BY b.created DESC,b.uid`).all();
    return reply({ items: rows.results });
  }
  if (request.method !== 'POST') return reply({ error: 'Метод не поддерживается' }, 405);
  let body;
  try { body = (await boundedJSON(request)).value; }
  catch { return reply({ error: 'Проверь Telegram ID' }, 400); }
  const action = body.action ?? 'add';
  if (typeof body.uid !== 'string' || !/^[1-9]\d{0,15}$/.test(body.uid)
      || !['add', 'remove'].includes(action)) return reply({ error: 'Проверь Telegram ID и действие' }, 400);
  if (action === 'remove') {
    await env.DB.prepare('UPDATE bot_resellers SET enabled=0 WHERE uid=?').bind(body.uid).run();
    return reply({ message: 'Доступ к боту отключён.' });
  }
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO bot_resellers(uid,enabled) VALUES(?,1)
      ON CONFLICT(uid) DO UPDATE SET enabled=1`).bind(body.uid),
    env.DB.prepare('INSERT INTO shop_wallet(uid) VALUES(?) ON CONFLICT(uid) DO NOTHING').bind(body.uid)
  ]);
  return reply({ message: 'Реселлер добавлен в Telegram-бота.' });
}
