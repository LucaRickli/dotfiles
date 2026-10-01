#!/usr/bin/env bash
#
# The cockpit feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Cockpit: installed, off (its preset; image/finalize.sh checks that), and on
# loopback only when switched on. The firewall must not open it either.
test -x /usr/libexec/cockpit-ws
grep -qx 'ListenStream=127.0.0.1:9090' /usr/lib/systemd/system/cockpit.socket.d/10-localhost.conf
grep -qx 'ListenStream=' /usr/lib/systemd/system/cockpit.socket.d/10-localhost.conf
test -z "$(firewall-offline-cmd --list-services | grep -w cockpit)"
test -z "$(rpm -qa cockpit-packagekit cockpit-ostree)"
# The Metrics page stays off: its override adds a condition on a file that
# must not exist.
jq -e '.conditions[0]["path-exists"]' /etc/cockpit/metrics.override.json >/dev/null
test ! -e "$(jq -r '.conditions[0]["path-exists"]' /etc/cockpit/metrics.override.json)"
