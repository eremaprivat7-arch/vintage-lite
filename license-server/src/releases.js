const versionPattern = /^\d{1,6}(?:\.\d{1,6}){0,3}$/;

export function releaseIdentity(version, build) {
  if (version === undefined && build === undefined) return { version: "legacy", build: "legacy" };
  if (typeof version !== "string" || typeof build !== "string"
      || !versionPattern.test(version) || !versionPattern.test(build)) return null;
  return { version, build };
}

export async function releaseBlocked(env, identity) {
  const row = await env.DB.prepare(
    "SELECT blocked FROM app_releases WHERE version = ? AND build = ?",
  ).bind(identity.version, identity.build).first();
  return row?.blocked === 1;
}

export async function recordRelease(env, identity) {
  if (identity.version === "legacy") return;
  await env.DB.prepare(
    "INSERT OR IGNORE INTO app_releases (version, build) VALUES (?, ?)",
  ).bind(identity.version, identity.build).run();
}

export async function releaseList(env) {
  const rows = await env.DB.prepare(
    "SELECT version, build, blocked FROM app_releases ORDER BY version, build",
  ).all();
  const releases = rows.results || [];
  releases.sort((a, b) => {
    if (a.version === "legacy") return b.version === "legacy" ? 0 : 1;
    if (b.version === "legacy") return -1;
    return b.version.localeCompare(a.version, "en", { numeric: true })
      || b.build.localeCompare(a.build, "en", { numeric: true });
  });
  return { releases };
}

export async function saveRelease(env, body) {
  if (!body || typeof body.blocked !== "boolean") return { error: "Выберите состояние версии" };
  const identity = body.version === "legacy" && body.build === "legacy"
    ? { version: "legacy", build: "legacy" }
    : releaseIdentity(body.version, body.build);
  if (!identity || (identity.version === "legacy" && body.version !== "legacy")) {
    return { error: "Укажите версию и номер сборки цифрами через точку" };
  }
  await env.DB.prepare(`
    INSERT INTO app_releases (version, build, blocked) VALUES (?, ?, ?)
    ON CONFLICT (version, build) DO UPDATE SET blocked = excluded.blocked
  `).bind(identity.version, identity.build, Number(body.blocked)).run();
  return { ok: true };
}

export function updateNotice() {
  return {
    maintenance: true,
    error: "maintenance",
    update_required: true,
    message: "Для этой версии включён патч. Скачай новую версию в @osinxshop.",
  };
}
