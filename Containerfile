# A personal Fedora bootc image, booting via systemd-boot + a sealed UKI
# (bootc's composefs backend: the UKI carries the composefs digest of the
# rootfs, fs-verity enforces it at runtime, and UKI + loader are signed with
# the repo's own Secure Boot key).
#
#   os ---------------> uki    the main image
#     \--> os-nvidia --> uki    the NVIDIA variant
#
# `os` is the whole OS, unsealed and with its kernel still in place, so it is
# an ordinary bootc image in its own right. Everything after it seals one of
# the two: split (kernel/initramfs moved out), chunkah (rechunk into canonical
# OCI layers), uki (sealed UKI built and signed against the rechunked rootfs),
# final (chunked plus the UKI at /boot/EFI/Linux). Pattern:
# https://bootc.dev/bootc/experimental-composefs.html and
# https://github.com/travier/fedora-atomic-desktops-sealed
#
# ALWAYS boot-test a build in a VM (`just qcow2 && just vm`) before installing
# or upgrading real hardware: a build/install digest mismatch only shows up at
# boot, as a dracut emergency shell.

# ARGs used in a FROM must be declared before the first FROM.
#
#   OS_BASE  what the sealing half starts from. The `os` stage by default; CI
#            passes a base it has already built and pushed, and then `os` is
#            unreferenced and skipped, so the packages are built once per run.
#   SEAL     which image gets sealed: os-image, or os-nvidia for the variant.
ARG OS_BASE=os
ARG SEAL=os-image

# The parts of the repo the build scripts read, bind-mounted into the RUN steps
# below. Only what each step needs, so that editing docs, CI files or home/
# does not invalidate the cached package layer.
FROM scratch AS ctx
COPY build_files/build.sh /build_files/
COPY packages/packages.txt packages/binary.yaml /packages/

FROM scratch AS ctx-boot
COPY build_files/bootloader.sh build_files/initramfs.sh build_files/uki.sh /build_files/

FROM scratch AS ctx-finalize
COPY build_files/finalize.sh /build_files/

FROM scratch AS ctx-nvidia
COPY nvidia/ /nvidia/

FROM scratch AS ctx-live
COPY live/ /

# One base for both the OS image and the live ISO. It floats on the release
# tag; moving to the next Fedora release is a deliberate edit here.
FROM quay.io/fedora/fedora-bootc:44 AS base

FROM base AS os

# The rootfiles package pulled in below expects root's home directory to
# exist at build time (on a booted system systemd creates it under /var).
RUN mkdir -p /var/roothome

# The comps groups the image is composed from. Its own step, so that a change
# to packages/ does not rebuild these GBs.
#
# workstation-product is the Fedora Workstation base set (firmware tools,
# chrony, btrfs-progs, input methods, ...). Two of its defaults are excluded:
# gnome-shell-extension-background-logo requires gnome-shell and would drag a
# second desktop in with it (gdm, mutter, gnome-session), and unoconv pulls in
# LibreOffice. The desktop here is greetd + noctalia-greeter and five Wayland
# sessions (packages.txt).
#
# fedora-release-ostree-desktop marks the image as an image-based desktop
# (https://fedoraproject.org/wiki/Changes/UnprivilegedUpdatesAtomicDesktops).
# It shares the transaction because every dnf transaction rewrites the rpm
# database, and a layer of its own would cost ~90 MB for that copy.
RUN dnf -y group install \
    --exclude=gnome-shell-extension-background-logo \
    --exclude=unoconv --exclude='libreoffice*' \
    base-graphical container-management core fonts guest-desktop-agents hardware-support multimedia networkmanager-submodules printing workstation-product \
    && dnf -y install fedora-release-ostree-desktop \
    && dnf -y clean all \
    && rm -f /var/log/dnf5.log*

# The repo definitions for the third-party packages in packages.txt. The rest
# of overlay/ is copied in further down; build.sh needs these first.
COPY overlay/etc/yum.repos.d/ /etc/yum.repos.d/

# Packages (packages.txt) and the binaries bm manages (binary.yaml). The
# expensive layer: nothing below invalidates it. CI mounts the bm binaries
# pre-fetched and verified as /run/bundle.tar (the `bm` job in build.yml);
# without one, build.sh syncs them itself.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/build_files/build.sh

# GRUB/bootupd out, systemd-boot in, signed with the db key from keys/
# (podman secrets, so the private key never enters a layer).
RUN --mount=type=bind,from=ctx-boot,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/build_files/bootloader.sh

# overlay/ lands verbatim on the image. The dotfiles in home/ never do.
COPY overlay/ /

# The cosign PUBLIC key: overlay/etc/containers/policy.json requires a valid
# signature by it for every pull from ghcr.io/lucarickli/fedora-bootc, so the
# machine verifies its own updates. CI signs after the push (build.yml).
COPY keys/cosign.pub /etc/pki/containers/fedora-bootc.pub

# Services, generated configs, and the build-time assertions.
RUN --mount=type=bind,from=ctx-finalize,source=/,target=/ctx /ctx/build_files/finalize.sh

# --- everything below seals one of two things -------------------------------
FROM ${OS_BASE} AS os-image

# NVIDIA variant: the driver on top of that same base, nothing else different.
#   NVIDIA_KMOD=open   open kernel modules (default, Turing+) | closed (Maxwell..Volta)
# The modules are signed with the same db key as the UKI (one enrollment).
FROM os-image AS os-nvidia
ARG NVIDIA_KMOD=open
RUN --mount=type=bind,from=ctx-nvidia,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/nvidia/nvidia.sh

# Which of the two gets sealed (SEAL). `just build-nvidia` passes os-nvidia.
FROM ${SEAL} AS rootfs

# Rebuild the initramfs (bootc/composefs dracut module; nvidia early KMS on the
# NVIDIA variant). This is the last change to the rootfs, then validate it.
RUN --mount=type=bind,from=ctx-boot,source=/,target=/ctx /ctx/build_files/initramfs.sh
RUN bootc container lint

# Move kernel + initramfs out of the rootfs; they live in the UKI instead.
FROM rootfs AS split
RUN mkdir /kernel && bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# Rechunk into a canonical OCI image (chunkah) and re-import it. The composefs
# digest MUST be computed from the same canonical layers that get pushed and
# pulled: measuring the build stage directly gives a digest `bootc install`
# does not reproduce, and the sealed UKI then refuses to install or boot
# ("wrong composefs= parameter").
# The OCI directory goes to out/ in the repo (git-ignored) through the
# `--volume "$PWD":/run/src` that Justfile/CI pass, and `FROM oci:out` reads it
# back. podman cannot see that dependency, so the build runs as two
# invocations split right here; see the Justfile's `_build`.
FROM quay.io/coreos/chunkah:latest@sha256:ff8b8b466a942ec6000445d4001fc661e2fc5a952ad9ee29b4de9ab09d1d1708 AS chunkah
RUN --mount=from=split,src=/,target=/chunkah,ro \
    --mount=type=bind,target=/run/src,rw \
    chunkah build \
    --max-layers 256 \
    --prune /ostree \
    --prune /sysroot/ostree \
    --prune /kernel \
    --output oci:/run/src/out

# The kernel and initramfs go out to the host as well (kernel/), so nothing
# below this line refers to `rootfs` or `split` and the second build
# invocation can skip them.
FROM split AS kernel-out
RUN --mount=type=bind,target=/run/src,rw \
    rm -rf /run/src/kernel && cp -a /kernel /run/src/kernel

# The re-import loses the container config, so restore what bootc needs.
FROM oci:out AS chunked
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# Tools to build + sign the UKI (kept out of the OS image).
FROM registry.fedoraproject.org/fedora-minimal:44 AS tools
RUN dnf -y install --enablerepo=updates-testing bootc systemd-ukify sbsigntools && dnf -y clean all

# Seal: composefs digest of the rechunked rootfs + kargs.d, into a signed UKI.
# The kernel comes from the host copy (kernel-out above).
FROM tools AS uki
RUN --mount=type=bind,from=chunked,source=/,target=/target \
    --mount=type=bind,target=/run/src \
    --mount=type=bind,from=ctx-boot,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    env KERNEL_DIR=/run/src/kernel /ctx/build_files/uki.sh

# The final image: the rechunked rootfs plus the sealed UKI. Nothing under /
# may change after the digest was computed; only /boot is outside the seal.
FROM chunked AS final
COPY --from=uki /out/ /boot/EFI/Linux/

# Live ISO variant (`just build-live`, then `just iso`).
#
# Built from the plain base, not from the OS: the installer pulls the real
# image from the registry, so the live system only needs a compositor, the
# installer and what the install itself uses. fisherman (the installer's
# helper) runs `bootc install to-filesystem` inside a container of the TARGET
# image, so podman and the disk tools are needed, bootc is not.
# live/build-iso.sh assembles the ISO from this stage.
FROM base AS live
RUN --mount=type=bind,from=ctx-live,source=/,target=/ctx /ctx/prepare-live.sh
# The signature policy and the cosign public key, so the image the installer
# pulls is verified here too. The rest of overlay/ configures the OS, not this.
COPY overlay/etc/containers/ /etc/containers/
COPY keys/cosign.pub /etc/pki/containers/fedora-bootc.pub

# The graphical installer (bootc-installer Flatpak): started by labwc's
# autostart, locked to this repo's image catalog and named after it
# (live/images.json, live/recipe.json, live/branding.json).
RUN --mount=type=bind,from=ctx-live,source=/,target=/ctx /ctx/configure-installer.sh
