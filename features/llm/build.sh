#!/usr/bin/env bash
#
# shimmy, the local LLM server, which Fedora does not package: built from
# crates.io at the version below, with the Cargo.lock it ships (--locked) and
# every crate checked against the registry's checksums. Run by
# image/builds.sh (see there), so the Rust toolchain never reaches the image.
# The binary lands in $OUT/root/usr/bin.
#
set -euxo pipefail

# renovate: datasource=crate depName=shimmy
SHIMMY_VERSION=2.6.4

dnf -y install cargo
# CARGO_HOME in /tmp: /root is a dangling symlink in the base image. The
# crate also installs test helpers; only shimmy goes into the image.
CARGO_HOME=/tmp/cargo cargo install --locked --version "$SHIMMY_VERSION" --root /tmp/shimmy shimmy
install -D -m 0755 /tmp/shimmy/bin/shimmy "$OUT/root/usr/bin/shimmy"
test "$("$OUT/root/usr/bin/shimmy" --version)" = "shimmy $SHIMMY_VERSION"
