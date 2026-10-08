# Seals any OS image built here (image/base.Containerfile's OS, or an add-on
# image of image/addon.Containerfile such as nvidia) into a signed UKI
# carrying the composefs digest of its rootfs (bootc's composefs backend:
# fs-verity enforces the digest at runtime, and the UKI is signed with the
# repo's own Secure Boot key). `just seal <name>` runs it in three steps:
#
#   1. podman build --target split    initramfs, lint, kernel out to /kernel
#   2. podman run chunkah              rechunk the split image into canonical
#                                      OCI layers; `podman pull oci:` imports
#                                      them
#   3. podman build --target final    the UKI from the imported image
#                                      (`chunked`) and the kernel of step 1
#                                      (`kernel`), both passed as
#                                      --build-context by image ID
#
# The digest MUST come from the imported, rechunked layers, the ones that get
# pushed: one computed from the build stage does not match what
# `bootc install` pulls, and the sealed UKI then refuses to install or boot
# ("wrong composefs= parameter"). Pattern:
# https://bootc.dev/bootc/experimental-composefs.html and
# https://github.com/travier/fedora-atomic-desktops-sealed

# ARGs used in a FROM must be declared before the first FROM. BASE_IMAGE is
# the image to seal; `just seal` always passes it (the default only makes a
# forgotten one fail loudly: "short-name overridden").
ARG BASE_IMAGE=overridden

# One stage per script, each mounted into one step: editing uki.sh re-runs
# the UKI step alone, not the initramfs and everything after it.
FROM scratch AS ctx-initramfs
COPY image/initramfs.sh /image/

FROM scratch AS ctx-uki
COPY image/uki.sh /image/

# Rebuild the initramfs (bootc/composefs dracut module; nvidia early KMS on
# the NVIDIA image), the last change to the rootfs, then validate it and move
# kernel + initramfs out of the rootfs; they live in the UKI instead.
FROM ${BASE_IMAGE} AS split
RUN --mount=type=bind,from=ctx-initramfs,source=/,target=/ctx /ctx/image/initramfs.sh
RUN bootc container lint
RUN mkdir /kernel && bootc container split-kernel-and-rootfs --rootfs / --output /kernel

# Step 2's image. Built into nothing: `just seal` resolves this stage to the
# pinned ID and runs it with `podman run`, with the split image read-only, an
# empty output directory and no network. A FROM line so that Renovate's
# dockerfile manager and prepare-runner's pre-pull see the pin.
FROM quay.io/coreos/chunkah:latest@sha256:8b56578258d1d10d3e1c7b0f71a4d05317c5fde331c4f483576a1b60e65f0cea AS chunkah

# Tools to build and sign the UKI, kept out of the OS image.
FROM registry.fedoraproject.org/fedora-minimal:44 AS tools
RUN dnf -y install --enablerepo=updates-testing bootc systemd-ukify sbsigntools && dnf -y clean all

# Seal: composefs digest of the rechunked rootfs + kargs.d, into a signed UKI.
# `chunked` and `kernel` are build contexts (container-image://), never
# stages: a stage that is only mounted is left out of the RUN's cache key on
# buildah before 1.44 (CI's), which would reuse another image's UKI.
# Secret contents are not in the cache key either; the cert's hash is, so a
# new db key re-signs instead of reusing a UKI signed with the old one.
FROM tools AS uki
ARG SB_CERT_SHA256=
RUN --mount=type=bind,from=chunked,source=/,target=/target \
    --mount=type=bind,from=kernel,source=/kernel,target=/kernel \
    --mount=type=bind,from=ctx-uki,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/uki.sh

# The final image: the rechunked rootfs plus the sealed UKI. Nothing under /
# may change after the digest was computed; only /boot is outside the seal.
# The import carries no image config, so restore what bootc needs (config
# only: not part of the digest).
FROM chunked AS final
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
COPY --from=uki /out/ /boot/EFI/Linux/
