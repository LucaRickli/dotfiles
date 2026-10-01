#!/usr/bin/env bash
#
# The boot feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# The boot splash: the theme kargs.d/30-quiet-boot.toml relies on (firmware
# logo, spinner, Fedora logo), and the unit that hides systemd-boot's menu.
test "$(plymouth-set-default-theme)" = bgrt
grep -qx 'ExecStart=/usr/bin/bootctl set-timeout menu-hidden' /usr/lib/systemd/system/hide-boot-menu.service
