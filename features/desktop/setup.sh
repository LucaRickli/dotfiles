#!/usr/bin/env bash
#
# The desktop feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: compile the GSettings defaults
# it ships, then its checks (the marked section at the end).
#
set -euxo pipefail

glib-compile-schemas /usr/share/glib-2.0/schemas

# --- Checks -----------------------------------------------------------------
# The compiled default (overlay/'s zz0-custom.gschema.override) is what an
# account without its own setting gets.
test "$(GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.interface color-scheme)" = "'prefer-dark'"
test -x /usr/bin/noctalia
rpm -q nautilus polkit >/dev/null
