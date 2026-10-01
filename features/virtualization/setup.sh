#!/usr/bin/env bash
#
# The virtualization feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Virtual machines (pkg.yml): libvirt's QEMU and network daemons as
# Fedora's presets enable them, the default NAT network set to autostart, and
# the libvirt group in /etc/group, where the installer looks for the groups
# it gives new accounts.
for unit in virtqemud.socket virtnetworkd.socket; do
    test "$(systemctl is-enabled "$unit")" = enabled
done
test -e /etc/libvirt/qemu/networks/autostart/default.xml
grep -q '^libvirt:' /etc/group
