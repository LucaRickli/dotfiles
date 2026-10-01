#!/usr/bin/env bash
#
# Runs in the package layer, right after dnf (image/packages.sh): xrdp's
# %posttrans creates its private keys (the TLS pair key.pem/cert.pem and the
# RDP-security RSA key rsakeys.ini) when they are missing. Here that is at
# image build time, so every machine would share one set, published with the
# image. Deleted in this same RUN, so they never reach a layer; each machine
# generates its own before xrdp starts (overlay/usr/libexec/fedora-bootc/
# xrdp-keygen). setup.sh checks they are gone, and image/finalize.sh that no
# private key is left where per-machine state lives; CI's scan covers the
# whole image (.github/actions/scan-image).
set -euxo pipefail

rm -f /etc/xrdp/key.pem /etc/xrdp/cert.pem /etc/xrdp/rsakeys.ini
