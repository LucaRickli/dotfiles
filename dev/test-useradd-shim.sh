#!/usr/bin/env bash
#
# Prove the live ISO's useradd shim against a deployment laid out the way an
# installed disk lays one out. Rootless, no ISO, no VM, about a minute.
#
# What it reproduces: the wizard's last step is
#
#   useradd --root <deployment> --shell /bin/bash --groups wheel,docker <name>
#
# (fisherman has already dropped the groups the deployment lacks from the
# wizard's list), and a composefs deployment is a writable /etc plus a `var`
# symlink that points outside it. useradd chroots in, cannot follow that
# symlink, and exits 12 with the account written and no home directory, and
# fisherman aborts the install there. The details are with the shim in
# live/configure-installer.sh.
#
# So RED first, with the real useradd, which has to fail the way an install
# fails. Then GREEN, the same call through the shim, which has to not.
#
# The shim is read out of live/configure-installer.sh rather than copied, so
# what this tests is what the ISO ships.
#
#   dev/test-useradd-shim.sh [target-image] [live-image]
#
set -euo pipefail

target_image=${1:-ghcr.io/lucarickli/fedora-bootc:latest-uki}
live_image=${2:-localhost/fedora-bootc:live}
groups=wheel,docker    # the wizard's list, after fisherman filtered it
user=shimtestuser

podman image exists "$live_image" ||
    { echo "no $live_image locally: run 'just build-live' first" >&2; exit 1; }
podman image exists "$target_image" ||
    { echo "no $target_image locally: 'podman pull' it, or pass one as \$1" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
# The account files and the home directory come out owned by the container's
# root and its first user, which are subuids out here: only the user namespace
# can read them, and only the user namespace can delete them.
trap 'podman unshare rm -rf "$work"' EXIT

# The shim, exactly as configure-installer.sh writes it into the ISO.
awk '/^cat > \/usr\/local\/bin\/useradd << .EOF.$/ { f = 1; next }
     f && /^EOF$/ { exit } f' "$repo/live/configure-installer.sh" > "$work/useradd"
test -s "$work/useradd"
chmod 0755 "$work/useradd"
sh -n "$work/useradd"

# The deployment: this image's /etc, a `var` symlink that points outside it,
# and nothing else. Same layout dev/add-demo-user.sh works against.
dep=$work/target/state/deploy/testdeployment
mkdir -p "$dep" "$work/target/state/os/default/var/home"
podman run --rm "$target_image" tar -C / -cf - etc | tar -xf - -C "$dep"
ln -s ../../os/default/var "$dep/var"

dep_in=/target/state/deploy/testdeployment
in_live() {
    podman run --rm -i \
        -v "$work/target:/target:rw" \
        -v "$work/useradd:/usr/local/bin/useradd:ro" \
        "$live_image" "$@"
}

echo "== RED: the real useradd, the way fisherman calls it =="
rc=0
in_live /usr/sbin/useradd --root "$dep_in" --shell /bin/bash \
    --groups "$groups" --comment "Shim Test" "$user" || rc=$?
test "$rc" -eq 12 || { echo "expected exit 12 from useradd, got $rc" >&2; exit 1; }
test ! -e "$dep/var/home/$user" ||
    { echo "useradd exited 12 but made the home anyway" >&2; exit 1; }
in_live /usr/sbin/userdel --root "$dep_in" "$user"
echo "   exit 12, no home directory: the install failure, reproduced"

echo "== GREEN: the same call, through the shim =="
in_live useradd --root "$dep_in" --shell /bin/bash \
    --groups "$groups" --comment "Shim Test" "$user"

# Checked from inside, because /etc/shadow is mode 000 and the home is 0700:
# out here they belong to subuids and even root's own files are unreadable.
in_live sh -euc '
dep=$1; user=$2; groups=$3
grep -q "^$user:" "$dep/etc/passwd"          # the account row exists
for g in $(printf %s "$groups" | tr , " "); do
    grep -q "^$g:.*$user" "$dep/etc/group"   # in every group it asked for
done
test -d "$dep/var/home/$user"                # home made past the var symlink
test -s "$dep/var/home/$user/.bashrc"        # ...with /etc/skel copied into it
test "$(stat -c %a "$dep/var/home/$user")" = 700
owner=$(awk -F: -v u="$user" '"'"'$1 == u { print $3 ":" $4 }'"'"' "$dep/etc/passwd")
test "$(stat -c %u:%g "$dep/var/home/$user")" = "$owner"          # owned by the account
test "$(stat -c %u:%g "$dep/var/home/$user/.bashrc")" = "$owner"

# fisherman sets the password next, through the same chroot. Same step, so a
# failure here fails the install just as hard.
echo "$user:shim-test-password" | chpasswd --root "$dep"
grep -q "^$user:[^!*:]" "$dep/etc/shadow"    # a hash: not locked, not empty

echo "OK"
grep -E "^$user:" "$dep/etc/passwd" | sed "s/^/    /"
grep -E ":.*$user" "$dep/etc/group" | sed "s/^/    /"
' sh "$dep_in" "$user" "$groups"
