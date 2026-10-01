#!/usr/bin/env bash
#
# The containers feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
test -x /usr/bin/docker
test -x /usr/bin/podman
# In /etc/group, where the installer looks for the groups it gives new
# accounts (its fixed list has docker).
grep -q '^docker:' /etc/group
