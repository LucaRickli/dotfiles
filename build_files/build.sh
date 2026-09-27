#!/usr/bin/env bash
#
# Image build, part 1: the packages from packages/packages.txt and the bm
# binaries. (Part 2, build_files/finalize.sh, runs after overlay/ is copied in.)
# Runs inside `podman build` (see Containerfile) with the repo bind-mounted at /ctx.
#
set -euxo pipefail

CTX=${CTX:-/ctx}

# Package list files: one package per line, `#` comments and blank lines ignored.
pkgs() { grep -hvE '^\s*(#|$)' "$@"; }

# --- Packages ----------------------------------------------------------------
# One transaction. Third-party packages come from the .repo files in
# overlay/etc/yum.repos.d/, copied in just before this script; `dnf -y`
# imports each repo's gpgkey= on first use. noctalia-greeter is the RPM the
# Containerfile's `greeter` stage built, mounted at /run/greeter.
#
# The excludes are weak dependencies that would only duplicate Noctalia and
# ghostty: niri's upstream defaults (waybar, fuzzel, alacritty, swaylock),
# wayfire's wf-shell, and sway's foot and wmenu. The configs that referenced
# them are pointed at Noctalia and ghostty instead (finalize.sh,
# overlay/etc/xdg/labwc/environment, overlay/etc/sway/config.d/, river-init).
# Excluding rather than disabling weak deps altogether, because much else
# here relies on them (noctalia's upower, gnome-control-center's
# NetworkManager-wifi, ...).
dnf -y install \
    --exclude=waybar --exclude=fuzzel --exclude=alacritty --exclude=swaylock \
    --exclude=wf-shell --exclude=foot --exclude=wmenu \
    $(pkgs "$CTX"/packages/packages.txt) /run/greeter/noctalia-greeter-*.rpm

# --- Binaries managed by bm (packages/binary.yaml) ---------------------------
# CI fetches and verifies these in a job of their own (the `bm` job in
# build.yml) and hands the result in as a /run/bundle.tar volume: release
# downloads are the flakiest part of a build, so they happen where a retry
# costs seconds and a cached bundle skips them entirely. The tar mirrors the
# filesystem (usr/bin/...), so unpacking it IS the install; bm verified every
# file when the bundle was built. --no-same-owner, because the tar was created
# by the runner user and these files must be root's.
if [ -f /run/bundle.tar ]; then
    tar -xf /run/bundle.tar -C / --no-same-owner
else
    # No bundle (a local build): sync directly. Bootstrap bm outside /usr/bin
    # (binary.yaml installs /usr/bin/bm itself and would otherwise overwrite a
    # running executable), checksum-verified, and retried like the sync below:
    # GitHub resets connections mid-download often enough to matter, and the
    # bootstrap download has failed builds before, not just the releases.
    bm_url=$(yq -r '.releases[] | select(.id == "bm") | .src' "$CTX/packages/binary.yaml")
    bm_sum=$(yq -r '.releases[] | select(.id == "bm") | .integrity.signature' "$CTX/packages/binary.yaml")
    for attempt in 1 2 3; do
        if curl -fsSL -o /tmp/bm "$bm_url" \
           && echo "$(curl -fsSL "$bm_sum" | awk '{print $1}')  /tmp/bm" | sha256sum -c -; then
            break
        fi
        [ "$attempt" = 3 ] && { echo "bm bootstrap failed after 3 attempts" >&2; exit 1; }
        echo "bm bootstrap attempt $attempt failed, retrying in 10s" >&2
        sleep 10
    done
    chmod +x /tmp/bm
    # bm has no retry of its own and one failed release fails the whole build.
    # `bm sync` reconciles against binary.yaml, so re-running it is safe.
    for attempt in 1 2 3; do
        if /tmp/bm sync -c "$CTX/packages/binary.yaml"; then break; fi
        [ "$attempt" = 3 ] && { echo "bm sync failed after 3 attempts" >&2; exit 1; }
        echo "bm sync attempt $attempt failed, retrying in 10s" >&2
        sleep 10
    done
    rm -f /tmp/bm
fi
test -x /usr/bin/bm && test -x /usr/bin/kubectl

# --- Cleanup: keep /var free of build leftovers (bootc container lint) ------
dnf -y clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/roothome/.cache /var/tmp/* /tmp/*
