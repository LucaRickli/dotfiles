#!/usr/bin/env bash

set -euo pipefail

# ---
# This script installs / updates binaries from urls
# based on packages/binary/<releases>.yaml files.
# ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_RELEASES=$(realpath "$BASE_DIR/../packages/binary")

log="$BASE_DIR/log.sh"

find "$BINARY_RELEASES" -name "*.yaml" | while read -r file; do
  src=$(yq -r '.src' "$file")
  dst=$(yq -r '.dst' "$file")
  process=$(yq -r '.process // ""' "$file")

  tmpdir=$(mktemp -d)
  tmpfile="$tmpdir/$(basename $dst)"

  curl -Lo $tmpfile $src

  if [ ! -f $tmpfile ]; then
    rm -rf $tmpdir
    $log error "Failed to download '$src'"
    continue
  fi

  if [ ! -z "$process" ]; then
    $log warn "Processing '$tmpfile' with '$process'"
    eval $process
  fi

  sudo mv $tmpfile $dst
  sudo chmod +x $dst

  rm -rf $tmpdir

  $log info "Installed '$dst' from '$src'"
done
