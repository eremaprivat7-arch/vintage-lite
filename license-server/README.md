# Vintage Lite — Cloudflare license server

This Worker replaces the VPS-only Flask license server with a Cloudflare Worker, a D1 database, and a small admin page. It exposes the same `POST /api/check` contract used by `LicenseSession` in the iOS app.

## What it supports

- Keys limited to one or more devices.
- A duration that starts on the first activation, or a fixed UTC expiry date.
- Create, revoke, and permanently delete keys from `/admin`.
- Block a device and free its seat.
- The full key is shown only once; the database stores its SHA-256 digest.
- Admin access uses a secret password and a signed, HTTP-only session cookie.

## Deploy from Windows PowerShell

You need Node.js/npm and a free Cloudflare account.

1. Open PowerShell in this folder and install the project tools:

   ```powershell
   npm install
   npx wrangler login
   ```

2. Create the D1 database:

   ```powershell
   npx wrangler d1 create vintage-lite-keys
   ```

   Copy the returned database ID into `wrangler.jsonc`, replacing `REPLACE_WITH_D1_DATABASE_ID`.

3. Create the tables in the remote database:

   ```powershell
   npx wrangler d1 execute vintage-lite-keys --remote --file=./migrations/0001_init.sql
   ```

4. Generate two secrets and add them to Cloudflare. Keep both values private:

   ```powershell
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   npx wrangler secret put ADMIN_PASSWORD
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   npx wrangler secret put SESSION_SECRET
   ```

   Each `secret put` command asks for the value. Use the matching generated value. The admin password is the password for `/admin`.

5. Publish the Worker:

   ```powershell
   npx wrangler deploy
   ```

   Wrangler prints a URL ending in `.workers.dev`. Open that URL with `/admin` to manage keys.

6. Put the Worker base URL in `ThreeOneOSFive/Info.plist` under `LicenseServerURL` (no trailing slash), rebuild the app, and publish that build. For example:

   ```xml
   <key>LicenseServerURL</key>
   <string>https://YOUR-WORKER.YOUR-SUBDOMAIN.workers.dev</string>
   ```

The existing iOS client sends a device UUID and key to `/api/check`. A one-device key refuses another device; a shared key accepts up to its configured seat count. A key's relative timer begins at its first successful activation. Fixed expiry dates are interpreted as UTC.

The Cloudflare account and Worker must be deployed by you; this repo does not contain account credentials. Never commit passwords, session secrets, or a real D1 database ID if you prefer to keep your infrastructure details private.
