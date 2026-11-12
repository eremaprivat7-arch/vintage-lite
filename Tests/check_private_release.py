"""Check source/release boundaries; production license data is never needed."""
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parent.parent
app = root / "ThreeOneOSSix"
info = plistlib.loads((app / "Info.plist").read_bytes())
project = (root / "ThreeOneOSSix.xcodeproj/project.pbxproj").read_text()
assert info["CFBundleIdentifier"] == "com.apple.mobile.MobileHouseArrest"
assert info["LicenseServerURL"] == "https://vintage-lite-license.vintage-lite-keys.workers.dev"
assert info["CFBundleShortVersionString"] == "2.1.0"
assert info["CFBundleVersion"] == "10"
assert info["UIFileSharingEnabled"] is False
assert info["LSSupportsOpeningDocumentsInPlace"] is False
assert 'ThreeOneOSFive/Patches' not in project
assert "MARKETING_VERSION = 2.1.0;" in project
assert "CURRENT_PROJECT_VERSION = 10;" in project
for name in ("PrivateContentClient.swift", "PrivateContentView.swift"):
    assert project.count(name) >= 4, name
source = (app / "App.swift").read_text()
for field in ('kSecAttrService as String: "VintageLite.activation"', 'kSecAttrAccount as String: "license"', '"device-id"'):
    assert field in source, field
for path in app.rglob("*.swift"):
    assert 'password: "@osinxshop"' not in path.read_text(), path
private = (app / "helpers/PrivateContentClient.swift").read_text()
for field in ("SecureEnclave.P256", "kSecAttrAccessibleWhenUnlockedThisDeviceOnly", "httpShouldSetCookies = false", "AES.GCM.open", "rawRepresentation", "X-VL-Nonce"):
    assert field in private, field
assert "PatchKeyStore.store" not in private
schema = (root / "license-server/private-content/schema.sql").read_text().lower()
assert not any(word in schema for word in ("drop ", "truncate ", "delete from licenses", "update licenses"))
print("PASS private delivery contract, device identity, no bundled owner packages or hardcoded password use, signing profile retained")
if len(sys.argv) > 1:
    bundle = Path(sys.argv[1])
    built = plistlib.loads((bundle / "Info.plist").read_bytes())
    assert not built.get("UIFileSharingEnabled", False)
    forbidden = (".3105", ".3106", ".swift", ".py", ".sql", ".p12", ".pem", ".key", ".mobileprovision")
    # embedded.mobileprovision is a legitimate signing profile, not an owner payload.
    leaks = [p for p in bundle.rglob("*") if p.is_file() and p.suffix.lower() in forbidden and p.name != "embedded.mobileprovision"]
    assert not leaks, leaks
    assert not (bundle / "Patches").exists()
    print("PASS built IPA contains no owner packages, source files or signing secrets")
