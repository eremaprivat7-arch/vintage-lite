"""Owner-only private package publisher. Never include this tool or inputs in the IPA."""
import argparse
import base64
import getpass
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import uuid
import urllib.error
import urllib.request

BASE = "https://vintage-lite-license.vintage-lite-keys.workers.dev"
PART = 262144
MAX = 8 * 1024 * 1024


def b64(data):
    return base64.b64encode(data).decode("ascii")


def crypto_class():
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        return AESGCM
    except ImportError:
        raise SystemExit("Установи зависимость: py -m pip install cryptography")


def unwrap_package(data, password):
    aes = crypto_class()
    if len(data) > MAX - 66 or not data.startswith(b"3105PATCH\0"):
        raise ValueError("unsupported package")
    envelope = plistlib.loads(data[10:])
    version = envelope["schemaVersion"]
    if version not in (1, 2, 3, 9):
        raise ValueError("unsupported version")
    package_id = str(uuid.UUID(envelope["packageID"])).upper()
    if envelope["isPasswordProtected"]:
        iterations = envelope["kdfIterations"]
        if not 10000 <= iterations <= 2000000:
            raise ValueError("invalid KDF")
        wrap_key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), envelope["kdfSalt"], iterations, 32)
        wrapped = envelope["wrappedContentKey"]
        key_version = envelope.get("keyAADVersion", version)
        key = aes(wrap_key).decrypt(wrapped[:12], wrapped[12:], f"3105PATCH/v{key_version}/key/{package_id}".encode())
    else:
        key = envelope["publicContentKey"]
    if len(key) != 32 or hashlib.sha256(key).digest() != envelope["keyFingerprint"]:
        raise ValueError("invalid key fingerprint")
    encrypted = envelope["encryptedPayload"]
    payload = plistlib.loads(aes(key).decrypt(encrypted[:12], encrypted[12:], f"3105PATCH/v{version}/payload/{package_id}".encode()))
    project = payload["project"]
    if uuid.UUID(project["id"]) != uuid.UUID(package_id):
        raise ValueError("invalid project identity")
    if version == 9:
        if any(project.get(k) for k in ("settings", "appGroupIdentifiers", "systemAppGroupIdentifiers")):
            raise ValueError("unsupported V9 features")
        if any(r.get("operation") != "replace" or r.get("containerKind") != "application" for r in project["rules"]):
            raise ValueError("unsupported V9 operations")
        if any(d.get("containerKind") != "application" for d in project.get("directories", [])):
            raise ValueError("unsupported V9 directories")
    for rule in project["rules"]:
        digest = payload["replacementDigests"].get(str(uuid.UUID(rule["id"])).upper())
        if digest != hashlib.sha256(rule["replacementData"]).digest():
            raise ValueError("invalid replacement digest")
    return package_id.lower(), key, project["name"]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class OwnerAPI:
    def __init__(self):
        self.opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(self, path, body=None):
        data = None if body is None else json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
        request = urllib.request.Request(BASE + path, data=data, headers={"User-Agent": "VintageLite-Publisher/2.1", "Accept": "application/json", "X-Requested-With": "vintage-admin", "Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=90) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                code = json.loads(error.read(4096)).get("error", "request_failed")
            except (ValueError, AttributeError):
                code = "request_failed"
            raise RuntimeError(f"HTTP {error.code}: {code}") from None

    def login(self):
        self.call("/admin/api/login", {"password": getpass.getpass("Пароль админки сайта: ")})


def read_jsonc(path):
    text = path.read_text(encoding="utf-8-sig")
    output, quoted, escaped, i = [], False, False, 0
    while i < len(text):
        c = text[i]
        if quoted:
            output.append(c)
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                quoted = False
            i += 1
        elif c == '"':
            quoted = True; output.append(c); i += 1
        elif text[i:i+2] == "//":
            end = text.find("\n", i)
            i = len(text) if end == -1 else end
        elif text[i:i+2] == "/*":
            end = text.find("*/", i+2)
            if end == -1:
                raise ValueError("Unclosed JSONC comment")
            i = end + 2
        else:
            if c == ",":
                j = i+1
                while j < len(text) and text[j].isspace():
                    j += 1
                if j < len(text) and text[j] in "]}":
                    i += 1
                    continue
            output.append(c); i += 1
    # A second pass handles trailing commas followed by comments that were removed.
    text, output, quoted, escaped = "".join(output), [], False, False
    for i, c in enumerate(text):
        if quoted:
            output.append(c)
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                quoted = False
        elif c == '"':
            quoted = True
            output.append(c)
        else:
            j = i + 1
            if c == ",":
                while j < len(text) and text[j].isspace():
                    j += 1
                if j < len(text) and text[j] in "]}":
                    continue
            output.append(c)
    return json.loads("".join(output))


def configure(path, content_id):
    content_id = str(uuid.UUID(content_id))
    config = read_jsonc(path)
    if config.get("name") != "vintage-lite-license":
        raise RuntimeError("Ожидался Worker vintage-lite-license. Конфигурация не изменена.")
    secret_names = {"ADMIN_PASSWORD", "SESSION_SECRET", "KEY_SECRET", "CONTENT_MASTER_KEY", "TELEGRAM_BOT_TOKEN", "WEBHOOK_SECRET", "RESELLER_API_TOKEN", "CLOUDFLARE_API_TOKEN"}
    for name in config.get("vars", {}):
        if name.upper() in secret_names:
            raise RuntimeError(f"Перемести {name} из vars в Worker Secrets. Конфигурация не отправлялась в GitHub.")
    bindings = config.setdefault("d1_databases", [])
    original = [dict(v) for v in bindings if v.get("binding") == "DB"]
    if len(original) != 1 or original[0].get("database_id") != "17af1ecb-f1b5-408b-800d-2de448a1e3ba":
        raise RuntimeError("Лицензионная DB не совпадает с ожидаемой. Конфигурация не изменена.")
    if content_id == original[0]["database_id"]:
        raise RuntimeError("Хранилище файлов должно быть ОТДЕЛЬНОЙ базой.")
    matches = [v for v in bindings if v.get("binding") == "CONTENT_DB"]
    if matches and matches[0].get("database_id") != content_id:
        raise RuntimeError("CONTENT_DB уже указывает на другую базу. Автоматическая замена остановлена.")
    if not matches:
        bindings.append({"binding": "CONTENT_DB", "database_name": "vintage-private-content", "database_id": content_id})
    assert [v for v in bindings if v.get("binding") == "DB"] == original
    temporary = path.with_suffix(".jsonc.tmp")
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)
    print("CONTENT_DB добавлена. Лицензионная DB сохранена без изменений.")


def upload(folder, mirror=False):
    aes = crypto_class()
    folder = folder.resolve()
    files = sorted(p for p in folder.rglob("*") if p.suffix.lower() in (".3105", ".3106") and p.is_file())
    if not files:
        raise RuntimeError("В папке нет пакетов .3105 / .3106")
    categories = {"fpsboost": "Boost", "boost": "Boost", "modskin": "Mod Skin", "fps": "FPS", "holo": "Holo"}
    password = getpass.getpass("Общий пароль пакетов (не сохраняется): ")
    prepared, skipped = [], set()
    # Validate every file before publishing any update.
    for path in files:
        relative = path.relative_to(folder)
        if len(relative.parts) != 2 or relative.parts[0].lower() not in categories:
            raise RuntimeError(f"Помести файл в FPSBoost/ModSkin/FPS/Holo: {relative}")
        asset_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "vintage-private:" + relative.as_posix().lower()))
        package = path.read_bytes()
        if len(package) > MAX - 66:
            raise RuntimeError(f"Пакет превышает лимит 8 МиБ защищённой выдачи: {relative}")
        skip = False
        while True:
            try:
                package_id, content_key, title = unwrap_package(package, password)
                break
            except Exception:
                another = getpass.getpass(f"{relative}: пароль не подошёл или файл повреждён. Другой пароль (Enter = пропустить): ")
                if not another:
                    skipped.add(asset_id)
                    skip = True
                    print("Пропущен, исходник сохранён:", relative)
                    break
                try:
                    package_id, content_key, title = unwrap_package(package, another)
                    break
                except Exception:
                    print("Проверка файла снова не прошла.")
        if skip:
            continue
        key, nonce = os.urandom(32), os.urandom(12)
        clear = b"VLCP1\0" + content_key + package
        cipher = nonce + aes(key).encrypt(nonce, clear, ("VL-content-v1:" + asset_id).encode())
        if len(cipher) > MAX:
            raise RuntimeError(f"Файл слишком большой: {relative}")
        prepared.append(({"id": asset_id, "package_id": package_id, "title": title[:120], "category": categories[relative.parts[0].lower()],
                          "size": len(cipher), "parts": (len(cipher)+PART-1)//PART, "revision": hashlib.sha256(cipher).hexdigest(), "key": b64(key),
                          "hashes": [hashlib.sha256(cipher[i:i+PART]).hexdigest() for i in range(0,len(cipher),PART)]}, cipher))
    if not prepared:
        raise RuntimeError("Ни один пакет не прошёл проверку. Хранилище не изменено.")
    api = OwnerAPI(); api.login()
    old = api.call("/admin/api/content/status")["assets"]
    ids = set(skipped)
    for meta, cipher in prepared:
        api.call("/admin/api/content/begin", meta)
        for part in range(meta["parts"]):
            api.call("/admin/api/content/chunk", {"id": meta["id"], "revision": meta["revision"], "part": part, "data": b64(cipher[part*PART:(part+1)*PART])})
        api.call("/admin/api/content/commit", {"id": meta["id"], "revision": meta["revision"]})
        ids.add(meta["id"])
        print("Готово:", meta["category"], "·", meta["title"])
    if mirror:
        for asset in old:
            if asset["id"] not in ids:
                api.call("/admin/api/content/disable", {"id": asset["id"]})
    print(f"Опубликовано: {len(prepared)}, пропущено: {len(skipped)}. Исходные файлы и база лицензий не изменялись.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("upload"); p.add_argument("folder", type=Path); p.add_argument("--mirror", action="store_true")
    p = commands.add_parser("configure"); p.add_argument("config", type=Path); p.add_argument("database_id")
    commands.add_parser("create-master")
    commands.add_parser("status")
    p = commands.add_parser("reset-device"); p.add_argument("license", type=int); p.add_argument("device")
    args = parser.parse_args()
    if args.command == "configure":
        configure(args.config, args.database_id)
    elif args.command == "create-master":
        path = Path.home()/".vintage-lite-private"/"master.key"
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            descriptor = os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as output:
                output.write(b64(os.urandom(32)))
        data = base64.b64decode(path.read_text().strip(), validate=True)
        if len(data) != 32:
            raise RuntimeError("Некорректный master.key. Автоматическая замена запрещена.")
        print("Резервный ключ хранится только на твоём ПК:", path)
    elif args.command == "upload":
        upload(args.folder, args.mirror)
    else:
        api = OwnerAPI(); api.login()
        if args.command == "status":
            value = api.call("/admin/api/content/status")
            print("Хранилище готово. Файлов:", len(value["assets"]))
        else:
            api.call("/admin/api/content/reset-device", {"license": args.license, "device": str(uuid.UUID(args.device))})
            print("Защитная привязка сброшена. Срок и ключ лицензии сохранены.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print("Остановлено:", error, file=sys.stderr)
        sys.exit(1)
