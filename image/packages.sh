#!/usr/bin/env bash
#
# Image build, part 1: the packages from packages/packages.txt. (Part 2,
# image/finalize.sh, runs after overlay/ is copied in.)
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

# --- Keys the packages generated for "this machine" ---------------------------
# xrdp's %posttrans creates its private keys (the TLS pair key.pem/cert.pem and
# the RDP-security RSA key rsakeys.ini) when they are missing. Here that is at
# image build time, so every machine would share one set, published with the
# image. Deleted in this same RUN, so they never reach a layer; each machine
# generates its own before xrdp starts (overlay/usr/libexec/fedora-bootc/
# xrdp-keygen). finalize.sh asserts no private key is left where per-machine
# state lives; CI's scan covers the whole image (.github/actions/scan-image).
rm -f /etc/xrdp/key.pem /etc/xrdp/cert.pem /etc/xrdp/rsakeys.ini

# --- Cleanup: keep /var free of build leftovers (bootc container lint) ------
dnf -y clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/roothome/.cache /var/tmp/* /tmp/*
