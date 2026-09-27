#!/bin/sh
#
# What an XRDP session starts. sesman runs this after PAM has authenticated
# the user, so the RDP login IS the session login (no greeter, no separate RDP
# password). /etc/xrdp/sesman.ini points here via DefaultWindowManager, which
# must hold this ABSOLUTE path.
#
# --- why the desktop is not chosen on the xrdp login screen -------------------
#
# xrdp cannot do it (checked in the xrdp 0.10.6.1 source). A connection
# section's keys go to the display module (libxup) via mod_set_param, never to
# sesman; the create-session request that reaches sesman carries only type,
# geometry, bpp, shell and directory (xrdp_mm.c), and the shell is the client's
# own RDP Client Info field (libxrdp/xrdp_sec.c). sesman is chosen globally in
# sesman.ini. Several login-screen entries would all start the same desktop,
# so the image ships ONE entry and the choice is made here.
#
# --- how the desktop IS chosen ------------------------------------------------
#
#   1. XRDP_ALTERNATE_SHELL: the client's "alternate shell" field, handed in
#      as an env var by sesman.ini (AllowAlternateShell + PassShellAsEnv).
#      Remmina: Advanced > "Start-up program". xfreerdp: /shell:<name>.
#      Validated against the list below and NEVER executed.
#   2. ~/.config/xrdp-session: a persistent per-user default (one word).
#   3. otherwise labwc: plain stacking, no GPU required.
#
# Output goes to ~/.xrdp-session.log (truncated each session), so a session
# that dies leaves something to read. A session that dies the instant you log
# in, with nothing in that log, means this file lost its bin_t label:
# `ls -Z /etc/xrdp/startwm.sh` shows it, `sudo restorecon -v` restores it.

exec > "$HOME/.xrdp-session.log" 2>&1
echo "=== xrdp session start: $(date) ==="

test -r /etc/profile && . /etc/profile
test -r "$HOME/.profile" && . "$HOME/.profile"

# A leaked WAYLAND_DISPLAY (from a profile, or a console session for the same
# user) would send the nested compositor at the wrong Wayland socket. Clear it.
unset WAYLAND_DISPLAY

DEFAULT_SESSION=labwc
session=""

# 2. persistent per-user choice
if [ -r "$HOME/.config/xrdp-session" ]; then
    read -r choice < "$HOME/.config/xrdp-session" || choice=""
    case $choice in
        niri|labwc|sway|river|wayfire)
            session=$choice
            echo "xrdp: ~/.config/xrdp-session selects '$session'" ;;
        *) echo "xrdp: ignoring unknown ~/.config/xrdp-session '$choice'" ;;
    esac
fi

# 1. the client's alternate shell, which outranks it
case ${XRDP_ALTERNATE_SHELL:-} in
    niri|labwc|sway|river|wayfire)
        session=$XRDP_ALTERNATE_SHELL
        echo "xrdp: client alternate shell selects '$session'" ;;
    "") ;;
    *) echo "xrdp: ignoring unknown alternate shell '$XRDP_ALTERNATE_SHELL'" ;;
esac

# 3. otherwise the default
if [ -z "$session" ]; then
    session=$DEFAULT_SESSION
    echo "xrdp: no explicit choice, using the default '$session'"
fi
echo "xrdp: starting '$session'"

# --- make the desktop follow the RDP client's window size --------------------
#
# The client's resize request (the "disp" channel, MS-RDPEDISP) reaches the
# nested X screen via xorgxrdp and RandR. The last hop does not: a wlroots
# X11-backend compositor creates its output window at a HARDCODED 1024x768 and
# never looks at the X screen again.
#
# wlroots does handle ConfigureNotify on that window, so resizing the window to
# match the X screen makes the compositor follow. The window has no name, class
# or PID, so it is identified structurally: xorgxrdp owns exactly one window
# before the compositor starts, and the compositor adds one more.
#
# niri is smithay/winit, not wlroots, and sizes itself from the X display.
resize_watcher() {
    known=$(xdotool search --all --name "" 2>/dev/null | tr '\n' ' ')
    win=""
    i=0
    while [ $i -lt 60 ]; do
        for w in $(xdotool search --all --name "" 2>/dev/null); do
            case " $known " in
                *" $w "*) ;;
                *) win=$w ;;
            esac
        done
        [ -n "$win" ] && break
        i=$((i + 1))
        sleep 0.25
    done
    if [ -z "$win" ]; then
        echo "xrdp: no compositor window found, not syncing size"
        return
    fi
    echo "xrdp: syncing compositor window $win to the X screen size"
    last=""
    while kill -0 "$1" 2>/dev/null; do
        size=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
        case $size in
            [0-9]*x[0-9]*)
                if [ "$size" != "$last" ]; then
                    w=${size%x*}
                    h=${size#*x}
                    xdotool windowsize "$win" "$w" "$h" 2>/dev/null &&
                        echo "xrdp: resized desktop to ${w}x${h}"
                    last=$size
                fi
                ;;
        esac
        sleep 1
    done
}

# The shell (bar, launcher, notifications, polkit agent) comes from each
# compositor's own autostart, as on a local login.
#
# Software rendering is forced for the WLROOTS compositors. xorgxrdp's Xorg
# offers a DRI3 render node on real hardware; wlroots would then commit to
# GLES2/EGL on the GPU and try to present those buffers back through xorgxrdp's
# DRI3 (v1.0, implicit modifiers), which fails on many GPUs and takes the whole
# session with it. pixman is wlroots' pure-CPU renderer and never opens a render
# node; xorgxrdp H.264-encodes the framebuffer either way. Local console logins
# never run this script and keep full GPU acceleration.
case $session in
    labwc|sway|river|wayfire)
        export WLR_RENDERER=pixman
        export WLR_RENDERER_ALLOW_SOFTWARE=1
        export LIBGL_ALWAYS_SOFTWARE=1
        export WLR_BACKENDS=x11
        # river and wayfire start through their session wrappers (the greeter
        # uses the same ones), which supply an init/config when the user has
        # none; labwc and sway need no wrapper (labwc autostarts from
        # /etc/xdg/labwc, sway from /etc/sway/config.d).
        case $session in
            river|wayfire) "$session-session" & ;;
            *)             "$session" & ;;
        esac
        wm=$!
        resize_watcher "$wm" &
        wait "$wm"
        ;;
    niri)
        # niri has no software renderer: its winit backend needs a working EGL,
        # so it is only usable over RDP where xorgxrdp exposes a render node.
        # Do NOT force software here, or it cannot start at all.
        exec niri
        ;;
esac
