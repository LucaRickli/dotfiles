# The install ISO's live system (`just build-live`, then `just iso`;
# installer/build-iso.sh assembles the ISO from this image). Context: the
# repository root.
#
# Built from the plain Fedora base, not from the OS: the installer pulls the
# real image from the registry, so the live system only needs a compositor,
# the installer and what the install itself uses. fisherman (the installer's
# helper) runs `bootc install to-filesystem` inside a container of the TARGET
# image, so podman and the disk tools are needed, bootc is not. Nothing here
# is signed, so the build needs no Secure Boot key.

FROM scratch AS ctx
COPY installer/ /

# The same release as the OS (image/base.Containerfile).
FROM quay.io/fedora/fedora-bootc:44
RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/prepare-live.sh
# The signature policy and the cosign public key, so the image the installer
# pulls is verified here too. The other features configure the OS, not this.
COPY features/updates/overlay/etc/containers/ /etc/containers/
COPY keys/cosign.pub /etc/pki/containers/fedora-bootc.pub

# The graphical installer (bootc-installer Flatpak): started by labwc's
# autostart, locked to this repo's image catalog and named after it
# (installer/images.json, installer/recipe.json, installer/branding.json).
RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/configure-installer.sh
