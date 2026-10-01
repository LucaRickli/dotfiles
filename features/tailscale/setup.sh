#!/usr/bin/env bash
#
# The tailscale feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
test -x /usr/bin/tailscale
# Installed but off: no preset enables it.
test "$(systemctl is-enabled tailscaled.service || true)" = disabled
