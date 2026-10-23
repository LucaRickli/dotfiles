# Variables are worked out only when a recipe uses one: ovmf_arch (below)
# can ask the host, which only the VM recipes need.
set lazy

image := "localhost/fedora-bootc"
# What qcow2, vm, shell and check-image take by default: the sealed OS.
tag := "latest-uki"

# The private keys (Secure Boot PK/KEK/db, cosign) live outside the checkout,
# in the layout of keys/ (PK/PK.key, KEK/KEK.key, db/db.key, cosign.key), so
# that nothing that reads the repo (a build context, an editor, an agent, a
# backup of the checkout) can read them. keys/ holds the public halves alone.
keys_dir := env("FEDORA_BOOTC_KEYS", data_directory() / "fedora-bootc/keys")

# The db key and its certificate, for the three steps that sign and no other:
# bootloader.sh, an add-on's package step (nvidia's modules) and the UKI.
# CI points both at files outside the checkout (a pull request's throwaway
# pair too). A file and never `--secret env=`: podman leaves an env secret
# behind in $TMPDIR (buildahNNNN) after the build, a src= one not.
sb_key := env("SECUREBOOT_KEY", keys_dir / "db/db.key")
sb_cert := env("SECUREBOOT_CERT", "keys/db/db.pem")
secrets := "--secret id=secureboot_key,src=" + sb_key + " --secret id=secureboot_cert,src=" + sb_cert
# Secret contents are not part of podman's cache key; the cert's hash is, in
# every step that signs, so a new key re-runs them instead of reusing a layer
# signed with the old one. sha256sum, so the host needs only coreutils.
sb_cert_sha := "SB_CERT_SHA256=$(sha256sum < '" + sb_cert + "' | cut -d' ' -f1)"

default: build

# Needs sbctl (Arch: pacman -S sbctl, with sudo if it complains about
# permissions). Elsewhere, the sbctl line below in a throwaway container:
#   podman run --rm -v "$(just --evaluate keys_dir)":/k -v ./keys/sbctl.conf:/sbctl.conf:ro -w /k \
#       docker.io/archlinux:latest sh -c 'pacman -Sy --noconfirm sbctl && sbctl create-keys --config /sbctl.conf'
# then the copy lines.
#
# Generate the Secure Boot key tree (PK/KEK/db): keys into the key directory, certificates into keys/ (once)
keygen: _not-in-flatpak
    #!/usr/bin/env bash
    set -euo pipefail
    test ! -e keys/PK/PK.pem || { echo "keys/ already holds a key tree. For your own: git rm -r keys/GUID keys/PK keys/KEK keys/db"; exit 1; }
    test ! -e '{{keys_dir}}/PK/PK.key' || { echo "{{keys_dir}} already holds a key tree, not overwriting"; exit 1; }
    conf=$PWD/keys/sbctl.conf
    mkdir -p '{{keys_dir}}'
    # sbctl resolves the config's paths against its working directory.
    (cd '{{keys_dir}}' && sbctl create-keys --config "$conf")
    test -s '{{keys_dir}}/db/db.key'
    for k in PK KEK db; do install -Dm644 "{{keys_dir}}/$k/$k.pem" "keys/$k/$k.pem"; done
    cp '{{keys_dir}}/GUID' keys/GUID
    echo "Commit keys/GUID and keys/*/*.pem. Store {{keys_dir}}/db/db.key as the SECUREBOOT_PRIVATE_KEY secret of the release environment for CI (docs/fork.md), and back up {{keys_dir}} (enrolling a machine needs all three keys)."

# The VS Code Flatpak never gets the private keys (docs/devtools.md): it sees
# no ~/.local/share, and its $XDG_DATA_HOME, where keys_dir would point and
# the keygen recipes would write, is the app's own directory. A host shell or
# a toolbox shares the home, and its keys_dir is the host's.
_not-in-flatpak:
    @test ! -e /.flatpak-info || { echo "The signing keys ({{home_directory()}}/.local/share/fedora-bootc/keys) are kept out of the VS Code Flatpak: run this from a host shell or a toolbox."; exit 1; }

_need-keys: _not-in-flatpak
    @test -f '{{sb_key}}' || { printf '%s\n' "No Secure Boot db key at {{sb_key}} (keys/README.md)." \
        "  New keys: just keygen" \
        "  Keys kept in keys/: mkdir -p '{{keys_dir}}' && (cd keys && cp -a --parents GUID PK KEK db cosign.key '{{keys_dir}}/' && rm PK/PK.key KEK/KEK.key db/db.key cosign.key)"; exit 1; }
    @test -f '{{sb_cert}}' || { echo "No Secure Boot db certificate at {{sb_cert}}: just keygen writes it, then commit keys/*/*.pem."; exit 1; }

# The public half is committed and baked into the image, which verifies its
# own updates against it (features/updates/overlay/etc/containers/policy.json). Empty password,
# because CI passes the key by environment variable.
#
# Generate the cosign image-signing key pair: the key into the key directory, keys/cosign.pub (once)
cosign-keygen: _not-in-flatpak
    #!/usr/bin/env bash
    set -euo pipefail
    test ! -e '{{keys_dir}}/cosign.key' || { echo "{{keys_dir}}/cosign.key already exists, not overwriting"; exit 1; }
    test ! -e keys/cosign.pub || { echo "keys/cosign.pub already exists. For your own: git rm keys/cosign.pub"; exit 1; }
    mkdir -p '{{keys_dir}}'
    COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix '{{keys_dir}}/cosign'
    chmod 600 '{{keys_dir}}/cosign.key'
    mv '{{keys_dir}}/cosign.pub' keys/cosign.pub
    echo "Commit keys/cosign.pub. Store {{keys_dir}}/cosign.key as the SIGNING_SECRET secret of the release environment (docs/fork.md), and back it up."

# Uses the committed public key and no transparency log, exactly as the
# machine-side policy does.  just verify ghcr.io/lucarickli/fedora-bootc:latest
#
# Verify a pushed image's signature the way an installed machine does
verify ref:
    cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true {{ref}}

# The OS is built by image/base.Containerfile (unsealed), an add-on by
# image/addon.Containerfile on top of it, and image/seal.Containerfile seals
# either; the local names follow the registry's tags: :latest unsealed and
# :latest-uki sealed, :nvidia and :nvidia-uki for the NVIDIA variant.

# The OS that add-ons and seals build on. CI's image jobs pass the one the
# base job pushed, by digest, and `just build` then builds no OS of its own.
base_image := env("BASE_IMAGE", "")

# A nested `just` sees none of this run's variable overrides, so the image
# name is handed on; everything else these recipes read comes from the
# environment (SECUREBOOT_KEY, SECUREBOOT_CERT, FEDORA_BOOTC_KEYS, BASE_IMAGE).
#
# Build and seal the OS (`just build`) or an add-on on it (`just build nvidia [closed]`): :<name>, :<name>-uki
build name="latest" flavor="": _need-keys
    #!/usr/bin/env bash
    set -euo pipefail
    j() { just image='{{image}}' "$@"; }
    base='{{base_image}}'
    if [ -z "$base" ]; then j build-base; base='{{image}}:latest'; fi
    if [ '{{name}}' = latest ]; then
        j seal latest "$base"
    else
        j build-addon '{{name}}' '{{flavor}}' "$base"
        j seal '{{name}}'
    fi

# kmod: open for Turing (GTX 16 / RTX 20) and newer, closed for Maxwell to
# Volta (features/nvidia/pre-install.sh).
#
# Build and seal the NVIDIA variant: localhost/fedora-bootc:nvidia and :nvidia-uki
build-nvidia kmod="open": (build "nvidia" kmod)

# What the sealed images are built from, with its kernel still in place, so
# `bootc install` can deploy it the conventional way when the sealed image is
# inconvenient (rescue, a machine without the keys). CI builds and pushes it
# once per run and every add-on and seal starts from it.
# The only --pull=newer (Fedora's daily refresh): every later step uses
# --pull=missing, so a base republished in between cannot split an image
# from its seal.
#
# Build the unsealed OS: localhost/fedora-bootc:latest
build-base: _need-keys
    podman build --pull=newer {{secrets}} --build-arg "{{sb_cert_sha}}" \
        -f image/base.Containerfile -t {{image}}:latest .

# Every add-on (features/*/pkg.yml with `addon: true`; `just images` lists
# them) is built by image/addon.Containerfile: its packages, overlay and
# setup on top of the OS. flavor reaches the add-on's scripts as
# $ADDON_FLAVOR (nvidia: open or closed). base is the OS to build on: CI
# passes the one it pushed, by digest.
#
# Build an add-on on top of the OS, unsealed: localhost/fedora-bootc:<name>
build-addon name flavor="" base=(image + ":latest"): _need-keys
    @image/features.sh features --addons | jq -e --arg n '{{name}}' 'index($n) != null' >/dev/null \
        || { echo "{{name}} is not an add-on feature (features/*/pkg.yml with addon: true; just images)"; exit 1; }
    podman build --pull=missing {{secrets}} --build-arg "{{sb_cert_sha}}" \
        --build-arg BASE_IMAGE='{{base}}' --build-arg ADDON='{{name}}' --build-arg ADDON_FLAVOR='{{flavor}}' \
        -f image/addon.Containerfile -t '{{image}}:{{name}}' .

# Three steps (image/seal.Containerfile has the why): the split build, the
# rechunk as a plain `podman run` writing into a temporary directory, then
# the UKI build against the imported result. Nothing is handed over through
# the checkout. The OCI directory needs about 10 GB under
# ${TMPDIR:-/var/tmp}, so TMPDIR must not point at a small tmpfs.
#
# Seal an image into a signed UKI: localhost/fedora-bootc:<name>-uki
seal name src=(image + ":" + name): _need-keys
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp -d -p "${TMPDIR:-/var/tmp}" fedora-bootc-seal.XXXXXX)
    trap 'rm -rf "$out"' EXIT
    # 1. By image ID from here on: the rechunk and the UKI's kernel come from
    #    this exact image. --iidfile rather than -q, so the build is not silent.
    podman build --pull=missing --build-arg BASE_IMAGE='{{src}}' --iidfile "$out/split.iid" \
        -f image/seal.Containerfile --target split -t '{{image}}:{{name}}-split' .
    split=$(sed 's/^sha256://' "$out/split.iid")
    # 2. chunkah sees the split image read-only and an empty directory, nothing
    #    else. SOURCE_DATE_EPOCH is the split image's creation time: the same
    #    image rechunks into the same layers, so an unchanged rebuild stays
    #    cached from here on.
    chunkah=$(podman build -q --pull=missing --build-arg BASE_IMAGE='{{src}}' \
        -f image/seal.Containerfile --target chunkah .)
    podman run --rm --pull=never --network=none --security-opt label=disable \
        --mount type=image,src="$split",dst=/chunkah -v "$out":/run/out \
        -e SOURCE_DATE_EPOCH="$(podman image inspect --format '{{{{.Created.Unix}}' "$split")" \
        "$chunkah" build --max-layers 256 \
        --prune /ostree --prune /sysroot/ostree --prune /kernel \
        --output oci:/run/out/oci
    test -f "$out/oci/index.json" || { echo "chunkah wrote no OCI layout" >&2; exit 1; }
    chunked=$(podman pull -q "oci:$out/oci")
    rm -rf "$out"
    # 3. The UKI against exactly the imported layers, then the final image.
    podman build --pull=missing {{secrets}} --build-arg "{{sb_cert_sha}}" \
        --build-context chunked="container-image://$chunked" \
        --build-context kernel="container-image://$split" \
        -f image/seal.Containerfile --target final -t '{{image}}:{{name}}-uki' .

# What CI builds, scans and publishes (build.yml's matrix, release.yml's
# promotion): the OS and every add-on, by name. Fails on any feature error.
#
# Print the images CI builds, as JSON: ["latest", every add-on]
images:
    @image/features.sh features --addons | jq -ec '["latest"] + .'

# chunkah writes the layers that get sealed and signed (`seal`). Its images
# are signed keyless by its own release workflow, so the digest pinned in
# image/seal.Containerfile is checked against that identity: the release
# workflow of github.com/coreos/chunkah, run for a version tag, through
# GitHub's OIDC issuer. CI runs this before every build (build.yml); locally
# it needs cosign and the network (the signature and the trust roots).
#
# Verify the pinned chunkah image's signature against its release workflow's identity
verify-chunkah:
    #!/usr/bin/env bash
    set -euo pipefail
    ref=$(awk 'toupper($1) == "FROM" && $2 ~ /chunkah/ { print $2 }' image/seal.Containerfile)
    test -n "$ref" || { echo "no chunkah FROM line in image/seal.Containerfile" >&2; exit 1; }
    cosign verify \
        --certificate-identity-regexp '^https://github\.com/coreos/chunkah/\.github/workflows/ci\.yml@refs/tags/v' \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
        "$ref" >/dev/null
    echo "chunkah $ref: signed by its release workflow"

# Needs no Secure Boot key: installer/live.Containerfile signs nothing.
# sys_admin + label=disable are for the Flatpak install inside the build (dbus).
#
# Build the minimal live ISO image (from the Fedora base image, not the OS)
build-live:
    podman build --pull=newer --cap-add=sys_admin --security-opt label=disable \
        -f installer/live.Containerfile -t {{image}}:live .

# Runs installer/build-iso.sh inside a Fedora container with the :live image
# mounted read-only at /rootfs. `--mount type=image` needs no export or unpack
# and works rootless, so there is no sudo and no copy into root storage. CI
# runs exactly this recipe.
#
# Build the live install ISO into output/
iso: build-live
    mkdir -p output
    podman run --rm --security-opt label=disable \
        -v "$(pwd)/installer/build-iso.sh":/src/build-iso.sh:ro \
        --mount type=image,source={{image}}:live,dst=/rootfs \
        -v "$(pwd)/output":/output \
        quay.io/fedora/fedora:latest /src/build-iso.sh

# CI builds and pushes the same thing (.github/workflows/devcontainer.yml).
#
# Build the dev container: localhost/devcontainer:latest
devcontainer:
    podman build --pull=newer -t localhost/devcontainer:latest devtools/

# Runs devtools/flatpak/build.sh inside a Fedora container, which then
# installs the app and runs devtools/test.sh in it (VS Code itself is
# downloaded from Microsoft for that). Privileged for flatpak's own sandbox.
# Nothing touches your own Flatpak installations, and only the two
# directories it reads are mounted, never keys/. CI runs exactly this recipe
# (.github/workflows/flatpak.yml) and pushes output/flatpak/oci.
#
# Build and test the VS Code Flatpak into output/flatpak/
flatpak:
    mkdir -p output/flatpak
    podman run --rm --privileged --security-opt label=disable \
        -v "$(pwd)/devtools":/src/devtools:ro \
        -v "$(pwd)/.github/actions/scan-image":/src/.github/actions/scan-image:ro \
        -v "$(pwd)/output/flatpak":/out \
        quay.io/fedora/fedora:latest /src/devtools/flatpak/build.sh

# What `just flatpak` built, the same OCI image CI pushes, into your own user
# installation; VS Code itself is downloaded from Microsoft at install, as on
# any machine. Run it again after a new build to replace it. The runtime
# comes from Flathub, added as a user remote if it is not one yet. Remove
# with `flatpak uninstall --user io.github.lucarickli.Code`.
#
# Install the local VS Code Flatpak build for your user
flatpak-install:
    test -d output/flatpak/oci || { echo "Nothing built yet: run just flatpak first"; exit 1; }
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user -y --reinstall "oci:$(pwd)/output/flatpak/oci"

# Needs niri, noctalia, ghostty, fish and jq installed; `check-image` needs
# none of them.
#
# Validate the dotfiles + scripts on the host, without building
check: check-syntax
    scripts/check-dotfiles.sh home/.config

# CI's lint job runs this one as it is (needs only bash, yq and jq).
#
# Check every script's syntax and how the features fit together
check-syntax:
    # one at a time: `bash -n a.sh b.sh` parses only a.sh (b.sh becomes $1)
    for f in image/*.sh installer/*.sh scripts/*.sh .github/actions/*/*.sh features/*/*.sh features/xrdp/overlay/usr/libexec/fedora-bootc/xrdp-keygen features/desktop/overlay/etc/profile.d/gcr-ssh-agent.sh devtools/*.sh devtools/flatpak/*.sh devtools/host-command devtools/claude devtools/flatpak/code devtools/flatpak/apply_extra devtools/flatpak/host-command devtools/flatpak/fish devtools/flatpak/bcvk devtools/flatpak/claude devtools/flatpak/claude-sandboxed; do bash -n "$f" || exit 1; done
    sh -n dotfiles.sh
    # pkg.yml, requires, no file shipped twice
    image/features.sh features
    # No RUN may mount the build context itself (a --mount without from=):
    # such a bind ignores .containerignore, so keys/ would be readable there.
    # Mount a stage or a build context.
    ! grep -nE -- '--mount=' image/*.Containerfile installer/*.Containerfile | grep -vE 'from=|type=secret'

# Validate the dotfiles inside the built image (the image has all the tools)
check-image tag=tag:
    podman run --rm \
        -v ./scripts/check-dotfiles.sh:/run/check-dotfiles.sh:ro \
        -v ./home/.config:/run/dotfiles:ro \
        {{image}}:{{tag}} bash /run/check-dotfiles.sh /run/dotfiles

# Runs the wizard's user step against a deployment built out of the installed
# image's own /etc: first the failure the shim exists for (exit 12, no home
# directory, and fisherman aborts the install), then the shim not failing.
# Rootless, about a minute. Needs `just build-live` and the image the ISO
# installs (`podman pull ghcr.io/lucarickli/fedora-bootc:latest-uki`).
# `just build-live` asserts the rest of the shim (TPM2 key, scratch, mirror)
# against the live image's /etc.
#
# Reproduce the wizard's user step, and the shim that makes it work
test-installer-useradd target="ghcr.io/lucarickli/fedora-bootc:latest-uki":
    scripts/test-installer-useradd.sh {{target}}

# Poke around inside a built image without booting it
shell tag=tag:
    podman run --rm -it {{image}}:{{tag}} /bin/bash

# bcvk boots a throwaway VM and runs the image's own `bootc install` in it,
# rootless, with the host's podman, qemu and virtiofsd. The VS Code Flatpak
# and the dev container (as a toolbox) carry it and run it on the host
# (docs/devtools.md); on the host itself: paru -S bootc-bcvk (Arch, AUR) or
# dnf install bcvk (Fedora). https://github.com/bootc-dev/bcvk
#
# The image must accept root over SSH by key: bcvk logs into its VM as root
# (hardcoded) with a key it injects as a systemd credential, so
# `PermitRootLogin no` in features/ssh/overlay/etc/ssh/sshd_config.d/ breaks this recipe,
# silently: anything that stops bcvk reaching root over SSH looks the same
# (the VM boots to the greeter, bcvk times out after 240s saying nothing).
# To see the guest, add --log-dir=journal,console=DIR below (bcvk does not
# create DIR) and read the sshd lines in journal.json; the default --output
# console shows only the SeaBIOS handoff, because the guest talks on hvc0.
#
# Each run leaves a sparse swap file the size of --disk-size in the host's
# /var/tmp, also when run from the VS Code Flatpak: bcvk makes it for the
# install VM and never removes it. With no bcvk VM running:
#   find /var/tmp -maxdepth 1 -name '.tmp*' -size +1G -user "$USER" -delete
#
# Install the image into a VM disk, output/disk.qcow2
qcow2 tag=tag:
    mkdir -p output
    bcvk to-disk --filesystem=btrfs --composefs-backend --bootloader=systemd \
        --format qcow2 --disk-size 20G {{image}}:{{tag}} output/disk.qcow2
    # bcvk returns before its install VM has shut down and released the disk,
    # so wait until the image is unlocked or `just vm` fails on the lock
    timeout 300 sh -c 'until qemu-img info output/disk.qcow2 >/dev/null 2>&1; do sleep 2; done'

# Lets `just vm` get past the greeter. The account goes on THAT DISK ONLY: it
# is written after the install, into the deployment's writable /etc and /var;
# the image, pushed tags, ISOs and machines are never touched. See
# scripts/vm-demo-user.sh for why writing there is safe.
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
    cp scripts/vm-demo-user.sh output/.demo-user/
    printf '%s\n%s\n' '{{user}}' '{{password}}' > output/.demo-user/params
    # A throwaway VM booted from the image itself is the cheapest root shell
    # with btrfs and shadow tooling next to the disk: no sudo, no loopback.
    bcvk ephemeral run --rm \
        --mount-disk-file {{disk}}:target \
        --bind "$(pwd)/output/.demo-user:demo" \
        --execute /run/virtiofs-mnt-demo/vm-demo-user.sh \
        {{image}}:{{tag}}
    cat output/.demo-user/result
    grep -q '^OK' output/.demo-user/result
    rm -rf output/.demo-user
    # The same disk-lock wait as in `qcow2` above.
    timeout 300 sh -c 'until qemu-img info {{disk}} >/dev/null 2>&1; do sleep 2; done'

# The host's OVMF firmware, from its edk2-ovmf: qemu runs there, and so does
# podman (ovmf-vars), also from a toolbox, which shows the host's / at
# /run/host, and from the VS Code Flatpak, which does not: there the host is
# asked through the app's host-command, with the host access qemu needs
# anyway. Arch has 4 MiB builds in /usr/share/edk2/x64;
# Fedora 2 MiB ones in /usr/share/edk2/ovmf (its 4 MiB builds are qcow2) and
# a 4 MiB OVMF.stateless.fd for a plain boot. A Secure Boot CODE and its VARS
# must be the same build. Elsewhere, set them: just ovmf_bios=PATH vm
ovmf_arch := if path_exists("/usr/share/edk2/x64") == "true" { "true" } else if path_exists("/run/host/usr/share/edk2/x64") == "true" { "true" } else if path_exists("/app/libexec/host-command") == "true" { shell('/app/libexec/host-command test -d /usr/share/edk2/x64 2>/dev/null && echo true || echo false') } else { "false" }
ovmf_bios := if ovmf_arch == "true" { "/usr/share/edk2/x64/OVMF.4m.fd" } else { "/usr/share/edk2/ovmf/OVMF.stateless.fd" }
ovmf_code := if ovmf_arch == "true" { "/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd" } else { "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd" }
ovmf_vars := if ovmf_arch == "true" { "/usr/share/edk2/x64/OVMF_VARS.4m.fd" } else { "/usr/share/edk2/ovmf/OVMF_VARS.fd" }

# ALWAYS boot-test here before touching hardware: a composefs digest problem
# shows up only at boot (dracut emergency shell). The image bakes in no users
# (the ISO wizard creates them), so reaching noctalia-greeter IS the pass; run
# `just demo-user` first to get into a session.
#
# Boot the qcow2 in a throwaway QEMU VM (-snapshot: changes are discarded)
vm:
    qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -bios {{ovmf_bios}} \
        -snapshot -drive file=output/disk.qcow2,format=qcow2

# virt-fw-vars runs in a throwaway Fedora container (it is not packaged for
# Arch). It gets the template, the three certificates, the GUID and output/,
# nothing else: it installs from the network.
#
# Write an OVMF variable store with the keys/ tree enrolled (Secure Boot VM)
ovmf-vars:
    mkdir -p output
    podman run --rm --security-opt label=disable \
        -v {{ovmf_vars}}:/OVMF_VARS.fd:ro \
        -v ./keys/GUID:/keys/GUID:ro \
        -v ./keys/PK/PK.pem:/keys/PK.pem:ro \
        -v ./keys/KEK/KEK.pem:/keys/KEK.pem:ro \
        -v ./keys/db/db.pem:/keys/db.pem:ro \
        -v ./output:/output \
        registry.fedoraproject.org/fedora-minimal:44 \
        sh -c 'dnf -y install python3-virt-firmware >/dev/null && virt-fw-vars \
            --input /OVMF_VARS.fd --secure-boot \
            --set-pk  "$(cat /keys/GUID)" /keys/PK.pem \
            --add-kek "$(cat /keys/GUID)" /keys/KEK.pem \
            --add-db  "$(cat /keys/GUID)" /keys/db.pem \
            -o /output/OVMF_VARS_custom.fd'

# With Fedora's edk2-ovmf (its 2 MiB pair), booting the image this way is
# untested.
#
# Boot the qcow2 with Secure Boot enforcing against the enrolled keys/ tree
vm-secureboot: ovmf-vars
    qemu-system-x86_64 \
        -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 4096 \
        -vga virtio -display gtk,gl=on \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,readonly=on,file={{ovmf_code}} \
        -drive if=pflash,format=raw,unit=1,file=output/OVMF_VARS_custom.fd \
        -snapshot -drive file=output/disk.qcow2,format=qcow2

# Remove build outputs
clean:
    rm -rf output
