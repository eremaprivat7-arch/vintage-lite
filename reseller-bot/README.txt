Vintage Lite · Telegram reseller
Распакуй архив и открой PowerShell в этой папке. Нужны Node.js, Python и доступ к тому же аккаунту Cloudflare, что и у vintage-lite-license. База должна содержать миграции 0001 и 0002 действующего сервера. Проверь название и ID D1 в wrangler.jsonc.

npx wrangler login
npx wrangler d1 execute vintage-lite-keys --remote --file=./schema.sql
npx wrangler deploy
npx wrangler secret put TELEGRAM_BOT_TOKEN
npx wrangler secret put ADMIN_ID
npx wrangler secret put WEBHOOK_SECRET
npx wrangler secret put KEY_SECRET

Введи значения по запросу: токен BotFather, свой числовой Telegram ID, случайный webhook-секрет (буквы и цифры, 32–64 символа) и отдельный случайный секрет для ключей. Сохрани KEY_SECRET: он позволяет повторно показать выданные ключи. Для внешнего клиента API отдельно установи токен командой npx wrangler secret put API_TOKEN.

py webhook.py

Введи токен, тот же WEBHOOK_SECRET и URL нового Worker из вывода deploy. Telegram переключит доставку событий этого бота на новый webhook.

Открой личный чат с ботом и отправь /start. Цены из прайса устанавливает schema.sql. Для изменения цены используй команду /price ДНИ ЦЕНА. Пример: /price 7 1500. Цены в целых тенге. /balance 123456789 +5000 пополняет кошелёк, /balance 123456789 -1000 списывает. ID реселлер увидит в «Мой баланс». Покупка доступна любому пользователю с достаточным балансом. Повторное нажатие в одном сообщении не создаёт второй заказ; для новой покупки открой каталог заново.

У каждого личного ключа один бонус. Первый, кто вводит ключ в личном чате, получает деньги на свой баланс, срок продлевается у владельца ключа. Работает и для ключей сайта соответствующих сроков. Общие, отозванные и просроченные ключи не участвуют. У неактивированного ключа срок начнётся при активации.

API: POST /api/purchase, Authorization: Bearer <API_TOKEN>, Content-Type: application/json
Тело: {"uid":"123456789","order_id":"order-123","days":7,"price":1500}
Возвращает key, days, cost. При повторной попытке после обрыва связи отправь тот же order_id и параметры.
