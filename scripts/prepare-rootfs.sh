#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
DSH_VERSION="${DSH_VERSION:-0.1.0-rc.5}"
NODE_VERSION="${NODE_VERSION:-22.19.0}"
ASSET_DIR="$ROOT/app/src/main/assets"
WORK="$ROOT/.build/rootfs"
ROOTFS="$WORK/fs"
mkdir -p "$ASSET_DIR" "$WORK"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

BASE_INDEX="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"
BASE_NAME=$(curl -fsSL "$BASE_INDEX" | grep -oE 'ubuntu-base-24\.04(\.[0-9]+)?-base-arm64\.tar\.gz' | sort -Vu | tail -n1)
[[ -n "$BASE_NAME" ]] || { echo "Unable to discover Ubuntu Base ARM64 image" >&2; exit 1; }
curl -fsSL "$BASE_INDEX$BASE_NAME" -o "$WORK/ubuntu-base.tar.gz"
tar -xzf "$WORK/ubuntu-base.tar.gz" -C "$ROOTFS"

NODE_TAR="node-v${NODE_VERSION}-linux-arm64.tar.xz"
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TAR}" -o "$WORK/$NODE_TAR"
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$WORK/SHASUMS256.txt"
(cd "$WORK" && grep " ${NODE_TAR}$" SHASUMS256.txt | sha256sum -c -)
tar -xJf "$WORK/$NODE_TAR" -C "$ROOTFS/usr/local" --strip-components=1

sudo apt-get update -qq
sudo apt-get install -y -qq qemu-user-static binfmt-support
if command -v update-binfmts >/dev/null 2>&1; then sudo update-binfmts --enable qemu-aarch64 || true; fi
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

sudo chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends ca-certificates curl git openssh-client bash coreutils findutils grep sed tar xz-utils procps; rm -rf /var/lib/apt/lists/*'
sudo chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -lc "node --version && npm --version && npm install -g --omit=dev @deepseek-ai/dsh@${DSH_VERSION}"
sudo chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -lc 'dsh --version || true; command -v dsh; command -v node'

sudo rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
sudo rm -f "$ROOTFS/etc/resolv.conf"
sudo mkdir -p "$ROOTFS/root/.cache" "$ROOTFS/root/.config" "$ROOTFS/root/.local/share/dsh" "$ROOTFS/tmp" "$ROOTFS/var/tmp"
sudo chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"
echo "DSHion Ubuntu 24.04 ARM64 / Node ${NODE_VERSION} / dsh ${DSH_VERSION}" | sudo tee "$ROOTFS/etc/dshion-image" >/dev/null
sudo tar -C "$ROOTFS" --numeric-owner -cJf "$ASSET_DIR/ubuntu-rootfs-arm64.tar.xz" .
ls -lh "$ASSET_DIR/ubuntu-rootfs-arm64.tar.xz"
