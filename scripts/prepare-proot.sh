#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
ASSET_DIR="$ROOT/app/src/main/assets"
JNI_DIR="$ROOT/app/src/main/jniLibs/arm64-v8a"
WORK="$ROOT/.build/proot"
REPO="https://packages.termux.dev/apt/termux-main"
mkdir -p "$ASSET_DIR" "$JNI_DIR" "$WORK/debs" "$WORK/extract" "$WORK/libs"

curl -fsSL "$REPO/dists/stable/main/binary-aarch64/Packages.xz" -o "$WORK/Packages.xz"
xz -dc "$WORK/Packages.xz" > "$WORK/Packages"

python3 - "$WORK/Packages" "$WORK/package-list.txt" <<'PY'
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
    if name in wanted or name not in records:
        continue
    wanted.add(name)
    deps = records[name].get('Depends', '')
    for dep in deps.split(','):
        dep = dep.strip().split(' | ')[0].strip().split(' ')[0]
        if dep and dep not in wanted:
            queue.append(dep)

with open(sys.argv[2], 'w') as f:
    for name in sorted(wanted):
        r = records[name]
        print(f"{name}\t{r.get('Filename','')}\t{r.get('SHA256','')}", file=f)
PY

while IFS=$'\t' read -r pkg filename sha; do
  [[ -n "$filename" ]] || continue
  out="$WORK/debs/${pkg}.deb"
  curl -fsSL "$REPO/$filename" -o "$out"
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
echo "Prepared PRoot and runtime libraries."
