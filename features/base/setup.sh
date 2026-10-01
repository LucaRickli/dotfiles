#!/usr/bin/env bash
#
# The base feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# useradd defaults (overlay/etc/default/useradd): fish for a plain useradd,
# homes under /var/home, where bootc keeps them (/home is a symlink to it).
grep -qx 'SHELL=/usr/bin/fish' /etc/default/useradd
grep -qx 'HOME=/var/home' /etc/default/useradd
test "$(readlink /home)" = var/home
