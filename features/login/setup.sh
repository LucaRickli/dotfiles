#!/usr/bin/env bash
#
# The login feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: label the greeter's state dir
# for SELinux, then its checks (the marked section at the end).
#
set -euxo pipefail

# --- noctalia-greeter: the SELinux label of its state dir ---------------------
# greetd runs the greeter as xdm_t. The policy has no rule for its state dir,
# /var/lib/noctalia-greeter, so it would be var_lib_t, and so would a file
# Noctalia's appearance sync writes there (pkexec
# noctalia-greeter-apply-appearance stays in the user's unconfined_t). The
# greeter can read such a file but not replace it: every later save of
# sync.toml fails ("failed to replace ... Permission denied", an unlink AVC),
# and a colour scheme picked at the login screen does not stick. Labelled like
# greetd's own state (/var/lib/greetd), whatever is created in it inherits
# xdm_var_lib_t. tmpfiles.d creates the dir with this label and relabels an
# existing one at boot (overlay/usr/lib/tmpfiles.d/noctalia-greeter.conf).
# Like xrdp's startwm.sh rule (features/xrdp/setup.sh), it lives in /etc/selinux: a machine where
# `semanage fcontext` was run by hand keeps its own file_contexts.local on
# update and needs this line run there once (the boot relabel would otherwise
# put var_lib_t back). `matchpathcon /var/lib/noctalia-greeter` tells.
semanage fcontext -a -t xdm_var_lib_t '/var/lib/noctalia-greeter(/.*)?'

# --- Checks -----------------------------------------------------------------
# The greeter: greetd owns display-manager.service (its preset), and the
# greeter is installed.
test "$(readlink /etc/systemd/system/display-manager.service)" = /usr/lib/systemd/system/greetd.service
rpm -q noctalia-greeter >/dev/null                 # the RPM build.sh made
test -x /usr/bin/noctalia-greeter-session
getent passwd greetd >/dev/null                    # the user overlay/etc/greetd/config.toml names
matchpathcon /var/lib/noctalia-greeter/sync.toml | grep -q ':xdm_var_lib_t:'   # see the label rule above
