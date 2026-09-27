#!/usr/bin/env bash
#
# noctalia-greeter, the greetd greeter, built from its upstream tag into an RPM
# that build.sh installs with the rest of the packages. Fedora does not package
# it. Runs in the Containerfile's `greeter` stage, which pins the release (the
# tag GREETER_VERSION, which names the version, and its commit GREETER_COMMIT,
# which is what gets built; Renovate bumps both) and starts from
# the same base as the image, so the RPM links against the libraries the image
# ships. The RPM lands in /out.
#
set -euxo pipefail

CTX=${CTX:-/ctx}
: "${GREETER_VERSION:?}" "${GREETER_COMMIT:?}"
version=${GREETER_VERSION#v}
top=/tmp/rpmbuild       # /root is a dangling symlink in the base image
src=/tmp/noctalia-greeter

dnf -y install git-core rpm-build dnf5-plugins

# The pinned commit itself, not whatever the tag names today: that is the code
# Renovate proposed and CI built, and a tag moved upstream (Renovate opens a PR
# for that) or deleted breaks nothing here. Retried like build.sh's release
# downloads: GitHub resets connections often enough to fail builds.
for attempt in 1 2 3; do
    rm -rf "$src"
    if git init --quiet "$src" &&
        git -C "$src" fetch --quiet --depth 1 \
            https://github.com/noctalia-dev/noctalia-greeter "$GREETER_COMMIT" &&
        git -C "$src" checkout --quiet FETCH_HEAD; then
        break
    fi
    [ "$attempt" = 3 ] && { echo "fetching noctalia-greeter failed after 3 attempts" >&2; exit 1; }
    echo "fetch attempt $attempt failed, retrying in 10s" >&2
    sleep 10
done
test "$(git -C "$src" rev-parse HEAD)" = "$GREETER_COMMIT"

# Build time, build host and file dates fixed (the release commit's time), so
# the same pin builds the same RPM; rpmbuild would otherwise want a %changelog
# for the dates.
SOURCE_DATE_EPOCH=$(git -C "$src" log -1 --format=%ct)
export SOURCE_DATE_EPOCH

mkdir -p "$top/SOURCES" /out
git -C "$src" archive --format=tar.gz --prefix="noctalia-greeter-${version}/" \
    -o "$top/SOURCES/noctalia-greeter-${version}.tar.gz" HEAD
dnf -y builddep --define "greeter_version ${version}" "$CTX/noctalia-greeter.spec"
rpmbuild -bb --define "_topdir ${top}" --define "greeter_version ${version}" \
    --define 'debug_package %{nil}' \
    --define 'use_source_date_epoch_as_buildtime 1' --define '_buildhost fedora-bootc' \
    "$CTX/noctalia-greeter.spec"
cp "$top"/RPMS/*/noctalia-greeter-"${version}"-*.rpm /out/
ls -l /out
