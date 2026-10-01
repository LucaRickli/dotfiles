#!/usr/bin/env bash
#
# Turn the plain Fedora bootc base into the live ISO rootfs: the graphical
# session, the tools an install needs, and the ISO boot machinery. Runs from
# the Containerfile's `live` stage; installer/configure-installer.sh then adds
# the wizard on top.
set -euxo pipefail
# Session: labwc hosts the wizard, greetd autologs in, foot for the manual
# install path, plus mesa, portals and fonts.
# Xwayland is NOT optional: labwc declares no dependency on it, but dies at
# startup with "failed to start xwayland server" when it is absent, and greetd
# then falls back to a text greeter liveuser has no password for.
# Install tools: podman runs the target image's own bootc; cryptsetup and the
# filesystem tools do the disk work.
# Network: a GUI and a TUI, so a wifi-only machine can get online to pull.
# Boot: GRUB (gcdx64.efi) with NO shim, see "NO SHIM" below.
# dracut-live for the squashfs root; livesys creates the autologin live user.
# zram-generator: see the writable space section below.
dnf -y install \
    labwc foot greetd \
    xorg-x11-server-Xwayland \
    mesa-dri-drivers \
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr \
    default-fonts-core-sans adwaita-icon-theme \
    flatpak polkit \
    podman fuse-overlayfs cryptsetup btrfs-progs dosfstools e2fsprogs util-linux \
    NetworkManager NetworkManager-tui nm-connection-editor \
    dracut-live livesys-scripts grub2-efi-x64 grub2-efi-x64-cdboot \
    zram-generator
# shim-x64 comes with the base image, so it has to be removed, not left out.
# Nothing depends on it, but /etc/dnf/protected.d/shim.conf protects it, hence
# the setopt. Why it must go is right below.
dnf -y remove --setopt=protected_packages= shim-x64
# On bootc images the rpms' /boot/efi payload stays empty; the real binaries
# live under /usr/lib/efi/<pkg>/<ver>/EFI. installer/build-iso.sh reads
# /boot/efi/EFI.
mkdir -p /boot/efi/EFI/BOOT
for d in /usr/lib/efi/grub2/*/EFI; do cp -a "$d/." /boot/efi/EFI/; done
# NO SHIM, on purpose. This ISO is meant NOT to boot under Secure Boot.
#
# Fedora's shim is signed by Microsoft, so an ISO carrying it boots on
# essentially any Secure Boot machine. This one hands whoever holds it a live
# session with passwordless sudo, which is a way into a machine that is
# otherwise locked down (own keys enrolled, boot order fixed, USB disabled).
# Leaving shim out means the firmware sees only grubx64.efi, signed by
# Fedora's CA, which is trusted by nothing in the firmware's db: Secure Boot
# refuses it. Turn Secure Boot off to install, turn it back on afterwards
# once your own keys are enrolled (docs/secureboot-tpm2.md).
#
# So EFI/BOOT/BOOTX64.EFI, the removable-media path firmware looks for, is
# GRUB itself. gcdx64.efi rather than grubx64.efi: same GRUB, built with its
# prefix set to /EFI/BOOT, which is where installer/build-iso.sh writes
# grub.cfg. Nothing chain-loads, so there is no fbx64.efi and no mmx64.efi
# either.
cp /boot/efi/EFI/fedora/gcdx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
test -f /boot/efi/EFI/BOOT/BOOTX64.EFI
test -f /boot/efi/EFI/fedora/gcdx64.efi
# A shim arriving as somebody's dependency would silently make the ISO
# Secure Boot bootable again, which is the whole thing this avoids.
test -z "$(rpm -qa shim shim-x64)"
# --- Writable space in the live session ---------------------------------------
# Everything below exists because of one measurement: in the live session `/`
# is an overlay whose upper layer is a plain directory on /run, and systemd
# mounts /run at a hard 20% of RAM with 800k inodes
# (TMPFS_LIMITS_RUN in systemd's mount-setup.c). On a 4 GB machine that is a
# 780 MB writable root, and an install that has to stage several GB of image
# dies in it with ENOSPC. Measured by booting this ISO: `df -h /` reports
# 780M, and writing to it stops at 771 MiB.
#
# Note that rd.live.overlay.size= does NOT help. It sizes the device-mapper
# COW file, and this ISO takes dracut's overlayfs path (the squashfs holds the
# root tree rather than a rootfs.img), where the parameter is never read.
# dracut 111 adds rd.overlay=tmpfs:size=, Fedora 44 has 108. So the only
# lever on this dracut is a remount after boot, which is what the unit below
# does, and it is what dakota-iso does too.
cat > /etc/systemd/system/live-run-expand.service << 'EOF'
[Unit]
Description=Give the live overlay room to install from
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target sysinit.target
ConditionPathExists=/run/overlayfs

[Service]
Type=oneshot
RemainAfterExit=yes
# The upper layer of the live root lives here, so this is the size of the
# writable root filesystem, and the image the installer pulls has to fit in
# it: measured at 9.1 GB for this image. 80% of a 16 GB machine is 12.8 GB,
# which leaves the pull about 3.5 GB of headroom to grow into.
ExecStart=/usr/bin/mount -o remount,size=80%,nr_inodes=4m /run
# Into dmesg, so "the installer ran out of space" can be checked against the
# size it actually got, on any console, without a shell.
ExecStartPost=/usr/bin/sh -c 'echo "live: writable overlay is now $(findmnt -no SIZE /run)" > /dev/kmsg'

[Install]
WantedBy=local-fs.target
EOF
systemctl enable live-run-expand.service

# bootc stages image blobs in /var/tmp, and containers/storage hardcodes that
# path rather than reading TMPDIR. 50%, not 80%: on the composefs path
# fisherman bind-mounts its own disk-backed scratch over /var/tmp for exactly
# that staging, so this is the fallback rather than the main event, and it
# competes with /run above for the same RAM.
cat > /etc/systemd/system/var-tmp.mount << 'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on the live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%,nr_inodes=1m

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

# Both of those are RAM. zram swap is what makes the ceiling more than the
# amount installed: tmpfs pages are swappable, and an unpacked container image
# is mostly binaries and text, which zstd compresses well. It does not remove
# the RAM requirement, it stretches it.
mkdir -p /usr/lib/systemd
cat > /usr/lib/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF

# fisherman moves its own scratch onto the target disk once that is mounted,
# and pre-creates nothing; this is the path it uses before that point.
mkdir -p /var/fisherman-tmp

# --- podman on an overlayfs root ---------------------------------------------
# The live root IS an overlayfs, and podman's native overlay driver refuses to
# stack on one:
#
#   Error: configure storage: 'overlay' is not supported over overlayfs,
#   a mount_program is required
#
# and podman exits 125. containers/storage falls back to fuse-overlayfs by
# itself only when rootless; an install runs as root, so it has to be told.
# Without this, every `podman pull` in the live session fails, including the
# manual install route in docs/install.md.
#
# Live image only. The installed system keeps container storage on btrfs,
# where the native driver works and is faster, so this must not go in features/.
cat > /etc/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
test -x /usr/bin/fuse-overlayfs
kver=$(cd /usr/lib/modules && echo *)
DRACUT_NO_XATTR=1 dracut --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kver}/initramfs.img" "${kver}"
systemctl enable livesys.service livesys-late.service
systemctl enable NetworkManager.service
# The base image ships the AWS SDK (boto3 and friends, about 150 MB) for cloud
# use cases. An installer ISO has none. mesa-vulkan-drivers is not installed
# above for the same reason: labwc renders with GLES and declares no Vulkan
# dependency, and the Flatpak app gets its GL from the runtime extension.
dnf -y remove python3-boto3 python3-s3transfer python3-botocore || true
dnf -y clean all
rm -rf /var/cache/libdnf5 /var/log/dnf5.log*
