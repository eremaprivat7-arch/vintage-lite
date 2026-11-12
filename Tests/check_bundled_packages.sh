#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/Tests/vintage_packages_main.swift.txt" "$WORK/main.swift"
swiftc -O \
  "$ROOT/ThreeOneOSSix/helpers/PatchProjectModels.swift" \
  "$ROOT/ThreeOneOSSix/helpers/PatchPackageCodec.swift" \
  "$WORK/main.swift" -o "$WORK/check-packages"
"$WORK/check-packages" "$ROOT/ThreeOneOSFive/Patches"
