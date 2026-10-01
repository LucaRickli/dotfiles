#!/usr/bin/env bash
#
# The kernel-build feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# What a kernel module build calls (kbuild, akmods).
for tool in pahole bc flex bison perl depmod; do
    command -v "$tool" >/dev/null
done
