#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/Tests/patch_transaction_main.swift.txt" "$WORK/main.swift"
swiftc -O \
  "$ROOT/ThreeOneOSSix/helpers/PatchProjectModels.swift" \
  "$ROOT/ThreeOneOSSix/helpers/BackupCenter.swift" \
  "$ROOT/ThreeOneOSSix/helpers/PatchTransaction.swift" \
  "$WORK/main.swift" -o "$WORK/check-transactions"
"$WORK/check-transactions"
