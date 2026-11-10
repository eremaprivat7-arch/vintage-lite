from getpass import getpass
import json
from urllib.request import urlopen, Request
token = getpass("BotFather token: ").strip()
secret = getpass("WEBHOOK_SECRET: ").strip()
url = input("Reseller Worker https URL: ").strip().rstrip("/") + "/telegram"
payload = json.dumps({"url": url, "secret_token": secret, "allowed_updates": ["message", "callback_query"]}).encode()
request = Request("https://api.telegram.org/bot"+token+"/setWebhook", data=payload, headers={"Content-Type":"application/json"})
try:
    print(json.load(urlopen(request))["description"])
except Exception:
    print("Webhook setup failed. Check URL, token and WEBHOOK_SECRET.")
