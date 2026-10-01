#!/usr/bin/env bash
#
# Image build, part 2, run after `COPY overlay/ /`: service config, generated
# compositor configs, and the build-time assertions. Kept separate from
# packages.sh so that editing overlay/ only re-runs this (seconds), not the
# package layer.
#
set -euxo pipefail

CTX=${CTX:-/ctx}

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
#    missing.
if ! grep -q pam_gnome_keyring /etc/pam.d/xrdp-sesman; then
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
# Like the startwm.sh rule above, it lives in /etc/selinux: a machine where
# `semanage fcontext` was run by hand keeps its own file_contexts.local on
# update and needs this line run there once (the boot relabel would otherwise
# put var_lib_t back). `matchpathcon /var/lib/noctalia-greeter` tells.
semanage fcontext -a -t xdm_var_lib_t '/var/lib/noctalia-greeter(/.*)?'

# --- niri: the image's default config -----------------------------------------
# niri reads /etc/niri/config.kdl when the user has no ~/.config/niri/config.kdl,
# and then writes nothing into $HOME (niri wiki: Integrating niri). Generated
# from the packaged default so upstream's bindings keep arriving with package
# updates; only the programs it starts change: Noctalia instead of waybar
# (bar), fuzzel (launcher) and swaylock (lock screen), ghostty instead of
# alacritty. packages.sh keeps those four out of the image.
install -D -m0644 /usr/share/doc/niri/default-config.kdl /etc/niri/config.kdl
sed -i \
    -e 's|^// This line starts waybar.*|// The Noctalia shell: bar, launcher, notifications, lock screen, polkit agent.|' \
    -e 's|^spawn-at-startup "waybar"$|spawn-at-startup "noctalia"|' \
    -e 's|"Open a Terminal: alacritty" { spawn "alacritty"; }|"Open a Terminal: ghostty" { spawn "ghostty"; }|' \
    -e 's|"Run an Application: fuzzel" { spawn "fuzzel"; }|"Run an Application: noctalia" { spawn "noctalia" "msg" "panel-toggle" "launcher"; }|' \
    -e 's|"Lock the Screen: swaylock" { spawn "swaylock"; }|"Lock the Screen: noctalia" { spawn "noctalia" "msg" "session" "lock"; }|' \
    /etc/niri/config.kdl

# --- Wayfire: the image's config, derived from the packaged example -----------
# wayfire reads only ~/.config/wayfire.ini; overlay/usr/bin/wayfire-session
# passes this file with -c when the user has none. Derived from the packaged
# example (which enables the autostart, command, session-lock and
# foreign-toplevel plugins Noctalia needs) so upstream changes keep arriving.
# The programs it starts are replaced, not added: a repeated key would leave
# the example's own value in effect. Autostarts of programs the image does not
# ship (kanshi, mako, wlsunset) are commented out; mako would also compete with
# Noctalia's notifications.
install -D -m0644 /usr/share/doc/wayfire/wayfire.ini /usr/share/fedora-bootc/wayfire.ini
sed -i \
    -e 's/^autostart_wf_shell = true$/autostart_wf_shell = false/' \
    -e "s/^idle = swayidle before-sleep swaylock$/idle = swayidle before-sleep 'noctalia msg session lock'/" \
    -e 's/^command_terminal = .*/command_terminal = ghostty/' \
    -e 's/^command_launcher = .*/command_launcher = noctalia msg panel-toggle launcher/' \
    -e 's/^command_lock = .*/command_lock = noctalia msg session lock/' \
    -e 's/^command_logout = .*/command_logout = noctalia msg panel-toggle session/' \
    -e 's/^command_light_up = .*/command_light_up = brightnessctl --class=backlight set +5%/' \
    -e 's/^command_light_down = .*/command_light_down = brightnessctl --class=backlight set 5%-/' \
    -e 's/^\(outputs\|notifications\|gamma\) = /# &/' \
    /usr/share/fedora-bootc/wayfire.ini
# The Noctalia shell and a Secret Service, same as the labwc autostart.
sed -i '/^\[autostart\]/a noctalia_shell = noctalia\nsecret_service = /usr/bin/gnome-keyring-daemon --start --components=secrets' /usr/share/fedora-bootc/wayfire.ini

# --- Services ----------------------------------------------------------------
# overlay/usr/lib/systemd/system-preset/80-fedora-bootc.preset lists the units
# this image enables. Presets only apply when an RPM's %post runs, so apply
# them explicitly now that the file is in place.
units=$(sed -n 's/^enable //p' /usr/lib/systemd/system-preset/80-fedora-bootc.preset)
units_off=$(sed -n 's/^disable //p' /usr/lib/systemd/system-preset/80-fedora-bootc.preset)
systemctl preset $units $units_off
systemctl set-default graphical.target
# The same for user units, for every account.
user_units=$(sed -n 's/^enable //p' /usr/lib/systemd/user-preset/80-fedora-bootc.preset)
systemctl --global preset $user_units

# --- GTK defaults shipped in overlay/ ----------------------------------------
glib-compile-schemas /usr/share/glib-2.0/schemas

# --- Validate what we ship (fail the build, not the first login) -------------
# Cross-file contracts only: an unresolvable package name already fails
# packages.sh. The dotfiles are validated separately (`just check-image`, CI
# check.yml), never baked in.

# Flatpak: the remotes are configured, and nothing installs from them at boot
# (apps are installed per machine, packages/flatpaks.txt). The preinstall
# directories belong to the flatpak package, so assert they are empty.
test -f /usr/share/flatpak/remotes.d/flathub.flatpakrepo
test -f /usr/share/flatpak/remotes.d/devolutions.flatpakrepo
test -z "$(find /usr/share/flatpak/preinstall.d /etc/flatpak/preinstall.d -mindepth 1 2>/dev/null)"
test ! -e /usr/lib/systemd/system/flatpak-preinstall.service
# `systemctl preset` is silent about units it does not match, so check the result.
systemctl is-enabled $units
systemctl --global is-enabled $user_units
for unit in $units_off; do
    test "$(systemctl is-enabled "$unit" || true)" = disabled
done

# Cockpit: installed, off (above), and on loopback only when switched on. The
# firewall must not open it either.
test -x /usr/libexec/cockpit-ws
grep -qx 'ListenStream=127.0.0.1:9090' /usr/lib/systemd/system/cockpit.socket.d/10-localhost.conf
grep -qx 'ListenStream=' /usr/lib/systemd/system/cockpit.socket.d/10-localhost.conf
test -z "$(firewall-offline-cmd --list-services | grep -w cockpit)"
test -z "$(rpm -qa cockpit-packagekit cockpit-ostree)"
# The Metrics page stays off: its override adds a condition on a file that
# must not exist.
jq -e '.conditions[0]["path-exists"]' /etc/cockpit/metrics.override.json >/dev/null
test ! -e "$(jq -r '.conditions[0]["path-exists"]' /etc/cockpit/metrics.override.json)"

# The greeter: greetd owns display-manager.service, and every session it
# offers exists. labwc ships no session file (overlay/ provides it); river's
# and wayfire's are replaced by overlay/ to run the session wrappers.
test "$(readlink /etc/systemd/system/display-manager.service)" = /usr/lib/systemd/system/greetd.service
rpm -q noctalia-greeter >/dev/null                 # the RPM the `greeter` stage built
test -x /usr/bin/noctalia-greeter-session
test -f /usr/share/wayland-sessions/niri.desktop
test -f /usr/share/wayland-sessions/labwc.desktop  # shipped by overlay/, not by labwc
test -f /usr/share/wayland-sessions/sway.desktop
grep -qx 'Exec=river-session' /usr/share/wayland-sessions/river.desktop
grep -qx 'Exec=wayfire-session' /usr/share/wayland-sessions/wayfire.desktop
test -x /usr/bin/labwc
# labwc has no rpm-level dependency on Xwayland but refuses to start without it.
test -x /usr/bin/Xwayland
getent passwd greetd >/dev/null                    # the user overlay/etc/greetd/config.toml names
matchpathcon /var/lib/noctalia-greeter/sync.toml | grep -q ':xdm_var_lib_t:'   # see the label rule above
# labwc runs this script, not the XDG autostart entries: without it a session
# has no shell and no polkit agent.
test -s /etc/xdg/labwc/autostart
grep -q '^XKB_DEFAULT_LAYOUT=' /etc/xdg/labwc/environment
# labwc's default Super+Return runs lab-sensible-terminal, which honours
# $TERMINAL and otherwise picks the first terminal on its own list (ghostty
# is not on it).
grep -qx 'TERMINAL=ghostty' /etc/xdg/labwc/environment
# The boot splash: the theme kargs.d/30-quiet-boot.toml relies on (firmware
# logo, spinner, Fedora logo), and the unit that hides systemd-boot's menu.
test "$(plymouth-set-default-theme)" = bgrt
grep -qx 'ExecStart=/usr/bin/bootctl set-timeout menu-hidden' /usr/lib/systemd/system/hide-boot-menu.service
# What the Containerfile's group excludes keep out (a second desktop and
# LibreOffice), so a comps change fails the build instead of shipping them.
# (`! rpm -q ...` would be exempt from set -e, hence test -z.)
test -z "$(rpm -qa gdm gnome-shell mutter libreoffice-core)"
rpm -q polkit nautilus >/dev/null
# The weak dependencies packages.sh excludes are absent, and the generated niri
# and wayfire configs call Noctalia and ghostty in their place.
test -z "$(rpm -qa waybar fuzzel alacritty swaylock wf-shell foot wmenu)"
niri validate -c /etc/niri/config.kdl
grep -qx 'spawn-at-startup "noctalia"' /etc/niri/config.kdl
grep -q '{ spawn "ghostty"; }' /etc/niri/config.kdl
grep -q '{ spawn "noctalia" "msg" "panel-toggle" "launcher"; }' /etc/niri/config.kdl
grep -q '{ spawn "noctalia" "msg" "session" "lock"; }' /etc/niri/config.kdl
test -z "$(grep -E '"(waybar|fuzzel|alacritty|swaylock)"' /etc/niri/config.kdl)"
test -z "$(grep -vE '^\s*#' /usr/share/fedora-bootc/wayfire.ini | grep -E 'alacritty|swaylock|wofi|wlogout|kanshi|mako|wlsunset|= light ')"
test "$(grep -c '^command_terminal = ghostty$' /usr/share/fedora-bootc/wayfire.ini)" = 1
test "$(grep -c '^command_terminal = ' /usr/share/fedora-bootc/wayfire.ini)" = 1

# XRDP: the edits above took, and the session script is executable (a
# non-executable startwm.sh fails only at connect time).
grep -q '^AllowRootLogin=false' /etc/xrdp/sesman.ini
grep -qx 'DefaultWindowManager=/etc/xrdp/startwm.sh' /etc/xrdp/sesman.ini
grep -q 'pam_gnome_keyring' /etc/pam.d/xrdp-sesman
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
# Every compositor startwm.sh offers is installed. riverctl + rivertile prove
# it is river-classic, not the `river` 0.4 core.
test -x /usr/bin/labwc
test -x /usr/bin/niri
test -x /usr/bin/sway
test -x /usr/bin/river
test -x /usr/bin/riverctl
test -x /usr/bin/rivertile
test -x /usr/bin/wayfire
# sway's packaged config must keep the include our drop-in arrives through.
grep -q '^include /etc/sway/config.d/\*' /etc/sway/config
test -s /etc/sway/config.d/90-fedora-bootc.conf
# river: the wrapper, the image's init, and the packaged example it runs.
test -x /usr/bin/river-session
test -x /usr/libexec/fedora-bootc/river-init
test -x /usr/share/river/init.example
# wayfire: the wrapper and the config generated above.
test -x /usr/bin/wayfire-session
test -s /usr/share/fedora-bootc/wayfire.ini
grep -qx 'noctalia_shell = noctalia' /usr/share/fedora-bootc/wayfire.ini
grep -qx 'autostart_wf_shell = false' /usr/share/fedora-bootc/wayfire.ini
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
# No xrdp keys in the image (packages.sh deletes what its %posttrans made);
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

# SSH: password auth for non-root accounts, with a pre-auth legal notice.
# Asked of sshd rather than grepped, because drop-ins are first-match-wins and
# what matters is the value sshd ends up with. sshd needs a host key before it
# prints its config, hence the throwaway one.
ssh-keygen -q -t ed25519 -N '' -f /tmp/sshd-check
sshd -t -h /tmp/sshd-check
sshd_effective=$(sshd -T -h /tmp/sshd-check)
grep -qx 'permitrootlogin prohibit-password' <<<"$sshd_effective"
grep -qx 'passwordauthentication yes' <<<"$sshd_effective"
grep -qx 'permitemptypasswords no' <<<"$sshd_effective"
grep -qx 'banner /usr/share/fedora-bootc/ssh-banner' <<<"$sshd_effective"
test -s /usr/share/fedora-bootc/ssh-banner
rm -f /tmp/sshd-check /tmp/sshd-check.pub

# No private key where packages and build steps leave per-machine state: a
# scriptlet that generates one at install time ships it to every machine (the
# xrdp keys above were exactly that). PEM keys of any kind, plus the private
# exponent in xrdp's own rsakeys.ini format, which is not PEM. CI scans the
# whole image with trivy as well before pushing it (.github/actions/scan-image).
keys=$(grep -rlsIE -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' -e '^pri_exp=' \
    /etc /var /root /opt /usr/local || true)
test -z "$keys" || { printf 'private key in the image:\n%s\n' "$keys" >&2; exit 1; }

# fail2ban parses its own config, and our xrdp filter still matches what
# xrdp-sesexec logs ("AUTHFAIL: user=%s ip=%s time=%d"); a filter that matches
# nothing would leave RDP unguarded while looking configured.
fail2ban-client -t
printf 'AUTHFAIL: user=someone ip=203.0.113.9 time=1757100000\n' > /tmp/xrdp-probe.log
fail2ban-regex /tmp/xrdp-probe.log /etc/fail2ban/filter.d/xrdp.conf | grep -q '1 matched'
rm -f /tmp/xrdp-probe.log

# Virtual machines (packages.txt): libvirt's QEMU and network daemons as
# Fedora's presets enable them, the default NAT network set to autostart, and
# the libvirt group in /etc/group, where the installer looks for the groups
# it gives new accounts.
systemctl is-enabled virtqemud.socket virtnetworkd.socket >/dev/null
test -e /etc/libvirt/qemu/networks/autostart/default.xml
grep -q '^libvirt:' /etc/group

# Signature verification: the policy demands a cosign signature for every pull
# from the GHCR repo, so the key it names must exist and registries.d must
# enable sigstore attachments. Otherwise every `bootc upgrade` fails with
# "a signature was required".
test -s /etc/pki/containers/fedora-bootc.pub
grep -q 'sigstoreSigned' /etc/containers/policy.json
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/ghcr-fedora-bootc.yaml
keypath=$(sed -n 's/.*"keyPath": "\([^"]*\)".*/\1/p' /etc/containers/policy.json)
test -s "$keypath"

# The dotfiles in home/ never go into an image (.containerignore keeps them
# out of the build context), so none of their app configs may show up in
# /etc/skel.
for app in fish ghostty niri noctalia fastfetch mimeapps.list; do
    test ! -e "/etc/skel/.config/$app"
done
