#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
ASSET_DIR="$ROOT/app/src/main/assets"
JNI_DIR="$ROOT/app/src/main/jniLibs/arm64-v8a"
WORK="$ROOT/.build/proot"
REPO="https://packages.termux.dev/apt/termux-main"
INDEX_BASE="$REPO/dists/stable/main/binary-aarch64"
mkdir -p "$ASSET_DIR" "$JNI_DIR" "$WORK/debs" "$WORK/extract" "$WORK/libs"
rm -rf "$WORK/debs" "$WORK/extract" "$WORK/libs"
mkdir -p "$WORK/debs" "$WORK/extract" "$WORK/libs"

# Termux mirrors may expose Packages using different compression formats.
# Try xz, gzip, then plain text so CI is resilient to mirror layout changes.
if curl -fsSL "$INDEX_BASE/Packages.xz" -o "$WORK/Packages.xz"; then
  xz -dc "$WORK/Packages.xz" > "$WORK/Packages"
elif curl -fsSL "$INDEX_BASE/Packages.gz" -o "$WORK/Packages.gz"; then
  gzip -dc "$WORK/Packages.gz" > "$WORK/Packages"
elif curl -fsSL "$INDEX_BASE/Packages" -o "$WORK/Packages"; then
  :
else
  echo "Unable to download Termux aarch64 package index from $INDEX_BASE" >&2
  exit 1
fi

python3 - "$WORK/Packages" "$WORK/package-list.txt" <<'PY'
import re
import sys
from pathlib import Path

paragraphs = Path(sys.argv[1]).read_text(errors='replace').split('\n\n')
records = {}
for p in paragraphs:
    data = {}
    key = None
    for line in p.splitlines():
        if line.startswith(' ') and key:
            data[key] += '\n' + line[1:]
        elif ': ' in line:
            key, val = line.split(': ', 1)
            data[key] = val
    if 'Package' in data:
        records[data['Package']] = data

wanted, queue = set(), ['proot']
while queue:
    name = queue.pop(0)
    if name in wanted:
        continue
    if name not in records:
        raise SystemExit(f"Required Termux package not found in index: {name}")
    wanted.add(name)
    deps = records[name].get('Depends', '')
    for dep_group in deps.split(','):
        dep = dep_group.strip().split(' | ')[0].strip()
        dep = re.sub(r'\s*\(.*?\)\s*$', '', dep)
        dep = dep.split(':')[0]
        if dep and dep not in wanted:
            queue.append(dep)

with open(sys.argv[2], 'w') as f:
    for name in sorted(wanted):
        r = records[name]
        filename = r.get('Filename', '')
        sha = r.get('SHA256', '')
        if not filename or not sha:
            raise SystemExit(f"Incomplete package metadata for {name}")
        print(f"{name}\t{filename}\t{sha}", file=f)
PY

while IFS=$'\t' read -r pkg filename sha; do
  out="$WORK/debs/${pkg}.deb"
  url="$filename"
  case "$url" in
    http://*|https://*) ;;
    *) url="$REPO/${url#./}" ;;
  esac
  echo "Downloading $pkg from $url"
  curl --retry 4 --retry-delay 2 --retry-all-errors -fsSL "$url" -o "$out"
  echo "$sha  $out" | sha256sum -c -
  dpkg-deb -x "$out" "$WORK/extract/$pkg"
done < "$WORK/package-list.txt"

PROOT_BIN=$(find "$WORK/extract/proot" -type f -path '*/bin/proot' | head -n1)
[[ -n "$PROOT_BIN" ]] || { echo "Termux proot binary not found" >&2; exit 1; }
cp "$PROOT_BIN" "$JNI_DIR/libproot.so"
chmod 755 "$JNI_DIR/libproot.so"

find "$WORK/extract" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 | while IFS= read -r -d '' f; do
  cp -L "$f" "$WORK/libs/$(basename "$f")"
done

tar -C "$WORK/libs" -cJf "$ASSET_DIR/proot-libs-arm64.tar.xz" .
file "$JNI_DIR/libproot.so"
ls -lh "$JNI_DIR/libproot.so" "$ASSET_DIR/proot-libs-arm64.tar.xz"
echo "Prepared PRoot and runtime libraries."
