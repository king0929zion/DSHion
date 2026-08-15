#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
DSH_REF="${DSH_REF:-master}"
NODE_VERSION="${NODE_VERSION:-22.19.0}"
PNPM_VERSION="${PNPM_VERSION:-11.7.0}"
ASSET_DIR="$ROOT/app/src/main/assets"
WORK="$ROOT/.build/rootfs"
ROOTFS="$WORK/fs"
mkdir -p "$ASSET_DIR" "$WORK"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

BASE_INDEX="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"
BASE_NAME=$(curl -fsSL "$BASE_INDEX" | grep -oE 'ubuntu-base-24\.04(\.[0-9]+)?-base-arm64\.tar\.gz' | sort -Vu | tail -n1)
[[ -n "$BASE_NAME" ]] || { echo "Unable to discover Ubuntu Base ARM64 image" >&2; exit 1; }
curl --retry 3 -fsSL "$BASE_INDEX$BASE_NAME" -o "$WORK/ubuntu-base.tar.gz"
tar -xzf "$WORK/ubuntu-base.tar.gz" -C "$ROOTFS"

NODE_TAR="node-v${NODE_VERSION}-linux-arm64.tar.xz"
curl --retry 3 -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TAR}" -o "$WORK/$NODE_TAR"
curl --retry 3 -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$WORK/SHASUMS256.txt"
(cd "$WORK" && grep " ${NODE_TAR}$" SHASUMS256.txt | sha256sum -c -)
tar -xJf "$WORK/$NODE_TAR" -C "$ROOTFS/usr/local" --strip-components=1

# Ubuntu Base may ship /tmp without the permissions apt expects.
sudo mkdir -p "$ROOTFS/tmp" "$ROOTFS/var/tmp"
sudo chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"

sudo apt-get update -qq
sudo apt-get install -y -qq qemu-user-static binfmt-support
if command -v update-binfmts >/dev/null 2>&1; then sudo update-binfmts --enable qemu-aarch64 || true; fi
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
sudo rm -f "$ROOTFS/etc/resolv.conf"
sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

CHROOT=(sudo chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -lc)
"${CHROOT[@]}" 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends ca-certificates curl git openssh-client bash coreutils findutils grep sed tar xz-utils procps python3 make g++ pkg-config; rm -rf /var/lib/apt/lists/*'
"${CHROOT[@]}" "node --version && npm --version && corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate && pnpm --version"
"${CHROOT[@]}" "rm -rf /opt/deepseek-harness; git clone --depth 1 --branch '${DSH_REF}' https://github.com/deepseek-ai/deepseek-harness.git /opt/deepseek-harness || { git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git /opt/deepseek-harness; cd /opt/deepseek-harness; git checkout '${DSH_REF}'; }"
"${CHROOT[@]}" 'cd /opt/deepseek-harness && CI=1 pnpm install --frozen-lockfile && pnpm run build'

sudo tee "$ROOTFS/usr/local/bin/dsh" >/dev/null <<'EOF'
#!/bin/bash
exec node /opt/deepseek-harness/apps/cli/lib/bin.js "$@"
EOF
sudo chmod 755 "$ROOTFS/usr/local/bin/dsh"
"${CHROOT[@]}" 'dsh --version || true; test -f /opt/deepseek-harness/apps/cli/lib/bin.js; command -v dsh; command -v node'

# Strip caches and development metadata while keeping built runtime dependencies.
sudo rm -rf "$ROOTFS/opt/deepseek-harness/.git" "$ROOTFS/root/.cache/pnpm" "$ROOTFS/root/.npm" "$ROOTFS/tmp"/* "$ROOTFS/var/tmp"/*
sudo rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
sudo rm -f "$ROOTFS/etc/resolv.conf"
sudo mkdir -p "$ROOTFS/root/.cache" "$ROOTFS/root/.config" "$ROOTFS/root/.local/share/dsh" "$ROOTFS/tmp" "$ROOTFS/var/tmp"
sudo chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"
echo "DSHion Ubuntu 24.04 ARM64 / Node ${NODE_VERSION} / DeepSeek Harness ${DSH_REF}" | sudo tee "$ROOTFS/etc/dshion-image" >/dev/null
sudo tar -C "$ROOTFS" --numeric-owner -cJf "$ASSET_DIR/ubuntu-rootfs-arm64.tar.xz" .
ls -lh "$ASSET_DIR/ubuntu-rootfs-arm64.tar.xz"
