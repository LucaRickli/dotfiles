#!/usr/bin/env bash
#
# The sessions feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: generate the image's niri and
# wayfire configs from the packaged defaults, then its checks (the marked
# section at the end).
#
set -euxo pipefail

# --- niri: the image's default config -----------------------------------------
# niri reads /etc/niri/config.kdl when the user has no ~/.config/niri/config.kdl,
# and then writes nothing into $HOME (niri wiki: Integrating niri). Generated
# from the packaged default so upstream's bindings keep arriving with package
# updates; only the programs it starts change: Noctalia instead of waybar
# (bar), fuzzel (launcher) and swaylock (lock screen), ghostty instead of
# alacritty. pkg.yml keeps those four out of the image.
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

# --- Checks -----------------------------------------------------------------
# Every session the greeter offers exists. labwc ships no session file
# (overlay/ provides it); river's and wayfire's are replaced by overlay/ to
# run the session wrappers.
test -f /usr/share/wayland-sessions/niri.desktop
test -f /usr/share/wayland-sessions/labwc.desktop  # shipped by overlay/, not by labwc
test -f /usr/share/wayland-sessions/sway.desktop
grep -qx 'Exec=river-session' /usr/share/wayland-sessions/river.desktop
grep -qx 'Exec=wayfire-session' /usr/share/wayland-sessions/wayfire.desktop
test -x /usr/bin/labwc
# labwc has no rpm-level dependency on Xwayland but refuses to start without it.
test -x /usr/bin/Xwayland
# labwc runs this script, not the XDG autostart entries: without it a session
# has no shell and no polkit agent.
test -s /etc/xdg/labwc/autostart
grep -q '^XKB_DEFAULT_LAYOUT=' /etc/xdg/labwc/environment
# labwc's default Super+Return runs lab-sensible-terminal, which honours
# $TERMINAL and otherwise picks the first terminal on its own list (ghostty
# is not on it).
grep -qx 'TERMINAL=ghostty' /etc/xdg/labwc/environment
# The weak dependencies pkg.yml excludes are absent, and the generated niri
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
# sway's packaged config must keep the include our drop-in arrives through.
grep -q '^include /etc/sway/config.d/\*' /etc/sway/config
test -s /etc/sway/config.d/90-fedora-bootc.conf
# river: river-classic (riverctl and rivertile; not the `river` 0.4 core),
# the wrapper, the image's init, and the packaged example it runs.
test -x /usr/bin/riverctl
test -x /usr/bin/rivertile
test -x /usr/bin/river-session
test -x /usr/libexec/fedora-bootc/river-init
test -x /usr/share/river/init.example
# wayfire: the wrapper and the config generated above.
test -x /usr/bin/wayfire-session
test -s /usr/share/fedora-bootc/wayfire.ini
grep -qx 'noctalia_shell = noctalia' /usr/share/fedora-bootc/wayfire.ini
grep -qx 'autostart_wf_shell = false' /usr/share/fedora-bootc/wayfire.ini
