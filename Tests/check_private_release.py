"""Verify the complete VintageLite app and its bundled packages."""
from collections import Counter
from hashlib import sha256
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "ThreeOneOSSix"
RESOURCES = ROOT / "ThreeOneOSFive/Patches"

info = plistlib.loads((APP / "Info.plist").read_bytes())
project = (ROOT / "ThreeOneOSSix.xcodeproj/project.pbxproj").read_text()
assert info["CFBundleIdentifier"] == "com.apple.mobile.MobileHouseArrest"
assert info["CFBundleDisplayName"] == "VintageLite"
assert info["LicenseServerURL"] == "https://vintage-lite-license.vintage-lite-keys.workers.dev"
assert info["CFBundleShortVersionString"] == "2.2.4"
assert info["CFBundleVersion"] == "15"
assert info["UIFileSharingEnabled"] is False
assert info["LSSupportsOpeningDocumentsInPlace"] is False
assert 'path = "../ThreeOneOSFive/Patches"' in project
assert "F37A0001 /* Patches in Resources */" in project
assert "MARKETING_VERSION = 2.2.4;" in project
assert "CURRENT_PROJECT_VERSION = 15;" in project
assert project.count("INFOPLIST_KEY_CFBundleDisplayName = VintageLite;") == 2
entitlements = plistlib.loads((APP / "ThreeOneOSSix.entitlements").read_bytes())
assert entitlements["com.apple.security.application-groups"]

files = sorted(
    file for file in RESOURCES.rglob("*")
    if file.is_file() and file.suffix.lower() in (".3105", ".3106")
)
assert files, "The source Patches folder contains no packages"
source_size = sum(file.stat().st_size for file in files)
identities = set()
source_hashes = {}
for file in files:
    data = file.read_bytes()
    assert data.startswith(b"3105PATCH\0"), file
    envelope = plistlib.loads(data[10:])
    assert envelope["schemaVersion"] in (1, 2, 3, 9), file
    assert envelope["packageID"] not in identities, file
    identities.add(envelope["packageID"])
    source_hashes[file.relative_to(RESOURCES)] = sha256(data).digest()

source = (APP / "App.swift").read_text()
for field in (
    'kSecAttrService as String: "VintageLite.activation"',
    'kSecAttrAccount as String: "license"',
    '"device-id"', '"api/check"', '"app_version"', '"app_build"',
    ".environmentObject(patchStore)", "SandboxAccess.prepare()",
):
    assert field in source, field
library = (APP / "helpers/PatchProjectLibrary.swift").read_text()
assert 'resources.appendingPathComponent("Patches", isDirectory: true)' in library
assert 'collect(root, bundled: false)' in library
assert 'password: "@osinxshop"' in library
screen = (APP / "views/PatchProjectsView.swift").read_text()
assert "struct PatchProjectDetailView" in screen
assert "guard await license.checkForApply()" in screen
assert "DevicePatchService.apply(project: project," in screen
assert "DevicePatchService.restore" in screen
assert (APP / "Assets.xcassets/VintageSky.imageset/sky.jpg").is_file()
schema = (ROOT / "license-server/private-content/schema.sql").read_text().lower()
assert not any(word in schema for word in ("drop ", "truncate ", "delete from licenses", "update licenses"))
print(f"PASS complete target, licensing identity, Apply/Restore entry points and {len(files)} bundled packages")
print(f"Current package folders: {dict(Counter(file.parent.name for file in files))}")

if len(sys.argv) > 1:
    bundle = Path(sys.argv[1])
    built = plistlib.loads((bundle / "Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion"):
        assert built[key] == info[key], key
    assert not built.get("UIFileSharingEnabled", False)
    built_resources = bundle / "Patches"
    built_hashes = {
        file.relative_to(built_resources): sha256(file.read_bytes()).digest()
        for file in built_resources.rglob("*")
        if file.is_file() and file.suffix.lower() in (".3105", ".3106")
    }
    assert built_hashes == source_hashes, "IPA resources differ from the current source package list"
    forbidden = (".swift", ".py", ".sql", ".p12", ".pem", ".key", ".mobileprovision")
    leaks = [
        file for file in bundle.rglob("*")
        if file.is_file() and file.suffix.lower() in forbidden and file.name != "embedded.mobileprovision"
    ]
    assert not leaks, leaks
    assert (bundle / built["CFBundleExecutable"]).is_file()
    print(f"PASS packaged executable and all {len(built_hashes)} package hashes ({source_size:,} bytes)")
