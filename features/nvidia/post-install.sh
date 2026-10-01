#!/usr/bin/env bash
#
# Runs right after the nvidia add-on's package transaction (image/packages.sh),
# in the same layer as pre-install.sh: builds the kernel module against the
# image's kernel (akmods), signed with the key pre-install.sh put in place,
# then removes that key, so it never reaches a layer. setup.sh checks the
# module and that the key is gone; image/finalize.sh scans for any private
# key left in the image.
set -euxo pipefail

KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
MOD="/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz"

akmods --force --kernels "$KVER" --kmod nvidia
# akmods can finish without a module; the build log says why.
if ! modinfo "$MOD" >/dev/null 2>&1; then
    cat /var/cache/akmods/nvidia/*.failed.log 2>/dev/null || true
    echo "akmods did not produce $MOD" >&2; exit 1
fi
modinfo "$MOD" | grep -E '^(version|license|signer|sig_key)' || true

# Build-time only: the signing key, the open/closed pin, the build's leftovers.
rm -rf /etc/pki/akmods/private
rm -f /etc/rpm/macros.nvidia-kmod
rm -rf /var/cache/akmods /var/log/akmods /var/roothome/rpmbuild
