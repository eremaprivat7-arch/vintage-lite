import {privateContent,manageContent,boundedJSON,limitAdminLogin} from "./private-content.js";
import { releaseIdentity, releaseBlocked, releaseList, saveRelease, updateNotice } from "./releases.js";
import {report,reveal,issuedKey} from "./dashboard.js";
import {manage,reseller} from './reseller.js';
const encoder = new TextEncoder();
const SESSION_SECONDS = 12 * 60 * 60;
const COOKIE_NAME = "vl_admin";

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
      ...extraHeaders,
    },
  });
}

function html(response) {
  const headers = new Headers(response.headers);
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
  return new Response(response.body, { status: response.status, headers });
}

function errorResponse(error, status = 400) {
  return json({ error }, status);
}

async function readJson(request, maxBytes = 4096) {
  return (await boundedJSON(request, maxBytes)).value;
}

function hex(bytes) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256(value) {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

function equalConstantTime(left, right) {
  const max = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;
  for (let i = 0; i < max; i += 1) {
    diff |= (left.charCodeAt(i) || 0) ^ (right.charCodeAt(i) || 0);
  }
  return diff === 0;
}

async function hmac(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

async function newSession(secret) {
  const expires = Math.floor(Date.now() / 1000) + SESSION_SECONDS;
  const signature = await hmac(secret, `admin:${expires}`);
  return `${expires}.${signature}`;
}

async function validSession(request, secret) {
  const cookieHeader = request.headers.get("Cookie") || "";
  const cookie = cookieHeader.split(";").map((part) => part.trim())
    .find((part) => part.startsWith(`${COOKIE_NAME}=`));
  if (!cookie) return false;
  const value = cookie.slice(COOKIE_NAME.length + 1);
  const separator = value.indexOf(".");
  if (separator < 1) return false;
  const expires = Number(value.slice(0, separator));
  const signature = value.slice(separator + 1);
  if (!Number.isSafeInteger(expires) || expires <= Math.floor(Date.now() / 1000)) return false;
  return equalConstantTime(signature, await hmac(secret, `admin:${expires}`));
}

function cookie(value, maxAge) {
  return `${COOKIE_NAME}=${value}; Path=/admin; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`;
}

function sameOrigin(request) {
  const origin = request.headers.get("Origin");
  return (!origin || origin === new URL(request.url).origin)
    && request.headers.get("X-Requested-With") === "vintage-admin";
}

async function requireAdmin(request, env) {
  if (!env.ADMIN_PASSWORD || !env.SESSION_SECRET || env.SESSION_SECRET.length < 32) {
    return errorResponse("server_setup", 503);
  }
  if (!await validSession(request, env.SESSION_SECRET)) return errorResponse("unauthorized", 401);
  if (request.method !== "GET" && !sameOrigin(request)) return errorResponse("forbidden", 403);
  return null;
}

function randomKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return `VL-${hex(bytes).toUpperCase()}`;
}

function validUUID(value) {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function patchStarted(env) {
  const row = await env.DB.prepare("SELECT started FROM patch_mode WHERE id = 1").first();
  return row.started;
}

async function changePatchMode(request, env) {
  const body = await readJson(request).catch(() => null);
  if (typeof body?.enabled !== "boolean") return errorResponse("invalid", 400);
  if (body.enabled) {
    await env.DB.prepare("UPDATE patch_mode SET started = unixepoch() WHERE id = 1 AND started IS NULL").run();
  } else {
    // Repeated resume requests see NULL and cannot extend a license twice.
    await env.DB.batch([
      env.DB.prepare(`
        UPDATE licenses SET expires = expires + unixepoch() -
          MAX(created, (SELECT started FROM patch_mode WHERE id = 1))
        WHERE revoked = 0 AND expires > MAX(created, (SELECT started FROM patch_mode WHERE id = 1))
      `),
      env.DB.prepare("UPDATE patch_mode SET started = NULL WHERE id = 1"),
    ]);
  }
  return json({ enabled: (await patchStarted(env)) !== null });
}

async function checkLicense(request, env) {
  let body;
  try { body = await readJson(request); }
  catch (error) { return errorResponse(error.message === "too_large" ? "too_large" : "invalid", 400); }

  const identity = releaseIdentity(body.app_version, body.app_build);
  if (!identity) return errorResponse("invalid_version", 400);
  if (await releaseBlocked(env, identity)) return json(updateNotice(), 503);
  if ((await patchStarted(env)) !== null) return errorResponse("maintenance", 503);

  if (typeof body.key !== "string" || !validUUID(body.device)) return errorResponse("invalid", 400);
  const supplied = body.key.trim().toUpperCase();
  if (supplied.length < 16 || supplied.length > 96) return json({ error: "invalid" }, 403);
  const digest = await sha256(supplied);
  const now = Math.floor(Date.now() / 1000);

  let license = await env.DB.prepare(
    "SELECT id, seats, lifetime, expires, revoked FROM licenses WHERE digest = ?",
  ).bind(digest).first();
  if (!license || license.revoked) return json({ error: "invalid" }, 403);
  if (license.expires !== null && now >= license.expires) return json({ error: "expired" }, 403);

  let slot = await env.DB.prepare(
    "SELECT blocked FROM devices WHERE license = ? AND device = ?",
  ).bind(license.id, body.device.toLowerCase()).first();
  if (slot?.blocked) return json({ error: "blocked" }, 403);

  if (!slot) {
    // The conditional insert allocates a seat atomically when simultaneous activations arrive.
    await env.DB.prepare(`
      INSERT INTO devices (license, device, blocked)
      SELECT ?, ?, 0
      WHERE (SELECT COUNT(*) FROM devices WHERE license = ? AND blocked = 0)
        < (SELECT seats FROM licenses WHERE id = ? AND revoked = 0
             AND (expires IS NULL OR expires > ?))
      ON CONFLICT (license, device) DO NOTHING
    `).bind(license.id, body.device.toLowerCase(), license.id, license.id, now).run();

    slot = await env.DB.prepare(
      "SELECT blocked FROM devices WHERE license = ? AND device = ?",
    ).bind(license.id, body.device.toLowerCase()).first();
    if (!slot) return json({ error: "full" }, 403);
    if (slot.blocked) return json({ error: "blocked" }, 403);
  }

  await env.DB.prepare(
    "UPDATE licenses SET expires = ? WHERE id = ? AND expires IS NULL AND revoked = 0",
  ).bind(now + license.lifetime, license.id).run();
  license = await env.DB.prepare(
    "SELECT expires, revoked FROM licenses WHERE id = ?",
  ).bind(license.id).first();
  if (!license || license.revoked) return json({ error: "invalid" }, 403);
  if (license.expires === null || now >= license.expires) return json({ error: "expired" }, 403);
  return json({ valid: true, remaining: Math.max(1, license.expires - now) });
}

async function adminLogin(request, env) {
  if (!env.ADMIN_PASSWORD || !env.SESSION_SECRET || env.SESSION_SECRET.length < 32) {
    return errorResponse("server_setup", 503);
  }
  if (!sameOrigin(request)) return errorResponse("forbidden", 403);
  try { await limitAdminLogin(request,env); }
  catch { return errorResponse("rate_limited",429); }
  let body;
  try { body = await readJson(request); }
  catch { return errorResponse("invalid", 400); }
  if (typeof body.password !== "string" || body.password.length > 256
      || !equalConstantTime(await sha256(body.password), await sha256(env.ADMIN_PASSWORD))) {
    return errorResponse("unauthorized", 401);
  }
  const token = await newSession(env.SESSION_SECRET);
  return json({ ok: true }, 200, { "Set-Cookie": cookie(token, SESSION_SECONDS) });
}

async function listKeys(env) {
  const licenses = await env.DB.prepare(`
    SELECT l.id, l.label, l.seats, l.lifetime, l.expires, l.revoked, l.created,
      (SELECT COUNT(*) FROM devices d WHERE d.license = l.id AND d.blocked = 0) AS used
    FROM licenses l ORDER BY l.id DESC
  `).all();
  const devices = await env.DB.prepare(
    "SELECT license, device, blocked FROM devices ORDER BY license DESC, device",
  ).all();
  return json({ started: await patchStarted(env), licenses: licenses.results || [], devices: devices.results || [] });
}

async function createKey(request, env) {
  let body;
  try { body = await readJson(request); }
  catch { return errorResponse("invalid", 400); }
  const seats = Number(body.seats);
  const duration = Number(body.duration);
  const unit = body.unit;
  if (!Number.isInteger(seats) || seats < 1 || seats > 100000
      || !Number.isInteger(duration) || duration < 1 || duration > 36500
      || !["hours", "days"].includes(unit)) return errorResponse("invalid", 400);

  let expires = null;
  if (body.until) {
    const parsed = Date.parse(body.until);
    if (!Number.isFinite(parsed) || parsed <= Date.now()) return errorResponse("invalid_expiry", 400);
    expires = Math.floor(parsed / 1000);
  }

  const seed = "manual:" + crypto.randomUUID();
  const key = env.KEY_SECRET ? await issuedKey(env.KEY_SECRET,seed) : randomKey();
  const digest = await sha256(key);
  const lifetime = duration * (unit === "hours" ? 3600 : 86400);
  const insert = env.DB.prepare(
    "INSERT INTO licenses (digest, label, seats, lifetime, expires, created) VALUES (?, ?, ?, ?, ?, ?)",
  ).bind(digest, key.slice(-8), seats, lifetime, expires, Math.floor(Date.now() / 1000));
  if (env.KEY_SECRET) {
    await env.DB.batch([insert,env.DB.prepare("INSERT INTO portal_manual_keys VALUES(?,?)").bind(digest,seed)]);
  } else await insert.run();
  return json({ key, label: key.slice(-8) }, 201);
}

async function adminApi(request, env, url) {
  if (url.pathname === "/admin/api/login" && request.method === "POST") return adminLogin(request, env);
  if (url.pathname === "/admin/api/logout" && request.method === "POST") {
    if (!sameOrigin(request)) return errorResponse("forbidden", 403);
    return json({ ok: true }, 200, { "Set-Cookie": cookie("", 0) });
  }

  const denied = await requireAdmin(request, env);
  if (denied) return denied;
  if (url.pathname.startsWith("/admin/api/content/")) return manageContent(request,env,url);
  if (url.pathname === "/admin/api/releases" && request.method === "GET") return json(await releaseList(env));
  if (url.pathname === "/admin/api/releases" && request.method === "POST") {
    const body = await readJson(request).catch(() => null);
    const result = await saveRelease(env, body);
    return json(result, result.error ? 400 : 200);
  }
  if (url.pathname === "/admin/api/report" && request.method === "GET") return json(await report(env,null));
  const show = url.pathname.match(/^\/admin\/api\/show\/(\d+)$/);
  if (show && request.method === "GET") {
    const result = await reveal(env,Number(show[1]),null);
    return json(result,result.error ? 404 : 200);
  }
  if (url.pathname === "/admin/api/profile" && request.method === "POST") {
    const {uid,name} = await readJson(request);
    if (typeof uid!=="string" || !/^[1-9]\d{0,15}$/.test(uid) || typeof name!=="string" || !name.trim() || name.trim().length>64) return errorResponse("Проверьте имя и ID");
    await env.DB.prepare("INSERT INTO portal_names VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET name=excluded.name").bind(uid,name.trim()).run();
    return json({ok:true});
  }
  const edit = url.pathname.match(/^\/admin\/api\/keys\/(\d+)\/edit$/);
  if (edit && request.method === "POST") {
    const {hours,seats} = await readJson(request);
    if (!Number.isSafeInteger(hours) || hours<1 || hours>876000 || !Number.isInteger(seats) || seats<1 || seats>100000) return errorResponse("Проверьте срок и число устройств");
    const id=Number(edit[1]), life=hours*3600;
    const result=await env.DB.prepare(`UPDATE licenses SET expires=CASE WHEN expires IS NULL THEN NULL ELSE expires+?-lifetime END,
      lifetime=?,seats=? WHERE id=? AND ?>=(SELECT count(*) FROM devices WHERE license=? AND blocked=0)`).bind(life,life,seats,id,seats,id).run();
    return result.meta.changes ? json({ok:true}) : errorResponse("Проверьте количество занятых мест",409);
  }
  if (url.pathname === "/admin/api/reseller" && request.method === "POST") return manage(request,env);
  if (url.pathname === "/admin/api/patch" && request.method === "POST") return changePatchMode(request, env);
  if (url.pathname === "/admin/api/keys" && request.method === "GET") return listKeys(env);
  if (url.pathname === "/admin/api/keys" && request.method === "POST") return createKey(request, env);

  const deviceMatch = url.pathname.match(/^\/admin\/api\/keys\/(\d+)\/devices\/([0-9a-f-]{36})\/block$/i);
  if (deviceMatch && request.method === "POST") {
    const result = await env.DB.prepare(
      "UPDATE devices SET blocked = 1 WHERE license = ? AND device = ?",
    ).bind(Number(deviceMatch[1]), deviceMatch[2].toLowerCase()).run();
    return result.meta?.changes ? json({ ok: true }) : errorResponse("not_found", 404);
  }

  const keyMatch = url.pathname.match(/^\/admin\/api\/keys\/(\d+)(?:\/(revoke))?$/);
  if (keyMatch) {
    const id = Number(keyMatch[1]);
    if (request.method === "POST" && keyMatch[2] === "revoke") {
      const result = await env.DB.prepare("UPDATE licenses SET revoked = 1 WHERE id = ?")
        .bind(id).run();
      return result.meta?.changes ? json({ ok: true }) : errorResponse("not_found", 404);
    }
    if (request.method === "DELETE" && !keyMatch[2]) {
      await env.DB.batch([
        env.DB.prepare("DELETE FROM devices WHERE license = ?").bind(id),
        env.DB.prepare("DELETE FROM licenses WHERE id = ?").bind(id),
      ]);
      return json({ ok: true });
    }
  }
  return errorResponse("not_found", 404);
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (["/dashboard.js","/portal.css","/releases.js"].includes(url.pathname) && request.method==="GET") return env.ASSETS.fetch(request);
      if (url.pathname.startsWith("/reseller/api/")) return await reseller(request,env,url.pathname);
      if (url.pathname === "/api/status" && request.method === "GET") {
        const identity = releaseIdentity(
          url.searchParams.get("app_version") ?? undefined,
          url.searchParams.get("app_build") ?? undefined,
        );
        if (!identity) return errorResponse("invalid_version", 400);
        if (await releaseBlocked(env, identity)) return json(updateNotice());
        return json({ maintenance: (await patchStarted(env)) !== null, update_required: false });
      }
      if (url.pathname.startsWith("/api/content/")) return await privateContent(request,env,url);
      if (url.pathname === "/api/check" && request.method === "POST") return await checkLicense(request, env);
      if (url.pathname.startsWith("/admin/api/")) return await adminApi(request, env, url);
      if (url.pathname === "/" || url.pathname === "/admin") {
        return html(await env.ASSETS.fetch(new Request(new URL("/admin.html", url))));
      }
      if (url.pathname === "/reseller.html" || url.pathname === "/reseller") return html(await env.ASSETS.fetch(new Request(new URL("/reseller.html", url))));
      if (url.pathname === "/admin.html") return html(await env.ASSETS.fetch(request));
      return errorResponse("not_found", 404);
    } catch (error) {
      console.error("license-worker error", error);
      return errorResponse("server_error", 500);
    }
  },
};
