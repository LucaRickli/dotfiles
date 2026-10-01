#!/usr/bin/env bash
#
# The llm feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# shimmy runs, with its GPU engine built in (the crate's default features),
# and its user service is off by default and listens on loopback only.
shimmy --version | grep -q '^shimmy '
shimmy gpu-info | grep -q 'Enabled (WebGPU'
test "$(systemctl --global is-enabled shimmy.service || true)" = disabled
grep -qx 'ExecStart=/usr/bin/shimmy serve --bind 127.0.0.1:11435' /usr/lib/systemd/user/shimmy.service
