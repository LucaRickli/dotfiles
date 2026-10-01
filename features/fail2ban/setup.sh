#!/usr/bin/env bash
#
# The fail2ban feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# fail2ban parses its own config, and our xrdp filter still matches what
# xrdp-sesexec logs ("AUTHFAIL: user=%s ip=%s time=%d"); a filter that matches
# nothing would leave RDP unguarded while looking configured.
fail2ban-client -t
printf 'AUTHFAIL: user=someone ip=203.0.113.9 time=1757100000\n' > /tmp/xrdp-probe.log
fail2ban-regex /tmp/xrdp-probe.log /etc/fail2ban/filter.d/xrdp.conf | grep -q '1 matched'
rm -f /tmp/xrdp-probe.log
