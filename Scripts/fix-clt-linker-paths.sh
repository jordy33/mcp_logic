#!/usr/bin/env bash
# Silence ld's "search path ... not found" warnings on Command Line Tools-only installs.
#
# SwiftPM always passes two search paths that only a full Xcode install creates:
#   -F /Library/Developer/CommandLineTools/Developer/Library/Frameworks
#   -L /Library/Developer/CommandLineTools/Developer/usr/lib
# ld warns once per product for each missing directory. Creating them empty is
# harmless and removes the warnings without hiding any other linker diagnostic.
#
# Requires sudo (they live under /Library). Re-run after a CLT upgrade.
set -euo pipefail

CLT="$(xcode-select -p)"
if [ "$CLT" != "/Library/Developer/CommandLineTools" ]; then
  echo "[fix-linker] active toolchain is $CLT — those paths come from Xcode; nothing to do"
  exit 0
fi

if [ -d /Applications/Xcode.app ]; then
  echo "[fix-linker] Xcode is installed; prefer: sudo xcode-select -s /Applications/Xcode.app"
  exit 0
fi

missing=()
for d in "$CLT/Developer/Library/Frameworks" "$CLT/Developer/usr/lib"; do
  [ -d "$d" ] || missing+=("$d")
done

if [ ${#missing[@]} -eq 0 ]; then
  echo "[fix-linker] search paths already exist"
  exit 0
fi

echo "[fix-linker] creating ${#missing[@]} directory(ies) under $CLT"
printf '  %s\n' "${missing[@]}"
sudo mkdir -p "${missing[@]}"
echo "[fix-linker] done — rebuild with: swift build -c release"
