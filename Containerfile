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

# One base for the OS image, the live ISO and the build stages. It floats on
# the release tag; moving to the next Fedora release is a deliberate edit
# here.
FROM quay.io/fedora/fedora-bootc:44 AS base

# The parts of the repo the build scripts read, bind-mounted into the RUN steps
# below. Only what each step needs, so that editing docs, CI files or home/
# does not invalidate the cached package layer.
#
# image/features.sh reads every feature's pkg.yml, checks how the features
# fit together (requires, no file shipped twice) and sorts them: the base
# apart from each add-on, and per set the package step's files apart from
# the rest, so that editing a feature's files or setup does not re-run a
# package step, and editing an add-on does not touch the base. COPY cannot
# pick files like that, hence the stage, which also needs yq for the YAML
# (from the release repo alone: no updates metadata to fetch for it).
FROM base AS features
RUN dnf -y install --repo=fedora yq && dnf -y clean all
COPY image/features.sh /image/
COPY features/ /features/
RUN /image/features.sh /features /out

FROM scratch AS ctx
COPY image/packages.sh /image/
COPY --from=features /out/base/packages/ /features/

FROM scratch AS ctx-builds
COPY image/builds.sh /image/
COPY --from=features /out/base/builds/ /builds/

FROM scratch AS ctx-boot
COPY image/bootloader.sh image/initramfs.sh image/uki.sh /image/

# The same two steps for the nvidia add-on (features/nvidia/).
FROM scratch AS ctx-nvidia
COPY image/packages.sh /image/
COPY --from=features /out/nvidia/packages/ /features/

FROM scratch AS ctx-nvidia-finalize
COPY image/finalize.sh /image/
COPY --from=features /out/nvidia/all/ /features/

FROM scratch AS ctx-live
COPY installer/ /

# What Fedora does not package (noctalia-greeter, shimmy, ...): every base
# feature's build.sh, run by image/builds.sh. From the same base as
# the image, so it links against the libraries the image ships and a base
# update rebuilds it; a stage of its own, so no toolchain reaches the image.
# Adding or changing a build needs no edit here.
FROM base AS builds
RUN --mount=type=bind,from=ctx-builds,source=/,target=/ctx /ctx/image/builds.sh

# The built RPMs alone, for the package step: COPY hashes content, so a build
# that only changed files leaves the package layer cached.
FROM scratch AS built-rpms
COPY --from=builds /out/rpm/ /

# finalize.sh's context, here because it lists what the builds made, to
# check against every feature's overlay paths.
FROM scratch AS ctx-finalize
COPY image/finalize.sh /image/
COPY --from=features /out/base/all/ /features/
COPY --from=features /out/overlay-paths.txt /
COPY --from=builds /out/root-paths.txt /

FROM base AS os

# The rootfiles package pulled in below expects root's home directory to
# exist at build time (on a booted system systemd creates it under /var).
RUN mkdir -p /var/roothome

# The comps groups the image is composed from. Its own step, so that a change
# to a feature's packages does not rebuild these GBs.
#
# workstation-product is the Fedora Workstation base set (firmware tools,
# chrony, btrfs-progs, input methods, ...). Two of its defaults are excluded:
# gnome-shell-extension-background-logo requires gnome-shell and would drag a
# second desktop in with it (gdm, mutter, gnome-session), and unoconv pulls in
# LibreOffice. The desktop here is greetd + noctalia-greeter and five Wayland
# sessions (features/login/, features/sessions/).
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

# Every base feature's packages (features/*/pkg.yml, plus the RPMs the
# builds made). The expensive layer: nothing below invalidates it.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=built-rpms,source=/,target=/run/builds \
    /ctx/image/packages.sh

# GRUB/bootupd out, systemd-boot in, signed with the db key from keys/
# (podman secrets, so the private key never enters a layer).
RUN --mount=type=bind,from=ctx-boot,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/bootloader.sh

# Every base feature's overlay/ lands verbatim on the image (no two may ship
# the same path, image/features.sh). The dotfiles in home/ never do.
COPY --from=features /out/base/overlay/ /
# The files the builds made (shimmy, ...); none may also be in an overlay/
# (image/finalize.sh checks).
COPY --from=builds /out/root/ /

# The cosign PUBLIC key: the signature policy (features/updates/) requires a
# valid signature by it for every pull from ghcr.io/lucarickli/fedora-bootc,
# so the machine verifies its own updates. CI signs after the push
# (build.yml).
COPY keys/cosign.pub /etc/pki/containers/fedora-bootc.pub

# Services, each feature's setup.sh, and the image-wide checks.
RUN --mount=type=bind,from=ctx-finalize,source=/,target=/ctx /ctx/image/finalize.sh

# --- everything below seals one of two things -------------------------------
FROM ${OS_BASE} AS os-image

# NVIDIA variant: the nvidia add-on (features/nvidia/) on top of that same
# base, nothing else different, built like the base: packages, overlay,
# finalize.
#   NVIDIA_KMOD=open   open kernel modules (default, Turing+) | closed (Maxwell..Volta)
# The modules are signed with the same db key as the UKI (one enrollment),
# which only the package step gets; it also removes it again.
FROM os-image AS os-nvidia
ARG NVIDIA_KMOD=open
RUN --mount=type=bind,from=ctx-nvidia,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/packages.sh
COPY --from=features /out/nvidia/overlay/ /
RUN --mount=type=bind,from=ctx-nvidia-finalize,source=/,target=/ctx /ctx/image/finalize.sh

# Which of the two gets sealed (SEAL). `just build-nvidia` passes os-nvidia.
FROM ${SEAL} AS rootfs

# Rebuild the initramfs (bootc/composefs dracut module; nvidia early KMS on the
# NVIDIA variant). This is the last change to the rootfs, then validate it.
RUN --mount=type=bind,from=ctx-boot,source=/,target=/ctx /ctx/image/initramfs.sh
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
    env KERNEL_DIR=/run/src/kernel /ctx/image/uki.sh

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
# installer/build-iso.sh assembles the ISO from this stage.
FROM base AS live
RUN --mount=type=bind,from=ctx-live,source=/,target=/ctx /ctx/prepare-live.sh
# The signature policy and the cosign public key, so the image the installer
# pulls is verified here too. The other features configure the OS, not this.
COPY features/updates/overlay/etc/containers/ /etc/containers/
COPY keys/cosign.pub /etc/pki/containers/fedora-bootc.pub

# The graphical installer (bootc-installer Flatpak): started by labwc's
# autostart, locked to this repo's image catalog and named after it
# (installer/images.json, installer/recipe.json, installer/branding.json).
RUN --mount=type=bind,from=ctx-live,source=/,target=/ctx /ctx/configure-installer.sh
