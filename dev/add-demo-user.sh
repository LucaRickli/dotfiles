#!/usr/bin/env bash
#
# Add a throwaway login to an INSTALLED disk image, and only to that disk.
#
# This runs INSIDE the throwaway VM that `just demo-user` starts, with the
# qcow2 attached as a virtio disk and a scratch directory bind-mounted for the
# parameters and the result. Nothing here touches the container image: it
# bakes in no accounts on purpose, and its composefs digest is sealed into the
# UKI, so an account added there would be in every machine built from it.
#
# What makes this safe after the fact is where the account lives. A
# composefs-native install lays the disk out like this:
#
#   /composefs/                    the sealed, verified image. Never touched.
#   /state/deploy/<digest>/etc/    the deployment's WRITABLE /etc
#   /state/deploy/<digest>/var ->  ../../os/default/var
#   /state/os/default/var/         the writable /var, shared across deployments
#
# /etc and /var are outside the sealed tree by design (that is what makes a
# bootc system configurable at all), so writing an account row into the
# deployment's /etc/passwd leaves the seal intact. The ISO wizard does the
# same at the end of an install.
#
# `useradd --root <deployment>` chroots into the deployment, where /var is a
# relative symlink pointing outside that chroot and /home does not exist at
# all, so creating the home from in there fails with exit 12. So: -M to write
# the account row without a home, then create the home from out here, where
# "$dep$home" resolves through the var symlink correctly. The ISO's useradd
# shim (live/configure-installer.sh) does the same.
#
set -euxo pipefail

scratch=/run/virtiofs-mnt-demo
disk=/dev/disk/by-id/virtio-target-part3
mnt=/mnt/target

user=$(sed -n 1p "$scratch/params")
password=$(sed -n 2p "$scratch/params")
test -n "$user"
test -n "$password"

mkdir -p "$mnt"
mount "$disk" "$mnt"
# sync before unmounting: this is a disk file on the host, and the recipe goes
# on to boot it as soon as the VM releases it.
trap 'sync; umount "$mnt" 2>/dev/null || true' EXIT

# Exactly one deployment is expected. A freshly installed disk has one; if a
# machine has been updated there would be two, and guessing which one the next
# boot picks is not something this dev tool should do.
mapfile -t deps < <(find "$mnt/state/deploy" -mindepth 1 -maxdepth 1 -type d | sort)
if [ "${#deps[@]}" -ne 1 ]; then
    echo "expected exactly one deployment, found ${#deps[@]}" >&2
    printf 'FAILED: %s deployments\n' "${#deps[@]}" > "$scratch/result"
    exit 1
fi
dep="${deps[0]}"
test -f "$dep/etc/passwd"

if awk -F: -v u="$user" '$1 == u { found = 1 } END { exit !found }' "$dep/etc/passwd"; then
    echo "account '$user' is already on this disk, leaving it alone"
    printf 'OK: %s already present\n' "$user" > "$scratch/result"
    exit 0
fi

# -6: yescrypt is what Fedora's default policy prefers, but sha512 is what
# every shadow implementation here agrees on, and this is a throwaway password.
hash=$(openssl passwd -6 "$password")

# SELinux, part one. The image runs SELinux enforcing, but bcvk boots this VM
# with selinux=0, so nothing here labels a file it creates. useradd does not
# edit the account files in place, it writes replacements and renames them
# over the top, so every one of them comes out with no label at all. With an
# unlabelled /etc/passwd under an enforcing policy, dbus-broker,
# systemd-logind, systemd-homed and rtkit all fail to start, the greeter never
# comes up, and the machine sits on a text console.
#
# So remember what the contexts were and put them back. Copying the old value
# is preferred over deriving a new one from policy: setfiles cannot be used on
# this tree (see the home directory below), and the labels bootc install left
# are by definition the right ones for this disk.
account_files=(etc/passwd etc/shadow etc/group etc/gshadow)
declare -A ctx
for f in "${account_files[@]}"; do
    ctx[$f]=$(getfattr -n security.selinux --only-values "$dep/$f" 2>/dev/null || true)
done

# wheel for sudo; the shell comes from the deployment's own
# /etc/default/useradd (fish).
useradd --root "$dep" -M -G wheel -p "$hash" "$user"

# SELinux, part two: restore them. useradd also leaves a backup next to each
# file (passwd-, shadow-, ...), which is newly created and so unlabelled for
# the same reason; it takes the same context as the file it backs up.
for f in "${account_files[@]}"; do
    [ -n "${ctx[$f]:-}" ] || continue
    chcon "${ctx[$f]}" "$dep/$f"
    [ -e "$dep/$f-" ] && chcon "${ctx[$f]}" "$dep/$f-"
done

entry=$(awk -F: -v u="$user" '$1 == u { print; exit }' "$dep/etc/passwd")
home=$(cut -d: -f6 <<<"$entry")
uid=$(cut -d: -f3 <<<"$entry")
gid=$(cut -d: -f4 <<<"$entry")
# HOME=/var/home in the image's useradd defaults, so this lands on the far
# side of the var symlink, in the writable /var, exactly where /home points at
# runtime. Assert it rather than trust it: an absolute path under /var is the
# only shape this handles.
case "$home" in
    /var/home/*) ;;
    *) echo "unexpected home '$home', refusing to guess" >&2
       printf 'FAILED: home %s\n' "$home" > "$scratch/result"
       exit 1 ;;
esac

target="${dep}${home}"
mkdir -p "$target"
cp -a "$dep/etc/skel/." "$target/"
chown -R "${uid}:${gid}" "$target"
chmod 0700 "$target"

# SELinux, part three: the home. mkdir leaves it with no label at all, and
# `cp -a` copies /etc/skel's own etc_t onto it. A login against that is
# denied, and looks like the greeter simply refusing you.
#
# setfiles cannot be used here: every path into the home runs through the
# deployment's `var` symlink, which setfiles will not traverse ("Not a
# directory", with or without -r). chcon follows the symlink, so set the two
# types by hand: user_home_t inside, user_home_dir_t on the directory itself.
# Order matters, -R first then the dir.
#
# Not guarded: a disk whose home is mislabelled cannot be logged into, which
# is the entire point of this recipe, so failing here is the useful outcome.
chcon -R -t user_home_t "$target"
chcon -t user_home_dir_t "$target"

# CREATE_MAIL_SPOOL=yes in the image's useradd defaults, so there is one more
# new file out in /var to label if it was made.
spool="$dep/var/spool/mail/$user"
[ -e "$spool" ] && chcon -t mail_spool_t "$spool"

# Prove the labels are back before declaring success: a disk that boots to a
# text console with dbus-broker failing is much harder to diagnose there.
for f in "${account_files[@]}"; do
    getfattr -n security.selinux --only-values "$dep/$f" >/dev/null 2>&1 || {
        echo "$f lost its SELinux label and this disk would not boot" >&2
        printf 'FAILED: %s unlabelled\n' "$f" > "$scratch/result"
        exit 1
    }
done

printf 'OK: %s uid=%s home=%s\n' "$user" "$uid" "$home" > "$scratch/result"
