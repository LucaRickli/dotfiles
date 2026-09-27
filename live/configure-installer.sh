#!/usr/bin/env bash
#
# Turn the :live image into a graphical installer session: greetd autologs the
# live user into labwc, labwc's autostart opens the bootc-installer Flatpak
# (tuna-os/bootc-installer), and that deploys the sealed image with
# fisherman (`bootc install to-filesystem` via its "systemd" bootloader stack:
# systemd-boot + composefs, this image's disk contract).
#
# Adapted from projectbluefin/dakota-iso (dakota/src/configure-live.sh) and
# bootc-installer's docs/live-iso.md. Differences from dakota: Fedora base
# (livesys-scripts creates `liveuser` at boot), labwc hosts the wizard, the
# installer's own icon, and no offline image embedding, so the installer pulls
# from GHCR and installs need network.
#
# Build needs: network, CAP_SYS_ADMIN (dbus/flatpak). See `just build-live`.
#
set -euxo pipefail

CTX=${CTX:-/ctx}
APP_ID="org.bootcinstaller.Installer"

# --- bootc-installer Flatpak (+ GNOME runtime from Flathub) -------------------
# overlayfs inside podman builds doesn't support O_TMPFILE; give flatpak a
# plain-directory TMPDIR instead.
mkdir -p /var/cache/flatpak-tmp
export TMPDIR=/var/cache/flatpak-tmp
# Fedora ships dbus-broker; the classic daemon (needed standalone in a build
# container) comes from the dbus-daemon package. Live variant only, so harmless.
dnf -y install dbus-daemon
mkdir -p /run/dbus
dbus-daemon --system --fork --nopidfile
sleep 1

flatpak remote-add --system --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
# Only ship the locales we might read. The GNOME runtime's Locale extension
# (every language) is about 830 MB, a third of the ISO. Set before installing
# so the rest is never downloaded.
flatpak config --system --set languages 'en;de;fr;it'
# A pinned release, checked against a hash kept here: upstream cuts several
# releases a day and publishes no checksums or signatures, and a release's
# assets can be replaced. The shims below depend on this exact fisherman. To
# move to a newer release, take its tag and digest from
#   gh api repos/tuna-os/bootc-installer/releases/latest \
#     --jq '.tag_name, (.assets[] | select(.name == "org.bootcinstaller.Installer.flatpak").digest | ltrimstr("sha256:"))'
# and re-read, in its fisherman submodule, what the useradd shim works around:
# StageFirstBootEnrollment (internal/luks/luks.go), prepareScratchDir
# (cmd/fisherman/main.go), CreateUser and writeHomeTmpfiles
# (internal/post/user.go). The asserts at the end check the names and paths the
# shims match on, not what fisherman does with them.
INSTALLER_TAG=v2026.09.26-253d6938
INSTALLER_SHA256=980bbddb4ae24d3a1bf654ac46efe19aea64bcf4ce8cfb0108135a48549768d3
curl --retry 3 -fL \
    "https://github.com/tuna-os/bootc-installer/releases/download/${INSTALLER_TAG}/${APP_ID}.flatpak" \
    -o "$TMPDIR/installer.flatpak"
echo "${INSTALLER_SHA256}  $TMPDIR/installer.flatpak" | sha256sum -c -
flatpak install --system --noninteractive --bundle "$TMPDIR/installer.flatpak"
# the installer reads its config from the host /etc (at /run/host/etc in-sandbox)
flatpak override --system --filesystem=/etc:ro "$APP_ID"

# Drop the proprietary NVIDIA GL and VAAPI extensions. flatpak installs the
# ones matching the driver on the BUILD HOST, which has nothing to do with the
# machine that boots this ISO (the live session runs on mesa), and the install
# would copy them onto every machine. About 850 MB of build-host leakage.
# `|| true` on the grep is load-bearing: on a build host without an NVIDIA
# driver there is no extension, grep exits 1, and pipefail fails the build.
nvidia_refs=$(flatpak list --system --columns=ref 2>/dev/null \
    | grep -E '(^|/)org\.freedesktop\.Platform\.(GL[0-9]*|VAAPI)\.nvidia' || true)
for ref in $nvidia_refs; do
    flatpak uninstall --system --noninteractive --force-remove "$ref" || true
done
# Media codecs: the wizard shows text and a progress bar.
flatpak uninstall --system --noninteractive --force-remove \
    org.freedesktop.Platform.codecs-extra || true
flatpak uninstall --system --noninteractive --unused || true

rm -rf /var/cache/flatpak-tmp
# ...and stop pointing TMPDIR at it, or every later mktemp fails with "No such
# file or directory" in a way that looks like some other failure.
unset TMPDIR

# fisherman, the privileged helper the wizard runs. From the Flatpak the GUI
# copies it to ~/.cache/bootc-installer and pkexecs that copy on the host (see
# the polkit rules below); /usr/local/bin/fisherman is the path its non-Flatpak
# mode and the polkit action's exec.path use.
appdir=$(find "/var/lib/flatpak/app/${APP_ID}" -name fisherman -type f | head -1 | xargs dirname)
mkdir -p /usr/local/bin
ln -sf "${appdir}/fisherman" /usr/local/bin/fisherman

# --- skopeo shim: drop signatures when exporting to an OCI layout -------------
# For a composefs image, fisherman exports the pulled image out of
# containers-storage into an OCI layout:
#
#   skopeo copy containers-storage:<ref> oci:<scratch>/oci-cache
#
# and on any image this repo publishes that fails, hard:
#
#   Can not copy signatures to oci:...: Pushing signatures for OCI images
#   is not supported
#
# precisely BECAUSE the image is signed and the live system requires that
# signature (policy.json): the verified pull stores the signature next to the
# image, and skopeo then tries to carry it into a format that cannot hold one.
# `--remove-signatures` is the answer, but the call is inside fisherman, so the
# flag has to arrive some other way. Without this, every install dies right
# after the pull.
#
# The signature has done its job by then (the pull was verified against
# /etc/pki/containers/fedora-bootc.pub), and the installed system verifies its
# own updates against the registry, so dropping it from a scratch OCI
# directory weakens nothing.
#
# /usr/local/bin because that is where fisherman looks. It does not inherit
# our PATH: the binary sets its own,
# "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", for the
# commands it runs, and invokes a bare "skopeo". Both are asserted at the end.
cat > /usr/local/bin/skopeo << 'EOF'
#!/bin/sh
# Shim: see live/configure-installer.sh. Adds --remove-signatures to `copy`,
# because the OCI layout format cannot store signatures and the images this
# installs are signed.
if [ "$1" = copy ]; then
    shift
    exec /usr/bin/skopeo copy --remove-signatures "$@"
fi
exec /usr/bin/skopeo "$@"
EOF
chmod 0755 /usr/local/bin/skopeo

# --- useradd shim: the one hook into the installed system ---------------------
# The wizard's last step creates your account with
#
#   useradd --root <target>/state/deploy/<id> --shell /bin/bash --groups <list> <name>
#
# once the image is on the disk. <target>/state/deploy/<id> is the
# composefs deployment: the installed system's writable /etc plus a `var`
# symlink to ../../os/default/var, and nothing else (no /usr, no /home). No
# other step hands out that path, so this shim is also where the installed
# /etc gets what the wizard cannot put there.
#
# 1. TPM2. With the wizard's "Use hardware-backed encryption" on (the default
#    with a TPM), fisherman stages a first-boot enrollment: a unit, and a file
#    with your LUKS passphrase in plain text for it to use. It writes both
#    under <target>/etc and <target>/usr, the raw root, which a composefs
#    system never mounts as /etc or /usr: the unit would never run and the
#    passphrase would stay in that file. So the key is deleted and the unit
#    removed here, and the TPM is bound after first boot, once the Secure Boot
#    keys are in (docs/secureboot-tpm2.md), the order that keeps it bound.
#    shred cannot overwrite in place on btrfs (copy-on-write), so the old
#    blocks keep the passphrase inside the encrypted volume; hence
#    docs/install.md says to leave that switch off.
#
# 2. SCRATCH. fisherman stages the image on the target disk, in
#    <target>/.fisherman-scratch (the OCI layout, and the image unpacked to
#    run bootc from: about 11 GB). Its own cleanup deletes that only after the
#    disk is unmounted, so it would stay on the installed system for good.
#    Nothing needs it once the image is installed.
#
# 3. THE REGISTRY MIRROR, when fedora-bootc.mirror= set one (below): its two
#    files are copied into the installed /etc, so updates use it too.
#
# 4. THE HOME DIRECTORY: "cannot create directory /var", exit 12, and
#    fisherman aborts the install there, leaving an account with no home and
#    no password. useradd chroots into the deployment, where
#    the var symlink points outside the chroot, so it cannot make
#    /var/home/<name>. So: run the real useradd with -M, then create the home
#    from OUTSIDE the chroot, where the symlink resolves. `-m` is dropped if
#    passed (useradd refuses -m with -M, exit 2).
#
#    The home has to be labelled by hand. The ISO boots with `enforcing=0`, so
#    files do get labels, but `cp -a` from /etc/skel carries skel's etc_t
#    across, and the installed system denies a login into an etc_t home. Each
#    file gets what the policy gives its path under /var/home (matchpathcon):
#    user_home_dir_t for the directory, config_home_t for .config, and so on.
#
#    Right after this, fisherman writes /etc/tmpfiles.d/fisherman-home-<name>
#    .conf to create the home on first boot. Its `Z` line would also chown and
#    relabel the whole home recursively on every boot, rootless container
#    storage included (files owned by subordinate UIDs, which would all become
#    yours). The home exists by then, so the file is masked the systemd way
#    first, a symlink to /dev/null; fisherman's write lands in /dev/null.
#
# The groups need nothing: fisherman drops the ones <deployment>/etc/group
# lacks before calling useradd. Of the wizard's fixed list (wheel, docker,
# incus-admin, libvirt, dialout) that leaves wheel and docker; dialout, like
# the rest of the base groups, is in /usr/lib/group.
#
# Two harmless messages stay in the install log:
#   "group '100' does not exist" / "the GROUP= configuration ... ignored"
#     GROUP=100 (/etc/default/useradd) is the base `users` group, also absent
#     from the deployment's /etc/group; useradd falls back to a per-user group,
#     which USERGROUPS_ENAB gives anyway.
#   "Creating mailbox file: No such file or directory"
#     CREATE_MAIL_SPOOL=yes, and /var/spool is past the same symlink. A
#     desktop account needs no mailbox.
#
# Only --root invocations (the installer's) are touched.
#
# /usr/local/bin, not /usr/local/sbin: the image has no /usr/local/sbin, and
# both come before /usr/sbin on the PATH fisherman uses.
cat > /usr/local/bin/useradd << 'EOF'
#!/bin/sh
# Shim: see live/configure-installer.sh.
real=/usr/sbin/useradd

case " $* " in
    *" --root "*) ;;
    *) exec "$real" "$@" ;;
esac

note() { echo "useradd shim: $*" >&2; }

root=""; prev=""; user=""
for arg in "$@"; do
    [ "$prev" = "--root" ] && root="$arg"
    prev="$arg"
    user="$arg"                 # the login name is the last argument
done
[ -n "$root" ] || exec "$real" "$@"

# 1. fisherman's TPM2 enrollment, staged on the raw root where nothing runs it.
case $root in
    */state/deploy/*)
        raw=${root%/state/deploy/*}
        if [ -f "$raw/etc/fisherman/tpm2-enroll.key" ]; then
            shred -u "$raw/etc/fisherman/tpm2-enroll.key"
            note "removed the staged TPM2 enrollment; bind the TPM after first boot (docs/secureboot-tpm2.md)"
        fi
        rm -f "$raw/usr/lib/systemd/system/fisherman-tpm2-enroll.service" \
              "$raw/etc/systemd/system/multi-user.target.wants/fisherman-tpm2-enroll.service"
        # Only these files live there; leave the raw root as bootc made it.
        rmdir "$raw/etc/fisherman" \
              "$raw/etc/systemd/system/multi-user.target.wants" \
              "$raw/etc/systemd/system" "$raw/etc/systemd" "$raw/etc" \
              "$raw/usr/lib/systemd/system" "$raw/usr/lib/systemd" \
              "$raw/usr/lib" "$raw/usr" 2>/dev/null

        # 2. fisherman's scratch space. fisherman mounts nothing inside it on
        # the host; --one-file-system only keeps rm out of other filesystems
        # below the top-level entries.
        if [ -d "$raw/.fisherman-scratch" ]; then
            find "$raw/.fisherman-scratch" -mindepth 1 -maxdepth 1 \
                -exec rm -rf --one-file-system {} + 2>/dev/null
            note "freed $raw/.fisherman-scratch"
        fi
        ;;
esac

# 3. The registry mirror, if the live system has one.
for f in /etc/containers/registries.conf.d/50-fedora-bootc-mirror.conf \
         /etc/containers/registries.d/50-fedora-bootc-mirror.yaml; do
    [ -f "$f" ] && [ -f "$root/etc/containers/policy.json" ] || continue
    dir=$(dirname "$root$f")
    mkdir -p "$dir" && cp "$f" "$root$f" || { note "could not copy $f"; continue; }
    chcon --reference="$root/etc/containers/policy.json" "$dir" "$root$f" 2>/dev/null ||
        note "no SELinux label on $root$f"
    note "copied $f to the installed system"
done

# 4. The account, minus the home directory that cannot be made in there.
n=$#; i=0
while [ "$i" -lt "$n" ]; do
    arg=$1; shift; i=$((i + 1))
    case "$arg" in
        -m|--create-home) ;;
        *)                set -- "$@" "$arg" ;;
    esac
done
"$real" -M "$@" || exit $?

[ -n "$user" ] || exit 0
entry=$(awk -F: -v u="$user" '$1 == u { print; exit }' "$root/etc/passwd") || exit 0
[ -n "$entry" ] || exit 0
home=$(echo "$entry" | cut -d: -f6)
uid=$(echo "$entry" | cut -d: -f3)
gid=$(echo "$entry" | cut -d: -f4)
case "$home" in /*) ;; *) exit 0 ;; esac

# "$root$home" resolves through the deployment's var symlink, which works from
# out here even though it does not from inside the chroot.
target="${root}${home}"
mkdir -p "$target" || { note "could not create $target"; exit 0; }
[ -d "$root/etc/skel" ] && cp -a "$root/etc/skel/." "$target/" 2>/dev/null
chown -R "${uid}:${gid}" "$target" 2>/dev/null
chmod 0700 "$target" 2>/dev/null

# skel arrives carrying etc_t. Each file gets the label the policy gives its
# path under /var/home (user_home_dir_t, config_home_t for .config, ...).
home_real=$(realpath "$target")
find "$home_real" | while IFS= read -r f; do
    ctx=$(matchpathcon -n "$home${f#"$home_real"}" 2>/dev/null) && chcon -h "$ctx" "$f" 2>/dev/null
done
case $(stat -c %C "$home_real" 2>/dev/null) in
    *:user_home_dir_t:*) ;;
    *) note "no SELinux label on $target" ;;
esac

# ...and no per-boot recursive chown of it (see live/configure-installer.sh).
mkdir -p "$root/etc/tmpfiles.d" &&
    ln -sfn /dev/null "$root/etc/tmpfiles.d/fisherman-home-$user.conf"
exit 0
EOF
chmod 0755 /usr/local/bin/useradd

# --- installer configuration --------------------------------------------------
# branding.json names the product in the wizard's text; without it that is the
# live system's os-release PRETTY_NAME.
mkdir -p /etc/bootc-installer
cp "$CTX"/images.json "$CTX"/recipe.json "$CTX"/branding.json /etc/bootc-installer/
touch /etc/bootc-installer/live-iso-mode      # activates live-ISO mode in the app
# fisherman's scratch when /var is on disk. On this ISO /var is on the overlay
# root, so it uses <target>/.fisherman-scratch instead (the useradd shim).
mkdir -p /var/fisherman-tmp

# --- Before the wizard starts: which image, and from where --------------------
# NVIDIA or not. The installer's own nvidia_imgref cannot do this for this ISO:
# it installs the NVIDIA image on every machine and only tracks the base one on
# machines without an NVIDIA GPU, because it expects that image embedded on the
# ISO. Here everything is pulled from the registry, so pick the tag instead: a
# PCI display-class device (0x03xxxx) from vendor 0x10de (the installer's own
# test) with a device ID of 0x1e00 or above means :nvidia-uki. That image
# carries the open kernel modules, which drive Turing (GTX 16 / RTX 20) and
# newer only; in pci.ids every Turing and newer GPU is at 0x1e00 or above and
# every older one below, and those are better off with :latest-uki (nouveau).
# Hybrid laptops count as NVIDIA.
# Kernel command line override: fedora-bootc.variant=nvidia|default
#
# A registry mirror, such as a pull-through cache:
# fedora-bootc.mirror=<host>[:<port>][/<path>] stands in for ghcr.io, so the
# image is looked for at <host>/<path>/lucarickli/fedora-bootc; an http://
# prefix allows plain HTTP. The installer keeps pulling the image by its
# ghcr.io name and containers/image sends the pulls to the mirror
# (registries.conf.d), so policy.json still requires the cosign signature. The
# signature is looked up on whichever registry served the image, hence the
# registries.d file for the mirror path: the cache has to serve cosign's
# sha256-<digest>.sig tags like any other tag. When the mirror cannot be
# reached, pulls go to ghcr.io. The useradd shim copies both files into the
# installed system.
# Not a different image name in the installer instead: nothing in policy.json
# covers another name, so that would install unverified, and the installed
# system would then track the cache for good.
mkdir -p /usr/libexec/fedora-bootc-live
cat > /usr/libexec/fedora-bootc-live/select-installer-image << 'EOF'
#!/bin/sh
# See live/configure-installer.sh. SYSFS, CONF, CONTAINERS and CMDLINE exist
# for the build test.
sysfs=${SYSFS:-/sys}
conf=${CONF:-/etc/bootc-installer}
containers=${CONTAINERS:-/etc/containers}
cmdline=${CMDLINE:-/proc/cmdline}

variant=; mirror=
for arg in $(cat "$cmdline" 2>/dev/null); do
    case $arg in
        fedora-bootc.variant=*) variant=${arg#*=} ;;
        fedora-bootc.mirror=*)  mirror=${arg#*=} ;;
    esac
done
if [ -z "$variant" ]; then
    variant=default
    for dev in "$sysfs"/bus/pci/devices/*; do
        [ -r "$dev/class" ] && [ -r "$dev/vendor" ] && [ -r "$dev/device" ] || continue
        read -r class < "$dev/class"
        read -r vendor < "$dev/vendor"
        read -r device < "$dev/device"
        case $class in 0x03*) ;; *) continue ;; esac
        [ "$vendor" = 0x10de ] && [ $((device)) -ge $((0x1e00)) ] && variant=nvidia
    done
fi

case $variant in
    nvidia)
        sed -i -e 's|:latest-uki"|:nvidia-uki"|g' \
               -e 's|"name": "Fedora bootc"|"name": "Fedora bootc (NVIDIA)"|' \
               "$conf/images.json" "$conf/recipe.json" ;;
    default) ;;
    *) echo "unknown fedora-bootc.variant=$variant, installing the default image" >&2 ;;
esac
echo "installer image: $(grep -o '"imgref": "[^"]*"' "$conf/recipe.json" | head -1)"

[ -n "$mirror" ] || exit 0
insecure=
case $mirror in
    http://*)  insecure=1; mirror=${mirror#http://} ;;
    https://*) mirror=${mirror#https://} ;;
esac
mirror=${mirror%/}
# ghcr.io/lucarickli/fedora-bootc: the imgref without its tag
repo=$(sed -n 's|.*"imgref": "\([^"]*\):[^":/]*".*|\1|p' "$conf/recipe.json" | head -1)
# What containers/image accepts as a registry and path. It refuses anything
# else only when it rewrites a pull, and then fails that pull outright instead
# of falling back to ghcr.io: a host needs a dot, a port or to be localhost,
# and path components are lowercase.
label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
if ! printf '%s\n' "$mirror" | grep -Eqx \
    "((localhost|$label(\.$label)+)(:[0-9]+)?|$label:[0-9]+)(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)*"; then
    echo "ignoring fedora-bootc.mirror=$mirror: expected <host>[:<port>][/<path>]," \
        "the host with a dot or a port, the path in lowercase" >&2
    exit 0
fi
if [ -z "$repo" ] || [ "${mirror%%/*}" = "${repo%%/*}" ]; then
    echo "ignoring fedora-bootc.mirror=$mirror: no image, or the registry itself" >&2
    exit 0
fi
location=$mirror/${repo#*/}
mkdir -p "$containers/registries.conf.d" "$containers/registries.d"
cat > "$containers/registries.conf.d/50-fedora-bootc-mirror.conf" << MIRROR
# From fedora-bootc.mirror= on the live ISO (docs/pull-through-cache.md).
# Pulls keep the image's name, and so its signature check, but try the mirror
# first.
[[registry]]
prefix = "$repo"
location = "$repo"

[[registry.mirror]]
location = "$location"
MIRROR
if [ -n "$insecure" ]; then
    echo 'insecure = true' >> "$containers/registries.conf.d/50-fedora-bootc-mirror.conf"
fi
cat > "$containers/registries.d/50-fedora-bootc-mirror.yaml" << MIRROR
# From fedora-bootc.mirror= on the live ISO: the signature is fetched from
# wherever the image came from, so look for it on the mirror as well.
docker:
  $location:
    use-sigstore-attachments: true
MIRROR
echo "registry mirror: $location${insecure:+ (plain HTTP)}"
EOF
chmod 0755 /usr/libexec/fedora-bootc-live/select-installer-image
cat > /etc/systemd/system/select-installer-image.service << 'EOF'
[Unit]
Description=Point the installer at the image this machine needs, and at a registry mirror
Before=greetd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/fedora-bootc-live/select-installer-image

[Install]
WantedBy=multi-user.target
EOF
systemctl enable select-installer-image.service

# --- launchable app entry -----------------------------------------------------
# Only the menu entry: labwc starts the wizard from its own autostart script
# further down, not from /etc/xdg/autostart, which it does not read.
# BOOTC_CUSTOM_RECIPE must use the /run/host prefix: inside the Flatpak
# sandbox the host /etc is mounted there.
mkdir -p /usr/share/applications
cat > /usr/share/applications/fedora-bootc-installer.desktop << EOF
[Desktop Entry]
Name=Fedora bootc Installer
Comment=Install Fedora bootc to your computer
Exec=flatpak run --env=BOOTC_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${APP_ID}
Icon=${APP_ID}
Type=Application
Categories=System;
EOF

# --- polkit: let liveuser run fisherman without a password --------------------
# The installer copies fisherman to a per-user cache path and pkexecs it, which
# polkit sees as the generic org.freedesktop.policykit.exec action, so grant both
# that and the installer's own action id for liveuser (live session only).
mkdir -p /usr/share/polkit-1/actions /etc/polkit-1/rules.d
cat > /usr/share/polkit-1/actions/org.bootcinstaller.Installer.policy << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.tunaos.Installer.install">
    <description>Install an operating system to disk</description>
    <message>Authentication is required to install an operating system</message>
    <icon_name>drive-harddisk</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/fisherman</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
EOF
cat > /etc/polkit-1/rules.d/99-live-installer.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.policykit.exec" ||
         action.id === "org.tunaos.Installer.install") &&
            subject.user === "liveuser" && subject.local) {
        return polkit.Result.YES;
    }
});
EOF

# --- live session: greetd autologin into labwc --------------------------------
# greetd starts labwc directly as liveuser, and labwc's own autostart script
# (written below) launches the wizard.
#
# [default_session] is greetd's own text greeter, agreety. The live image has
# no graphical greeter (that belongs to the installed system), and this is
# deliberately the diagnostic: if the autologin session ever dies, a text login
# prompt appears instead of a black screen, which says plainly that
# initial_session failed.
cat > /etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[initial_session]
command = "labwc"
user = "liveuser"

[default_session]
command = "agreety --cmd labwc"
user = "greetd"
EOF
# The installed image enables greetd through its preset in overlay/, which
# this image does not carry. The unit's Alias=display-manager.service is what
# graphical.target starts.
systemctl enable greetd.service
systemctl set-default graphical.target

# A way in when the graphical session does not come up: agreety would ask for
# a password liveuser does not have. An autologin shell on tty2 (Ctrl+Alt+F2)
# keeps the journal reachable.
mkdir -p /etc/systemd/system/getty@tty2.service.d
cat > /etc/systemd/system/getty@tty2.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I $TERM
EOF

echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# The live session's labwc config. The minimal live image does not carry
# overlay/, so these are written here rather than inherited.
mkdir -p /etc/xdg/labwc

# Keyboard layout. The LUKS passphrase chosen in the wizard is typed under
# this layout, and the installed initramfs expects the same one
# (docs/install.md).
cat > /etc/xdg/labwc/environment << 'EOF'
XKB_DEFAULT_LAYOUT=ch
EOF

# What the session starts. No desktop shell on purpose: fisherman is authorised
# by the polkit rules above rather than by an agent, and a shell would only add
# ways for the install session to break (an idle lock on a passwordless user,
# for one). BOOTC_CUSTOM_RECIPE: see the .desktop entry above.
cat > /etc/xdg/labwc/autostart << EOF
flatpak run --env=BOOTC_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${APP_ID} &
EOF

# Never sleep mid-install.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# /etc/hostname is bind-mounted during container builds; set it via tmpfiles
mkdir -p /usr/lib/tmpfiles.d
echo 'f /etc/hostname 0644 - - - fedora-bootc-live' > /usr/lib/tmpfiles.d/live-hostname.conf

# --- Assert the live session end state (fail the build, not the boot) ---------
# The live session is greetd autologging liveuser into labwc, whose autostart
# script opens the wizard. Every link in that chain is asserted, because a
# break in any of them shows up only as a black screen or a password prompt on
# a booted ISO, which is an expensive place to find out.
test "$(readlink /etc/systemd/system/display-manager.service)" = /usr/lib/systemd/system/greetd.service
grep -q '^command = "labwc"' /etc/greetd/config.toml
grep -q '^user = "liveuser"' /etc/greetd/config.toml
grep -q "$APP_ID" /etc/xdg/labwc/autostart      # the wizard is what labwc starts
grep -q '^XKB_DEFAULT_LAYOUT=ch' /etc/xdg/labwc/environment   # LUKS passphrase layout
test -x /usr/bin/labwc
# labwc dies without Xwayland and depends on it in no way rpm can see, so the
# only thing standing between a missing package and an unbootable ISO is this.
test -x /usr/bin/Xwayland
grep -q 'autologin liveuser' /etc/systemd/system/getty@tty2.service.d/autologin.conf
# What the install itself needs. fisherman runs `bootc install to-filesystem`
# inside a container of the TARGET image, so podman is the load-bearing piece;
# the base image's own bootc is not used.
rpm -q podman cryptsetup btrfs-progs dosfstools >/dev/null
# Network, or the installer cannot pull anything.
rpm -q NetworkManager NetworkManager-tui nm-connection-editor >/dev/null
# The pull is signature-checked here as well as on the installed system.
test -s /etc/pki/containers/fedora-bootc.pub
grep -q sigstoreSigned /etc/containers/policy.json
# The live image is a vehicle: none of the OS payload belongs in it.
test -z "$(rpm -qa niri noctalia noctalia-greeter ghostty)"
# Room to install in. The writable layer of the live root is a directory on
# /run, which systemd caps at 20% of RAM; these are what raise it. Without
# them an install dies with ENOSPC on any normal machine (prepare-live.sh).
# (One unit per call: with several, is-enabled succeeds if any one is.)
for unit in live-run-expand.service var-tmp.mount; do
    systemctl is-enabled "$unit" >/dev/null
done
test -s /usr/lib/systemd/zram-generator.conf
# Deliberately not bootable under Secure Boot: GRUB sits in the removable
# media slot with no shim in front of it.
test -f /boot/efi/EFI/BOOT/BOOTX64.EFI
test -z "$(rpm -qa shim shim-x64)"
# The installer helper, and the skopeo shim it has to find (see above).
test -x /usr/local/bin/fisherman
test -x /usr/local/bin/skopeo
grep -q -- '--remove-signatures' /usr/local/bin/skopeo
test -x /usr/bin/skopeo                    # the real one, which the shim execs
# podman has to work at all on this overlayfs root (prepare-live.sh).
grep -q 'mount_program' /etc/containers/storage.conf
test -x /usr/bin/fuse-overlayfs
# The useradd shim, and the real useradd it defers to. /usr/local/bin comes
# before /usr/sbin on the PATH fisherman uses, which is what makes it apply.
test -x /usr/local/bin/useradd
test -x /usr/sbin/useradd
sh -n /usr/local/bin/useradd
test "$(command -v useradd)" = /usr/local/bin/useradd
# Labels what it creates, deletes the TPM2 key. (`type -P` fails if any one of
# them is missing; `command -v` would pass if any one exists.)
type -P chcon matchpathcon shred >/dev/null
# The label the shim gives a home comes from the policy's own answer for it.
matchpathcon -n /var/home/shimtest | grep -q ':user_home_dir_t:'
# ...and it has to actually work: build a target the way the wizard leaves it
# (a deployment of this image's /etc plus a `var` symlink, and fisherman's TPM2
# staging and scratch on the raw root), give the live system a mirror, and
# make the call fisherman makes. A broken shim then costs a build, not an
# install that dies at 99% with the disk written.
shimtest=$(mktemp -d -p /tmp)
shimdep="$shimtest/state/deploy/testdeployment"
mkdir -p "$shimdep" "$shimtest/state/os/default/var/home"
cp -a /etc "$shimdep/etc"
ln -s ../../os/default/var "$shimdep/var"
mkdir -p "$shimtest/.fisherman-scratch/oci-cache/blobs"
echo layer > "$shimtest/.fisherman-scratch/oci-cache/blobs/layer"
mkdir -p "$shimtest/etc/fisherman" "$shimtest/usr/lib/systemd/system" \
    "$shimtest/etc/systemd/system/multi-user.target.wants"
echo passphrase > "$shimtest/etc/fisherman/tpm2-enroll.key"
touch "$shimtest/usr/lib/systemd/system/fisherman-tpm2-enroll.service"
ln -s /usr/lib/systemd/system/fisherman-tpm2-enroll.service \
    "$shimtest/etc/systemd/system/multi-user.target.wants/"
mkdir -p "$shimtest/conf"
cp /etc/bootc-installer/images.json /etc/bootc-installer/recipe.json "$shimtest/conf/"
echo 'fedora-bootc.mirror=cache.example.com/ghcr' > "$shimtest/cmdline"
SYSFS=/nonexistent CONF="$shimtest/conf" CMDLINE="$shimtest/cmdline" \
    /usr/libexec/fedora-bootc-live/select-installer-image
# Only wheel: fisherman passes the groups the deployment has, and this one is
# the live image's /etc, which has no docker group.
useradd --root "$shimdep" --shell /bin/bash --groups wheel \
    --comment "Shim test" shimtest
grep -q '^shimtest:' "$shimdep/etc/passwd"                # the account row exists
grep -q '^wheel:.*shimtest' "$shimdep/etc/group"          # ...and can sudo
test -d "$shimdep/var/home/shimtest"                      # home made past the symlink
test -s "$shimdep/var/home/shimtest/.bashrc"              # ...with /etc/skel in it
# ...and owned by the account: with fisherman's snippet masked (below),
# nothing else ever fixes that.
owner=$(awk -F: '$1 == "shimtest" { print $3 ":" $4 }' "$shimdep/etc/passwd")
test "$(stat -c %u:%g "$shimdep/var/home/shimtest")" = "$owner"
test "$(stat -c %u:%g "$shimdep/var/home/shimtest/.bashrc")" = "$owner"
test ! -e "$shimtest/etc"                                 # TPM2 staging gone, key too
test ! -e "$shimtest/usr"
test -z "$(ls -A "$shimtest/.fisherman-scratch")"         # scratch emptied
# fisherman's home snippet, written after the shim returns, goes nowhere.
echo "Z /var/home/shimtest - shimtest shimtest -" \
    > "$shimdep/etc/tmpfiles.d/fisherman-home-shimtest.conf"
test "$(readlink "$shimdep/etc/tmpfiles.d/fisherman-home-shimtest.conf")" = /dev/null
for f in /etc/containers/registries.conf.d/50-fedora-bootc-mirror.conf \
         /etc/containers/registries.d/50-fedora-bootc-mirror.yaml; do
    cmp "$f" "$shimdep$f"                                 # the mirror, carried over
    rm "$f"                                               # ...and not shipped
done
rm -rf "$shimtest"
# The shim leaves the groups alone because fisherman drops the ones the target
# lacks itself. One that stopped doing so would fail useradd (exit 6).
grep -q 'not present on target, skipping' "$appdir/fisherman"
# The names and paths the useradd shim matches on, so a release that renames
# one fails here instead of silently keeping the TPM2 key, the scratch or the
# per-boot chown. (A string cannot show that a path moved; see the pin above.)
for s in /etc/fisherman/tpm2-enroll.key fisherman-tpm2-enroll.service \
         .fisherman-scratch fisherman-home-; do
    grep -qaF -- "$s" "$appdir/fisherman"
done
# ...and useradd has to be called by bare name for the shim to apply at all.
test "$(grep -caE '/(usr/)?s?bin/useradd' "$appdir/fisherman" || true)" = 0
# The skopeo shim only works because fisherman looks for a bare "skopeo" on a
# PATH that starts with /usr/local. Assert that its binary still says so, so a
# future version that hardcodes a path fails the build rather than the install.
grep -q '/usr/local/sbin:/usr/local/bin:' "$appdir/fisherman"
# ...and that it does not call skopeo by absolute path, which would skip it.
# (grep -c prints 0 and exits 1 when there is no match, hence the || true.)
test "$(grep -c '/usr/bin/skopeo' "$appdir/fisherman" || true)" = 0
# The picker: enabled, ordered before the wizard, and right in every case
# (fake sysfs trees; an NVIDIA HDMI audio function is class 0x0403, not a GPU).
systemctl is-enabled select-installer-image.service >/dev/null
grep -qx 'Before=greetd.service' /etc/systemd/system/select-installer-image.service
sh -n /usr/libexec/fedora-bootc-live/select-installer-image
seltest=$(mktemp -d -p /tmp)
# pick <case> <gpu vendor> <gpu device> <kernel cmdline> <expected tag>: run
# the picker against a fake machine, then check every imgref field got that
# tag.
pick() {
    d="$seltest/$1"
    gpu="$d/sys/bus/pci/devices/0000:01:00.0"
    audio="$d/sys/bus/pci/devices/0000:01:00.1"
    mkdir -p "$gpu" "$audio" "$d/conf"
    echo 0x030000 > "$gpu/class";   echo "$2" > "$gpu/vendor";   echo "$3" > "$gpu/device"
    echo 0x040300 > "$audio/class"; echo 0x10de > "$audio/vendor"; echo 0x10f9 > "$audio/device"
    echo "$4" > "$d/cmdline"
    cp /etc/bootc-installer/images.json /etc/bootc-installer/recipe.json "$d/conf/"
    SYSFS="$d/sys" CONF="$d/conf" CONTAINERS="$d/containers" CMDLINE="$d/cmdline" \
        /usr/libexec/fedora-bootc-live/select-installer-image
    for ref in "$(jq -r '.imgref' "$d/conf/recipe.json")" \
               "$(jq -r '.images[0].imgref' "$d/conf/recipe.json")" \
               "$(jq -r '.images[0].imgref' "$d/conf/images.json")" \
               "$(jq -r '.default_image' "$d/conf/images.json")"; do
        case $ref in *":$5") ;; *) echo "picker case $1: got $ref, want :$5" >&2; exit 1 ;; esac
    done
}
pick nvidia        0x10de 0x1f08 'quiet'                              nvidia-uki  # RTX 2060
pick nvidia-new    0x10de 0x2684 'quiet'                              nvidia-uki  # RTX 4090
pick pascal        0x10de 0x1b80 'quiet'                              latest-uki  # GTX 1080
pick amd           0x1002 0x73bf 'quiet'                              latest-uki
pick force-nvidia  0x1002 0x73bf 'quiet fedora-bootc.variant=nvidia'  nvidia-uki
pick force-default 0x10de 0x1f08 'fedora-bootc.variant=default'       latest-uki
jq -e '.images[0].name == "Fedora bootc (NVIDIA)"' "$seltest/nvidia/conf/images.json" >/dev/null
# The shipped files stay on the default image; only the running copy changes.
jq -e '.imgref | endswith(":latest-uki")' /etc/bootc-installer/recipe.json >/dev/null
# mirror <case> <kernel cmdline> <expected location, - for none> <plain HTTP>:
# the files it writes, read back by podman itself.
repo=$(jq -r '.imgref | sub(":[^:/]*$"; "")' /etc/bootc-installer/recipe.json)
mirror() {
    d="$seltest/$1"
    mkdir -p "$d/conf"
    cp /etc/bootc-installer/images.json /etc/bootc-installer/recipe.json "$d/conf/"
    echo "$2" > "$d/cmdline"
    SYSFS=/nonexistent CONF="$d/conf" CONTAINERS="$d/containers" CMDLINE="$d/cmdline" \
        /usr/libexec/fedora-bootc-live/select-installer-image
    if [ "$3" = - ]; then
        test ! -e "$d/containers"
        return 0
    fi
    CONTAINERS_REGISTRIES_CONF="$d/containers/registries.conf.d/50-fedora-bootc-mirror.conf" \
        podman info --format '{{json .Registries}}' | jq -e --arg r "$repo" --arg m "$3" \
        --argjson i "$4" '.[$r] | .Location == $r and .Blocked == false
            and (.Mirrors | length) == 1 and .Mirrors[0].Location == $m
            and .Mirrors[0].Insecure == $i' >/dev/null
    grep -Fqx "  $3:" "$d/containers/registries.d/50-fedora-bootc-mirror.yaml"
    grep -Fqx "    use-sigstore-attachments: true" "$d/containers/registries.d/50-fedora-bootc-mirror.yaml"
}
mirror mirror-cache 'quiet fedora-bootc.mirror=cache.example.com/ghcr' "cache.example.com/ghcr/${repo#*/}" false
mirror mirror-http  'fedora-bootc.mirror=http://10.0.2.2:5000/'       "10.0.2.2:5000/${repo#*/}" true
mirror mirror-https 'fedora-bootc.mirror=https://harbor.example.com:8443/proxy/ghcr' \
    "harbor.example.com:8443/proxy/ghcr/${repo#*/}" false
mirror mirror-port  'fedora-bootc.mirror=nas:5000'                     "nas:5000/${repo#*/}" false
mirror mirror-local 'fedora-bootc.mirror=localhost'                    "localhost/${repo#*/}" false
mirror mirror-bad   'fedora-bootc.mirror=cache.example.com/a;b'        - false
# ...and what containers/image would refuse on every pull: no dot or port,
# uppercase in the path, a path component starting with a separator.
mirror mirror-bare  'fedora-bootc.mirror=nas'                          - false
mirror mirror-upper 'fedora-bootc.mirror=cache.example.com/GHCR'       - false
mirror mirror-dash  'fedora-bootc.mirror=cache.example.com/-x'         - false
mirror mirror-self  "fedora-bootc.mirror=${repo%%/*}"                  - false
mirror mirror-none  'quiet'                                            - false
rm -rf "$seltest"
echo "LIVE SESSION ASSERTS OK"
