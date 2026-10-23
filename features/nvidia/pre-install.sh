#!/usr/bin/env bash
#
# Runs before the nvidia add-on's package transaction (image/packages.sh):
# what its pkg.yml cannot say. RPM Fusion's repos come as release
# packages, the module build needs the headers of exactly the image's kernel
# and must be told open or closed modules, and akmods signs the modules with
# the Secure Boot db key (podman secrets, the same key that signs
# systemd-boot and the UKI). post-install.sh builds the modules and removes
# the key again, in this same layer.
#
#   NVIDIA_KMOD=open   NVIDIA open kernel modules: Turing (RTX 2000/GTX 16) and newer
#   NVIDIA_KMOD=closed legacy proprietary modules: Maxwell/Pascal/Volta (GTX 900/1000)
# (from ADDON_FLAVOR, the add-on build's argument in image/addon.Containerfile,
# `just build nvidia closed`; open by default)
#
set -euxo pipefail

NVIDIA_KMOD=${ADDON_FLAVOR:-open}
KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}')
REL=$(rpm -E %fedora)

# --- RPM Fusion free + nonfree ------------------------------------------------
# The release packages come from whichever mirror mirrors.rpmfusion.org
# redirects to, and dnf checks no signature on a package given by URL
# (localpkg_gpgcheck is off by default), so without more everything after,
# repo keys included, would rest on that mirror. Fedora ships RPM Fusion's
# signing keys in distribution-gpg-keys: those are imported first, and the
# two packages must be signed by them (an unsigned, tampered or differently
# signed package fails the transaction). The whole package step runs with
# the Secure Boot key mounted (see the top), which is why it matters most
# here.
# The two keys are in rpm's keyring for this check alone and deleted right
# after it, so the image's keyring is the one its packages make: dnf
# imports a repository's key from the verified release package when it
# first installs from that repository (nonfree's in the package step; free
# provides nothing the image installs).
dnf -y install distribution-gpg-keys
keys=$(rpm -qa 'gpg-pubkey*' --qf '%{VERSION}\n' | LC_ALL=C sort)
rpmkeys --import \
    "/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-free-fedora-${REL}" \
    "/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-nonfree-fedora-${REL}"
dnf -y install --setopt=localpkg_gpgcheck=1 \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${REL}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${REL}.noarch.rpm"
LC_ALL=C comm -13 <(printf '%s\n' "$keys") <(rpm -qa 'gpg-pubkey*' --qf '%{VERSION}\n' | LC_ALL=C sort) |
    xargs -r rpmkeys --delete

# --- Kernel headers for exactly the image's kernel ----------------------------
# fedora-bootc enables updates-archive, so this version stays installable after
# newer kernels hit the updates repo.
dnf -y install "kernel-devel-${KVER}" akmods

# Left to itself RPM Fusion's nvidia-kmod.spec picks open vs. closed by running
# lspci at build time (nvidia-kmod-noopen-checks), and that probe sees the BUILD
# HOST's GPU even inside a podman build, so the choice would depend on the machine
# doing the building. Pin it with the spec's own macros instead (build-time only,
# removed again by post-install.sh).
case "$NVIDIA_KMOD" in
    open)   echo '%_with_kmod_nvidia_open 1'      > /etc/rpm/macros.nvidia-kmod ;;
    closed) echo '%_without_kmod_nvidia_detect 1' > /etc/rpm/macros.nvidia-kmod ;;
    *)      echo "NVIDIA_KMOD must be 'open' or 'closed', got '$NVIDIA_KMOD'" >&2; exit 1 ;;
esac

# --- Secure Boot: sign the modules with the db key (podman secrets) -----------
# kmodtool signs automatically when both files exist at these paths. It wants the
# certificate as DER; the private key can be used as-is. akmods builds as the
# unprivileged 'akmods' user (created by the akmods package above), and kmodtool's
# sign step runs inside that build, so the key must be group-readable by it (this
# is what akmods' own kmodgenca does).
mkdir -p /etc/pki/akmods/certs
openssl x509 -in /run/secrets/secureboot_cert -outform DER -out /etc/pki/akmods/certs/public_key.der
chmod 644 /etc/pki/akmods/certs/public_key.der
install -Dm640 -o root -g akmods /run/secrets/secureboot_key /etc/pki/akmods/private/private_key.priv
