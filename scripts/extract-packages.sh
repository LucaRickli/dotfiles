#!/usr/bin/env bash

set -euo pipefail

# ---
# This script extracts package names from a file,
# ignoring comments and empty lines, and prints them
# as space-separated lists.
# ---

pkgList=()

for pkg in $(grep -v '^\s*#' "$1" | grep -v '^\s*$'); do
  pkgList+=("$pkg")
done

echo "${pkgList[@]}"
