#!/usr/bin/env bash
#
# Image build, part 2, for one set of features (the base, or an add-on on top
# of it), run after the set's overlay/ trees are copied in: the services the
# presets name, each feature's setup.sh, then checks of the image as a whole.
# Kept separate from packages.sh so that editing a feature's files or setup
# only re-runs this (seconds), not the package layer.
#
set -euxo pipefail

CTX=${CTX:-/ctx}
shopt -s nullglob

# --- Builds and overlays -------------------------------------------------------
# No file both built (image/builds.sh lists them) and in any feature's
# overlay/, add-ons included (image/features.sh lists those):
# image/base.Containerfile copies the built files after the base overlays,
# and image/addon.Containerfile an add-on's overlay after both, so one of the
# two would silently lose. Only the base run has the lists.
if [ -e "$CTX/root-paths.txt" ]; then
    both=$(LC_ALL=C comm -12 "$CTX/root-paths.txt" "$CTX/overlay-paths.txt")
    test -z "$both" || { printf 'built and in an overlay/:\n%s\n' "$both" >&2; exit 1; }
fi

# --- Services ----------------------------------------------------------------
# Each feature lists the units it enables or disables in its own
# usr/lib/systemd/{system,user}-preset/80-fedora-bootc-<feature>.preset.
# Presets only apply when an RPM's %post runs, so apply them now: all of
# them in the image, so an add-on's run re-applies and re-checks the base's.
# First, because the features' checks read the result (greetd's
# display-manager alias, for one). sed reads /dev/null first so that no preset at all (no
# feature with user services, say) is an empty list, not an error.
presets=(/usr/lib/systemd/system-preset/80-fedora-bootc-*.preset)
user_presets=(/usr/lib/systemd/user-preset/80-fedora-bootc-*.preset)
units=$(sed -n 's/^enable //p' /dev/null "${presets[@]}")
units_off=$(sed -n 's/^disable //p' /dev/null "${presets[@]}")
user_units=$(sed -n 's/^enable //p' /dev/null "${user_presets[@]}")
if [ -n "$units$units_off" ]; then
    # shellcheck disable=SC2086  # one unit per word
    systemctl preset $units $units_off
fi
if [ -n "$user_units" ]; then
    # shellcheck disable=SC2086
    systemctl --global preset $user_units
fi
systemctl set-default graphical.target
# `systemctl preset` is silent about units it does not match, and
# `is-enabled` with several units succeeds if any one is enabled, so check
# each unit's state on its own.
for unit in $units; do
    test "$(systemctl is-enabled "$unit")" = enabled
done
for unit in $user_units; do
    test "$(systemctl --global is-enabled "$unit")" = enabled
done
for unit in $units_off; do
    test "$(systemctl is-enabled "$unit" || true)" = disabled
done

# --- Features ----------------------------------------------------------------
# Each feature's setup.sh, in name order: what it needs at build time once its
# packages and files are in place, then the checks that prove it (fail the
# build, not the first login).
for setup in "$CTX"/features/*/setup.sh; do
    "$setup"
done

# --- The image as a whole -----------------------------------------------------
# What image/base.Containerfile's group excludes keep out (a second desktop
# and LibreOffice), so a comps change fails the build instead of shipping them.
# (`! rpm -q ...` would be exempt from set -e, hence test -z.)
test -z "$(rpm -qa gdm gnome-shell mutter libreoffice-core)"

# No private key where packages and build steps leave per-machine state: a
# scriptlet that generates one at install time ships it to every machine
# (xrdp's keys were exactly that, features/xrdp/post-install.sh). PEM keys of
# any kind, plus the private exponent in xrdp's own rsakeys.ini format, which
# is not PEM. CI scans the whole image with trivy as well before pushing it
# (.github/actions/scan-image).
keys=$(grep -rlsIE -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' -e '^pri_exp=' \
    /etc /var /root /opt /usr/local || true)
test -z "$keys" || { printf 'private key in the image:\n%s\n' "$keys" >&2; exit 1; }

# The dotfiles in home/ never go into an image (.containerignore keeps them
# out of the build context), so none of their app configs may show up in
# /etc/skel.
for app in fish ghostty niri noctalia fastfetch mimeapps.list; do
    test ! -e "/etc/skel/.config/$app"
done
