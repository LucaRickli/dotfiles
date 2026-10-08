# The OS, unsealed and with its kernel still in place: every base feature
# (features/*/ without `addon: true`), an ordinary bootc image in its own
# right. `just build-base` builds it as localhost/fedora-bootc:latest;
# image/addon.Containerfile builds each add-on on top of it (:nvidia), and
# image/seal.Containerfile seals either into a signed UKI carrying the
# composefs digest of its rootfs (:latest-uki, :nvidia-uki; `just build`,
# `just build nvidia`). Pattern:
# https://bootc.dev/bootc/experimental-composefs.html and
# https://github.com/travier/fedora-atomic-desktops-sealed
#
# The build context is the repository root; .containerignore keeps keys/ out
# of it, and no step mounts the context itself, so a RUN sees only what a
# stage below COPYed first.
#
# ALWAYS boot-test a build in a VM (`just qcow2 && just vm`) before installing
# or upgrading real hardware: a build/install digest mismatch only shows up at
# boot, as a dracut emergency shell.

# One base for the OS image and the build stages. It floats on the release
# tag; moving to the next Fedora release is a deliberate edit here, in
# image/addon.Containerfile, image/seal.Containerfile and
# installer/live.Containerfile (the live ISO's system).
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
# image/addon.Containerfile runs these same four lines, so one cached
# result serves both files.
FROM registry.fedoraproject.org/fedora-minimal:44 AS features
RUN dnf -y install --repo=fedora yq jq findutils && dnf -y clean all
COPY image/features.sh /image/
COPY features/ /features/
RUN /image/features.sh /features /out

FROM scratch AS ctx
COPY image/packages.sh /image/
COPY --from=features /out/base/packages/ /features/

FROM scratch AS ctx-builds
COPY image/builds.sh /image/
COPY --from=features /out/base/builds/ /builds/

# bootloader.sh alone: the stage is mounted into the OS at the bootloader
# step, so anything else in it would re-run that step and all that follows.
FROM scratch AS ctx-boot
COPY image/bootloader.sh /image/

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

# GRUB/bootupd out, systemd-boot in, signed with the Secure Boot db key
# (podman secrets, so the private key never enters a layer). Secret contents
# are not in the cache key; the cert's hash is, so a new db key re-runs the
# signing step instead of reusing a loader signed with the old one.
ARG SB_CERT_SHA256=
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
