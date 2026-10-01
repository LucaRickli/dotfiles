#!/usr/bin/env bash
#
# The locale feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Swiss German keyboard everywhere, Zurich time.
test "$(readlink /etc/localtime)" = ../usr/share/zoneinfo/Europe/Zurich
test -e /etc/localtime
grep -qx 'KEYMAP=ch' /etc/vconsole.conf
grep -q '"XkbLayout" "ch"' /etc/X11/xorg.conf.d/00-keyboard.conf
