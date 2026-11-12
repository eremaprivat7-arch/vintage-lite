"""Validate the migration contract before building the iPhone app."""
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = root / "ThreeOneOSSix"
info = plistlib.loads((app / "Info.plist").read_bytes())
project = (root / "ThreeOneOSSix.xcodeproj/project.pbxproj").read_text()
assert info["CFBundleIdentifier"] == "com.apple.mobile.MobileHouseArrest"
assert info["LicenseServerURL"] == "https://vintage-lite-license.vintage-lite-keys.workers.dev"
assert info["CFBundleShortVersionString"] == "2.0.0"
assert info["CFBundleVersion"] == "9"
assert "MARKETING_VERSION = 2.0.0;" in project
assert "CURRENT_PROJECT_VERSION = 9;" in project
assert 'path = "../ThreeOneOSFive/Patches"' in project
entitlements = plistlib.loads((app / "ThreeOneOSSix.entitlements").read_bytes())
assert entitlements["com.apple.security.application-groups"]

source = (app / "App.swift").read_text()
legacy = (root / "ThreeOneOSFive/App.swift").read_text()
for field in [
    'kSecAttrService as String: "VintageLite.activation"',
    'kSecAttrAccount as String: "license"',
    '"api/check"', '"app_version"', '"app_build"',
]:
    assert field in source and field in legacy, field
assert '"device-id"' in source
assert "UIDevice.current.identifierForVendor" in source
assert ".environmentObject(patchStore)" in source
assert ".environmentObject(repositoryStore)" in source

resources = root / "ThreeOneOSFive/Patches"
files = sorted(resources.rglob("*.3105"))
assert files, "Existing .3105 packages must be present"
ids = []
for file in files:
    data = file.read_bytes()
    assert data.startswith(b"3105PATCH\0"), file
    envelope = plistlib.loads(data[len(b"3105PATCH\0"):])
    assert envelope["schemaVersion"] in (1, 2, 3, 9), file
    ids.append(envelope["packageID"])

library = (app / "helpers/PatchProjectLibrary.swift").read_text()
assert '"FPSBoost", "ModSkin", "FPS", "Holo"' in library
assert '"3106", "3105"' in library
assert 'password: "@osinxshop"' in library
codec = (app / "helpers/PatchPackageCodec.swift").read_text()
assert 'Data("3105PATCH\\0".utf8)' in codec

for expected in ("LICENSE", "docs/3106/NOTICE.md", "docs/3106/VINTAGE-CHANGES.md"):
    assert (root / expected).is_file()
print(f"PASS VintageLite identity, licensing endpoint, app groups, {len(files)} resources ({len(set(ids))} IDs)")
