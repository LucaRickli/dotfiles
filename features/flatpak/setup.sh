#!/usr/bin/env bash
#
# The flatpak feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Flatpak: the remotes are configured, and nothing installs from them at boot
# (apps are installed per machine, flatpaks.txt). The preinstall
# directories belong to the flatpak package, so assert they are empty.
test -f /usr/share/flatpak/remotes.d/flathub.flatpakrepo
test -f /usr/share/flatpak/remotes.d/devolutions.flatpakrepo
test -z "$(find /usr/share/flatpak/preinstall.d /etc/flatpak/preinstall.d -mindepth 1 2>/dev/null)"
test ! -e /usr/lib/systemd/system/flatpak-preinstall.service
