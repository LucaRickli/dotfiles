image := "localhost/fedora-bootc"
tag := "latest"
secrets := "--secret id=secureboot_key,src=keys/db/db.key --secret id=secureboot_cert,src=keys/db/db.pem"

default: build

# Needs sbctl (Arch: pacman -S sbctl, with sudo if it complains about
# permissions). Elsewhere:
#   podman run --rm -v .:/w -w /w docker.io/archlinux:latest \
#       sh -c 'pacman -Sy --noconfirm sbctl && sbctl create-keys --config keys/sbctl.conf'
#
# Generate the Secure Boot key tree (PK/KEK/db) into keys/ (once)
keygen:
    test ! -e keys/PK/PK.pem || { echo "keys/ already holds a key tree. For your own: git rm -r keys/GUID keys/PK keys/KEK keys/db"; exit 1; }
    sbctl create-keys --config keys/sbctl.conf
    test -s keys/db/db.key
    @echo "Commit keys/GUID and keys/*/*.pem. Store keys/db/db.key as the SECUREBOOT_PRIVATE_KEY repository secret for CI, and back up keys/*/*.key (enrolling a machine needs all three)."

_need-keys:
    @test -f keys/db/db.key || { echo "No Secure Boot keys. Run 'just keygen' first (see keys/README.md)."; exit 1; }

# The public half is committed and baked into the image, which verifies its
# own updates against it (overlay/etc/containers/policy.json). Empty password,
# because CI passes the key by environment variable.
#
# Generate the cosign image-signing key pair into keys/ (once)
cosign-keygen:
    test ! -e keys/cosign.key || { echo "keys/cosign.key already exists, not overwriting"; exit 1; }
    COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix keys/cosign
    chmod 600 keys/cosign.key
    @echo "Commit keys/cosign.pub. Store keys/cosign.key as the SIGNING_SECRET repository secret, and back it up."

# Uses the committed public key and no transparency log, exactly as the
# machine-side policy does.  just verify ghcr.io/lucarickli/fedora-bootc:latest
#
# Verify a pushed image's signature the way an installed machine does
verify ref:
    cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true {{ref}}

# One definition of how a sealed image is built; `build` and `build-nvidia`
# below only differ in the tag and the build args.
#
# TWO invocations, on purpose. The chunkah stage writes the rechunked OCI
# directory to out/ on the HOST (via the --volume below), and the next stage
# reads it back with `FROM oci:out`. podman's stage graph cannot see a
# dependency through the filesystem, so a podman that builds independent
# stages concurrently may evaluate `FROM oci:out` before chunkah has written
# anything ("open out/index.json: no such file or directory"). Splitting the
# build at that seam makes the ordering explicit instead of lucky. Phase one
# also hands over the kernel (kernel/), so phase two refers to nothing on the
# rootfs side and skips those stages entirely.
_build tag args="": _need-keys
    rm -rf out kernel    # chunkah refuses to overwrite a previous run's output
    # Phase 1: rootfs, split and the rechunk. Writes out/ and kernel/.
    podman build --pull=newer {{secrets}} \
        --volume "$(pwd)":/run/src {{args}} \
        --target chunkah .
    # --pull=missing from here on: the first invocation pulled everything,
    # and a base republished in between (fedora-bootc:44 moves daily) must
    # not give kernel/ a different rootfs than out/.
    podman build --pull=missing {{secrets}} \
        --volume "$(pwd)":/run/src {{args}} \
        --target kernel-out .
    # Phase 2: seal and assemble, from out/ and kernel/ only; the rootfs
    # stages are skipped.
    podman build --pull=missing {{secrets}} --skip-unused-stages {{args}} \
        --volume "$(pwd)":/run/src \
        --target final -t {{image}}:{{tag}} .

# Build the OS image (rootless podman; systemd-boot + sealed UKI signed with keys/).
build: (_build tag)

# NVIDIA variant, localhost/fedora-bootc:nvidia (kmod: open | closed, see nvidia/nvidia.sh)
build-nvidia kmod="open": (_build "nvidia" ("--build-arg SEAL=os-nvidia --build-arg NVIDIA_KMOD=" + kmod))

# What both sealed variants are built from, with its kernel still in place, so
# `bootc install` can deploy it the conventional way when the sealed image is
# inconvenient (rescue, a machine without the keys). CI builds and pushes it
# once per run and both sealed builds start from it.
#
# Build the unsealed OS image (no UKI)
build-base tag="base":
    podman build --pull=newer {{secrets}} --target os -t {{image}}:{{tag}} .

# Needs no Secure Boot key: `--target live` never builds the seal stages.
# sys_admin + label=disable are for the Flatpak install inside the build (dbus).
#
# Build the minimal live ISO image (FROM the base image, not the OS)
build-live:
    podman build --pull=newer --cap-add=sys_admin --security-opt label=disable \
        --target live -t {{image}}:live .

# Runs live/build-iso.sh inside a Fedora container with the :live image mounted
# read-only at /rootfs. `--mount type=image` needs no export or unpack and
# works rootless, so there is no sudo and no copy into root storage. CI runs
# exactly this recipe.
#
# Build the live install ISO into output/
iso: build-live
    mkdir -p output
    podman run --rm --security-opt label=disable \
        -v "$(pwd)/live/build-iso.sh":/src/build-iso.sh:ro \
        --mount type=image,source={{image}}:live,dst=/rootfs \
        -v "$(pwd)/output":/output \
        quay.io/fedora/fedora:latest /src/build-iso.sh

# CI builds and pushes the same thing (.github/workflows/devcontainer.yml).
#
# Build the dev container: localhost/devcontainer:latest
devcontainer:
    podman build --pull=newer -t localhost/devcontainer:latest devcontainer/

# Needs niri, noctalia, ghostty, fish and jq installed; `check-image` needs
# none of them.
#
# Validate the dotfiles + scripts on the host, without building
check:
    build_files/validate-configs.sh home/.config
    # one at a time: `bash -n a.sh b.sh` parses only a.sh (b.sh becomes $1)
    for f in build_files/*.sh nvidia/nvidia.sh live/*.sh dev/*.sh .github/actions/*/*.sh overlay/usr/libexec/fedora-bootc/xrdp-keygen; do bash -n "$f"; done
    sh -n dotfiles.sh

# Validate the dotfiles inside the built image (the image has all the tools)
check-image tag=tag:
    podman run --rm \
        -v ./build_files/validate-configs.sh:/run/validate-configs.sh:ro \
        -v ./home/.config:/run/dotfiles:ro \
        {{image}}:{{tag}} bash /run/validate-configs.sh /run/dotfiles

# Runs the wizard's user step against a deployment built out of the installed
# image's own /etc: first the failure the shim exists for (exit 12, no home
# directory, and fisherman aborts the install), then the shim not failing.
# Rootless, about a minute. Needs `just build-live` and the image the ISO
# installs (`podman pull ghcr.io/lucarickli/fedora-bootc:latest-uki`).
# `just build-live` asserts the rest of the shim (TPM2 key, scratch, mirror)
# against the live image's /etc.
#
# Reproduce the wizard's user step, and the shim that makes it work
test-useradd-shim target="ghcr.io/lucarickli/fedora-bootc:latest-uki":
    dev/test-useradd-shim.sh {{target}}

# Poke around inside a built image without booting it
shell tag=tag:
    podman run --rm -it {{image}}:{{tag}} /bin/bash

# bcvk boots a throwaway VM and runs the image's own `bootc install` in it,
# rootless. Install bcvk: paru -S bootc-bcvk
# (AUR; https://github.com/bootc-dev/bcvk)
#
# The image must accept root over SSH by key: bcvk logs into its VM as root
# (hardcoded) with a key it injects as a systemd credential, so
# `PermitRootLogin no` in overlay/etc/ssh/sshd_config.d/ breaks this recipe,
# silently: anything that stops bcvk reaching root over SSH looks the same
# (the VM boots to the greeter, bcvk times out after 240s saying nothing).
# To see the guest, add --log-dir=journal,console=DIR below and read the sshd
# lines in journal.json; the default --output console shows only the SeaBIOS
# handoff, because the guest talks on hvc0.
#
# Install the image into a VM disk, output/disk.qcow2
qcow2 tag=tag:
    mkdir -p output
    bcvk to-disk --filesystem=btrfs --composefs-backend --bootloader=systemd \
        --format qcow2 --disk-size 20G {{image}}:{{tag}} output/disk.qcow2
    # bcvk (0.19) returns before its install VM has shut down and released the
    # disk, so wait until the image is unlocked or `just vm` fails on the lock
    timeout 300 sh -c 'until qemu-img info output/disk.qcow2 >/dev/null 2>&1; do sleep 2; done'

# Lets `just vm` get past the greeter. The account goes on THAT DISK ONLY: it
# is written after the install, into the deployment's writable /etc and /var;
# the image, pushed tags, ISOs and machines are never touched. See
# dev/add-demo-user.sh for why writing there is safe.
#
# The password is a throwaway in a `wheel` account, passed on the command
# line and written to a file under output/. Treat the disk as compromised and
# never point it at hardware; `just qcow2` gives a clean one.
#
#   just qcow2 && just demo-user && just vm      # log in as demo / demo
#
# Add a throwaway login to output/disk.qcow2, and to that disk only
demo-user user="demo" password="demo" disk="output/disk.qcow2":
    test -f {{disk}} || { echo "No {{disk}}. Run 'just qcow2' first."; exit 1; }
    rm -rf output/.demo-user && mkdir -p output/.demo-user
    cp dev/add-demo-user.sh output/.demo-user/
    printf '%s\n%s\n' '{{user}}' '{{password}}' > output/.demo-user/params
    # A throwaway VM booted from the image itself is the cheapest root shell
    # with btrfs and shadow tooling next to the disk: no sudo, no loopback.
    bcvk ephemeral run --rm \
        --mount-disk-file {{disk}}:target \
        --bind "$(pwd)/output/.demo-user:demo" \
        --execute /run/virtiofs-mnt-demo/add-demo-user.sh \
        {{image}}:{{tag}}
    cat output/.demo-user/result
    grep -q '^OK' output/.demo-user/result
    rm -rf output/.demo-user
    # Same bcvk 0.19 disk-lock wait as in `qcow2` above.
    timeout 300 sh -c 'until qemu-img info {{disk}} >/dev/null 2>&1; do sleep 2; done'

# ALWAYS boot-test here before touching hardware: a composefs digest problem
# shows up only at boot (dracut emergency shell). The image bakes in no users
# (the ISO wizard creates them), so reaching noctalia-greeter IS the pass; run
# `just demo-user` first to get into a session. The OVMF path is Arch's
# edk2-ovmf; on Fedora it's /usr/share/edk2/ovmf/OVMF_CODE.fd
#
# Boot the qcow2 in a throwaway QEMU VM (-snapshot: changes are discarded)
vm:
    qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -bios /usr/share/edk2/x64/OVMF.4m.fd \
        -snapshot -drive file=output/disk.qcow2,format=qcow2

# virt-fw-vars runs in a throwaway Fedora container (it is not packaged for
# Arch); the OVMF template path is Arch's edk2-ovmf.
#
# Write an OVMF variable store with the keys/ tree enrolled (Secure Boot VM)
ovmf-vars:
    mkdir -p output
    podman run --rm -v .:/work -w /work \
        -v /usr/share/edk2/x64/OVMF_VARS.4m.fd:/OVMF_VARS.fd:ro \
        registry.fedoraproject.org/fedora-minimal:44 \
        sh -c 'dnf -y install python3-virt-firmware >/dev/null && virt-fw-vars \
            --input /OVMF_VARS.fd --secure-boot \
            --set-pk  "$(cat keys/GUID)" keys/PK/PK.pem \
            --add-kek "$(cat keys/GUID)" keys/KEK/KEK.pem \
            --add-db  "$(cat keys/GUID)" keys/db/db.pem \
            -o output/OVMF_VARS_custom.4m.fd'

# Boot the qcow2 with Secure Boot enforcing against the enrolled keys/ tree
vm-secureboot: ovmf-vars
    qemu-system-x86_64 \
        -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        -drive if=pflash,format=raw,unit=1,file=output/OVMF_VARS_custom.4m.fd \
        -snapshot -drive file=output/disk.qcow2,format=qcow2

# Remove build outputs
clean:
    rm -rf output
