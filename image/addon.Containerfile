# One add-on feature (features/<name>/ with `addon: true`) on top of the OS
# image of image/base.Containerfile, for an image of its own: the add-on's
# packages (image/packages.sh), its overlay/, then image/finalize.sh, built
# like the base itself and nothing else different. Every add-on is built by
# this one file; `just build-addon <name>` runs it, as localhost/fedora-bootc:<name>,
# and `just seal <name>` seals the result like the OS (`just build <name>`
# does both). The nvidia add-on, for one: :nvidia and :nvidia-uki.
#
#   BASE_IMAGE    the OS image to build on: localhost/fedora-bootc:latest, or
#                 in CI the one the base job pushed, by digest
#   ADDON         the add-on feature's name
#   ADDON_FLAVOR  reaches the add-on's scripts as $ADDON_FLAVOR; empty by
#                 default (nvidia: open or closed kernel modules,
#                 `just build nvidia closed`)

# ARGs used in a FROM must be declared before the first FROM. `just` always
# passes BASE_IMAGE and ADDON; the defaults only make a forgotten one fail
# loudly ("short-name overridden", "/out/overridden/...: no such file").
ARG BASE_IMAGE=overridden

# The check-and-sort stage of image/base.Containerfile, the same four lines
# (same image, same instructions), so one cached result serves both files.
FROM registry.fedoraproject.org/fedora-minimal:44 AS features
RUN dnf -y install --repo=fedora yq jq findutils && dnf -y clean all
COPY image/features.sh /image/
COPY features/ /features/
RUN /image/features.sh /features /out

# The add-on's package step: image/packages.sh with the set's package lists,
# hooks and repo files (image/features.sh sorts them out of the feature).
FROM scratch AS ctx-packages
ARG ADDON=overridden
COPY image/packages.sh /image/
COPY --from=features /out/${ADDON}/packages/ /features/

FROM scratch AS ctx-finalize
ARG ADDON=overridden
COPY image/finalize.sh /image/
COPY --from=features /out/${ADDON}/all/ /features/

FROM ${BASE_IMAGE} AS addon
ARG ADDON=overridden
ARG ADDON_FLAVOR=
# The package step gets the Secure Boot db key (podman secrets, never a
# layer): the nvidia add-on signs its kernel modules with the same key as
# the UKI (one enrollment) and removes it again within the step. Secret
# contents are not in the cache key; the cert's hash is, so a new db key
# re-runs the step instead of reusing modules signed with the old one.
ARG SB_CERT_SHA256=
RUN --mount=type=bind,from=ctx-packages,source=/,target=/ctx \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert \
    /ctx/image/packages.sh
# The add-on's overlay/, after the base's (no two features may ship the same
# path, image/features.sh).
COPY --from=features /out/${ADDON}/overlay/ /
# Services, the add-on's setup.sh, and the image-wide checks again.
RUN --mount=type=bind,from=ctx-finalize,source=/,target=/ctx /ctx/image/finalize.sh
