#!/usr/bin/env bash
#
# The xrdp feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: edit xrdp's packaged config,
# then its checks (the marked section at the end).
#
set -euxo pipefail

# --- XRDP: remote login that behaves like a local one -------------------------
# Targeted edits to files the xrdp package owns, so package updates to them
# keep arriving; only the lines below are ours.
#
# 1. No root over RDP.
sed -i 's/^AllowRootLogin=true/AllowRootLogin=false/' /etc/xrdp/sesman.ini
# 2. Start our session script (overlay/etc/xrdp/startwm.sh). The path must be
#    absolute: sesman resolves a bare file name against its own libexec
#    directory and would silently run the packaged /usr/libexec/xrdp/startwm.sh,
#    which finds no X11 desktop and ends the session right after login.
sed -i 's|^DefaultWindowManager=.*|DefaultWindowManager=/etc/xrdp/startwm.sh|' /etc/xrdp/sesman.ini
# 2b. Label it bin_t. In /etc the policy default is etc_t, which xrdp-sesexec
#    cannot execve under enforcing SELinux: the session dies the instant you
#    authenticate ("Xorg server closed connection"). Only visible on a real
#    enforcing install, never in a container. A persistent fcontext rule, so
#    the deploy-time relabel keeps it.
semanage fcontext -a -t bin_t '/etc/xrdp/startwm\.sh'
restorecon -v /etc/xrdp/startwm.sh
# 3. Unlock the login keyring with the password just typed, so a remote
#    session does not prompt again for secrets. `-` = skip if the module is
#    missing. Appended to the packaged stack, which must be in /etc/pam.d: a
#    file there shadows one in /usr/lib/pam.d, so appending to a missing one
#    would replace xrdp's whole stack with these two lines.
grep -qE '^auth\s+include\s+password-auth' /etc/pam.d/xrdp-sesman
if ! grep -qE '^-auth\s+optional\s+pam_gnome_keyring\.so' /etc/pam.d/xrdp-sesman; then
    printf '%s\n%s\n' \
        '-auth       optional     pam_gnome_keyring.so' \
        '-session    optional     pam_gnome_keyring.so auto_start' \
        >> /etc/pam.d/xrdp-sesman
fi
# 4. One session type, named "desktop". Of the stock three only the xorgxrdp
#    one works here (Xvnc needs a VNC server, neutrinordp-any proxies to
#    another host), so the last two sections are deleted and Xorg is renamed
#    and autorun. It is not named after a compositor because an entry cannot
#    choose one: sesman only gets a session type, a geometry and the client's
#    alternate-shell string (see startwm.sh).
sed -i '/^\[Xvnc\]/,$d' /etc/xrdp/xrdp.ini
sed -i 's/^\[Xorg\]/[desktop]/; s/^name=Xorg$/name=desktop/; s/^autorun=.*$/autorun=desktop/' /etc/xrdp/xrdp.ini
# 5. Let the RDP client pick the compositor: its "alternate shell" string is
#    NOT executed but handed to startwm.sh as $XRDP_ALTERNATE_SHELL, which only
#    accepts the five session names. Both settings are required together:
#    AllowAlternateShell without PassShellAsEnv makes sesexec EXECUTE the
#    client-supplied string.
sed -i 's/^#\?AllowAlternateShell=.*/AllowAlternateShell=true/' /etc/xrdp/sesman.ini
sed -i 's/^#\?PassShellAsEnv=.*/PassShellAsEnv=XRDP_ALTERNATE_SHELL/' /etc/xrdp/sesman.ini
# 6. Open 3389 (firewalld's public zone only allows ssh and dhcpv6-client).
firewall-offline-cmd --add-service=rdp

# --- Checks -----------------------------------------------------------------
# XRDP: the edits above took, and the session script is executable (a
# non-executable startwm.sh fails only at connect time).
grep -q '^AllowRootLogin=false' /etc/xrdp/sesman.ini
grep -qx 'DefaultWindowManager=/etc/xrdp/startwm.sh' /etc/xrdp/sesman.ini
grep -qE '^auth\s+include\s+password-auth' /etc/pam.d/xrdp-sesman
grep -qE '^-auth\s+optional\s+pam_gnome_keyring\.so$' /etc/pam.d/xrdp-sesman
grep -qE '^-session\s+optional\s+pam_gnome_keyring\.so auto_start$' /etc/pam.d/xrdp-sesman
test -x /etc/xrdp/startwm.sh
# The DEPLOYED label will be bin_t (matchpathcon reads the fcontext rules,
# including the local one added above). The one check that catches the
# session-dies-at-login bug; keep it.
matchpathcon /etc/xrdp/startwm.sh | grep -q ':bin_t:'
test -f /usr/lib64/security/pam_gnome_keyring.so   # the module the PAM line needs
grep -qx 'autorun=desktop' /etc/xrdp/xrdp.ini
grep -qx '\[desktop\]' /etc/xrdp/xrdp.ini
test -z "$(grep -E '^\[(Xorg|Xvnc|neutrinordp-any)\]' /etc/xrdp/xrdp.ini)"
grep -qx 'AllowAlternateShell=true' /etc/xrdp/sesman.ini
grep -qx 'PassShellAsEnv=XRDP_ALTERNATE_SHELL' /etc/xrdp/sesman.ini
# Software rendering for the wlroots compositors over RDP (see startwm.sh).
grep -qE 'export WLR_RENDERER=pixman' /etc/xrdp/startwm.sh
grep -qE 'export LIBGL_ALWAYS_SOFTWARE=1' /etc/xrdp/startwm.sh
# The resize watcher's tools.
test -x /usr/bin/xdotool
test -x /usr/bin/xdpyinfo
# xrdp-selinux carries the rules that let sesexec transition the session to
# unconfined_t; without the module the Xorg execve is denied under enforcing.
rpm -q xrdp-selinux >/dev/null
semodule -l | grep -qx xrdp
firewall-offline-cmd --query-service=rdp
# No xrdp keys in the image (post-install.sh deletes what its %posttrans made);
# every machine makes its own, and xrdp does not start without them
# (Requires=).
test ! -e /etc/xrdp/key.pem
test ! -e /etc/xrdp/cert.pem
test ! -e /etc/xrdp/rsakeys.ini
test -x /usr/libexec/fedora-bootc/xrdp-keygen
grep -qx 'ExecStart=/usr/libexec/fedora-bootc/xrdp-keygen' /usr/lib/systemd/system/xrdp-keygen.service
grep -qx 'Requires=xrdp-keygen.service' /usr/lib/systemd/system/xrdp.service.d/10-keygen.conf
grep -qx 'After=xrdp-keygen.service' /usr/lib/systemd/system/xrdp.service.d/10-keygen.conf
test -x /usr/bin/xrdp-keygen
test -s /etc/xrdp/openssl.conf
