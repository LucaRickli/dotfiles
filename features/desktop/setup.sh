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
# gcr's SSH agent: on for every account (the preset; image/finalize.sh
# applies it), listening where overlay/etc/profile.d/gcr-ssh-agent.sh points
# SSH_AUTH_SOCK.
test "$(systemctl --global is-enabled gcr-ssh-agent.socket)" = enabled
grep -qx 'ListenStream=%t/gcr/ssh' /usr/lib/systemd/user/gcr-ssh-agent.socket
# shellcheck disable=SC2016  # expanded by the inner sh
test "$(env -u SSH_AUTH_SOCK XDG_RUNTIME_DIR=/nonexistent sh -c '. /etc/profile.d/gcr-ssh-agent.sh; echo "${SSH_AUTH_SOCK:-unset}"')" = unset
