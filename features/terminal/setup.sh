#!/usr/bin/env bash
#
# The terminal feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
test -x /usr/bin/fish
test -x /usr/bin/ghostty
test -x /usr/bin/fastfetch
grep -qx /usr/bin/fish /etc/shells
# ghostty's COPR (overlay/etc/yum.repos.d/), which image/packages.sh read.
test -s /etc/yum.repos.d/ghostty-copr.repo
