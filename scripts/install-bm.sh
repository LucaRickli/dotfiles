#!/usr/bin/env bash

set -euo pipefail

# ---
# This script installs bm, used to manage binaries, if it's not already installed.
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_RELEASES=$(realpath "$BASE_DIR/../packages/binary.yaml")

log="$BASE_DIR/log.sh"

if command -v bm &>/dev/null; then
  $log info "bm already installed, skipping."
  exit 0
fi

$log info "Installing bm (binary manager)..."

sudo pacman -S --needed --noconfirm curl

tmpdir=$(mktemp -d)

curl -Lo "$tmpdir/bm" https://github.com/LucaRickli/bm/releases/download/0.1.0/bm-linux-amd64

sudo mv "$tmpdir/bm" /usr/local/bin/bm
sudo chmod +x /usr/local/bin/bm

rm -rf "$tmpdir"

$log info "bm installed."
