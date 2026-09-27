# fedora-bootc

A personal Fedora 44 desktop, built as a bootable container image and
installed and updated by [bootc](https://bootc.dev/). It boots systemd-boot and
a sealed UKI ([composefs backend](https://bootc.dev/bootc/experimental-composefs.html))
signed with your own Secure Boot key, and only accepts cosign-signed updates.

greetd + noctalia-greeter, five Wayland sessions (niri, labwc, sway, river,
wayfire) running the [Noctalia](https://noctalia.dev) shell, ghostty + fish,
podman and docker, Kubernetes CLIs, XRDP, and an NVIDIA variant. Desktop apps
are Flatpaks; the dotfiles in `home/` never go into the image.

## Layout

```text
Containerfile    the image, its sealing stages, and the live ISO stage
build_files/     build scripts; finalize.sh also holds the build-time asserts
packages/        packages.txt (RPMs), binary.yaml (GitHub releases via bm),
                 flatpaks.txt (apps, installed per machine)
overlay/         copied verbatim onto the image
nvidia/          the NVIDIA variant
live/            the live installer ISO
home/.config/    dotfiles, linked into ~/.config by ./dotfiles.sh (GNU Stow)
devcontainer/    the development container (Go, Deno, Rust)
keys/            Secure Boot certificates and the cosign public key
repart.d/        partition layout for manual installs
docs/            install, pull-through cache, Secure Boot + TPM2, rescue,
                 enterprise Wi-Fi
```

## Make it yours

Needs rootless `podman`, `just`, `sbctl` and `cosign`, plus
[`bcvk`](https://github.com/bootc-dev/bcvk), `qemu` and OVMF for VM tests (the
recipes assume Arch paths).

1. Fork and point everything at your fork (not `binary.yaml`: its LucaRickli
   URLs are the bm tool):

   ```sh
   git grep -il lucarickli -- ':!packages/binary.yaml' | xargs sed -i \
     -e 's#lucarickli/dotfiles#<you>/<repo>#g' -e 's/lucarickli/<you, lowercase>/g'
   ```

2. Replace the keys with your own; commit the public halves and back up every
   `.key` file ([keys/README.md](keys/README.md)):

   ```sh
   git rm -r keys/GUID keys/PK keys/KEK keys/db keys/cosign.pub
   just keygen          # Secure Boot PK/KEK/db (sbctl)
   just cosign-keygen   # image signing key pair
   ```

3. Add the repository secrets `SECUREBOOT_PRIVATE_KEY` (`keys/db/db.key`) and
   `SIGNING_SECRET` (`keys/cosign.key`).
4. CI runs on GitHub's free hosted runners (`ubuntu-26.04`, rootless podman);
   nothing to install. A public repository gets the ~90 GB of disk a sealed
   build needs. In the repository settings: allow auto-merge, and import
   [`.github/rulesets/main.json`](.github/rulesets/main.json) (Rules,
   Rulesets, New ruleset, Import a ruleset). It requires the `ci-ok` check
   from GitHub Actions before anything merges into `main`, so Renovate's
   automerge waits for the whole build (see Automatic updates), and lets
   repository admins bypass it, so you can still push to `main` directly.
5. After the first push, make the GHCR packages public. If a package already
   exists (pushed from another repository), grant this one access in the
   package settings (Manage Actions access: Write, or Admin so that CI can
   delete old builds).
6. Run the release workflow once (Actions, release): builds only push
   `build-<sha>` tags, the release publishes the ISO and the tags below.

## Build and test

```sh
just build           # sealed image: localhost/fedora-bootc:latest
just build-nvidia    # NVIDIA variant (`just build-nvidia closed` for GTX 900/1000)
just qcow2           # install it into output/disk.qcow2
just demo-user       # optional: demo/demo login, on that disk only
just vm              # boot it; the greeter listing five sessions is the pass
just vm-secureboot   # the same with Secure Boot enforcing
just check           # validate the dotfiles and script syntax
just iso             # live installer: output/fedora-bootc-live.iso
```

The composefs backend is experimental: boot-test every build in a VM before it
goes near real hardware. `just --list` shows the rest.

## Install

Boot the live ISO (from a
[release](https://github.com/lucarickli/dotfiles/releases) or
`just iso`) and follow the wizard, or run `bootc install` from any live USB:
[docs/install.md](docs/install.md). Then enroll your Secure Boot keys and bind
LUKS to the TPM: [docs/secureboot-tpm2.md](docs/secureboot-tpm2.md).

## First login

```sh
git clone https://github.com/lucarickli/dotfiles.git
cd dotfiles
./dotfiles.sh
flatpak install -y flathub $(grep -vE '^\s*(#|$)' packages/flatpaks.txt)
```

`dotfiles.sh` links `home/.config` into `~/.config`, asking before it replaces
anything. The Flatpaks: Firefox, VS Code, Remmina and Bazaar (the app store).

## Updates

```sh
sudo bootc switch ghcr.io/lucarickli/fedora-bootc:latest-uki  # once, after installing a local build
sudo bootc upgrade             # stage the newest image for the next boot (--apply: reboot into it)
sudo bootc rollback            # back to the previous one (also in the boot menu)
sudo bootc status
```

| Tag | Image |
|---|---|
| `latest-uki` | sealed; what the ISO installs (`nvidia-uki` on NVIDIA) |
| `nvidia-uki` | sealed, with the NVIDIA driver |
| `latest`, `nvidia` | the same, unsealed (kernel in place) |
| `build-<sha>`, `build-<sha>-uki`, ... | one tag per build, for testing it; CI keeps the newest ten |

`release.yml` runs every Monday and moves the named tags to that week's build.
To pull through a cache: [docs/pull-through-cache.md](docs/pull-through-cache.md).

## Automatic updates

[Renovate](renovate.json) keeps the pins current (GitHub actions, the `bm`
binaries, chunkah, noctalia-greeter's source, the dev container's toolchains)
without anyone involved:

- On weekends it collects every minor, patch and digest update into one PR,
  `renovate/weekly`, once each release is three days old (noctalia-greeter,
  built from source, gets its own, `renovate/greeter`). `ci.yml` builds it
  (both variants, sealed; the dev container and the live ISO when touched),
  rehearses the signing and promotion steps, and the PR merges itself once
  the `ci-ok` check is green. Monday's release ships it.
- Major updates get a PR of their own and are never merged automatically.
  That includes the next Fedora release: one PR moves every Fedora pin once
  the release is actually out (endoflife.date lists it), not when the
  registries first carry its number as a tag (they carry the branched release
  and rawhide months earlier).
- You are assigned (and asked for review) only when something needs you: a
  major PR, or a weekly PR whose build failed. A failed scheduled release, or
  a failed build of `main`, opens an issue assigned to you (`notify.yml`),
  which closes itself on the next successful run. Runs you start yourself (a
  release published by hand, cleanup) are left to GitHub's own failure email.

## Development container

[`devcontainer/`](devcontainer/Containerfile) builds `ghcr.io/lucarickli/devcontainer`
(CI weekly and on change, `just devcontainer` locally): Fedora toolbox with Go,
Deno, Rust, their language servers and linters, and the VS Code extensions for
them preinstalled. In a project:

```jsonc
// .devcontainer/devcontainer.json
{ "image": "ghcr.io/lucarickli/devcontainer:latest" }
```

If docker on an SELinux host denies the workspace mount, add
`"runArgs": ["--security-opt", "label=disable"]` (podman does that itself). As
a toolbox: `toolbox create --image ghcr.io/lucarickli/devcontainer:latest dev`.

The Flatpak VS Code reaches your rootless podman through host-spawn. New
accounts are set up for it; existing ones copy the setup (and add
`dev.containers.dockerPath` by hand if they already have a `settings.json`):

```sh
cp -rn /etc/skel/.var ~
```

**Offline** (no internet for VS Code or the container):

- Move the image with `podman save` / `podman load`; the name stays the same.
- Install Dev Containers (0.447.0 or newer) from a `.vsix` (Extensions, `...`,
  Install from VSIX):
  `curl -fsSL --compressed -o dev-containers.vsix https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode-remote/vsextensions/remote-containers/0.469.0/vspackage`
- Put the VS Code Server for your VS Code's commit (Help, About) at
  `<folder>/<commit>/vscode-server-linux-x64.tar.gz`, from
  `https://update.code.visualstudio.com/commit:<commit>/server-linux-x64/stable`,
  and set `"remote.serverDownloadFolder": "<folder>"` (absolute path) in your
  user settings.

## Remote desktop (XRDP)

Port 3389, your normal account (not root), labwc by default: `niri`, `sway`,
`river` or `wayfire` in the client's alternate shell field (Remmina: Advanced,
"Start-up program"; xfreerdp: `/shell:sway`) or in `~/.config/xrdp-session`
picks another (niri needs a GPU). For resizing, enable Remmina's "Dynamic
resolution update" and "Use initial window size". Sessions log to
`~/.xrdp-session.log`; details in
[`overlay/etc/xrdp/startwm.sh`](overlay/etc/xrdp/startwm.sh).

## Other defaults

- Boot is silent: a splash with a spinner, no text (Esc shows the messages),
  and no boot menu unless you hold Space at power-on.
- SSH: passwords for users, keys only for root. fail2ban guards SSH and XRDP.
- Tailscale is installed but off:
  `sudo systemctl enable --now tailscaled && sudo tailscale up`.
- Cockpit (web admin) is installed but off:
  `sudo systemctl enable --now cockpit.socket`, then <http://localhost:9090>.
  It listens on loopback only; from another machine use
  `ssh -L 9090:localhost:9090 <user>@<machine>`. Services (fail2ban too), logs,
  firewall, storage, SELinux, files and podman containers; Fedora has no
  Cockpit plugin for docker. Its Metrics page is switched off.

## NVIDIA

`nvidia` and `nvidia-uki` add the RPM Fusion driver, built with akmods and
signed with the same db key (open kernel modules unless built with `closed`).
The live ISO installs it on machines with a GTX 16 / RTX 20 series or newer
(what the open modules support); to move an existing
install, `sudo bootc switch ghcr.io/lucarickli/fedora-bootc:nvidia-uki`.
Under Secure Boot the modules also need shim + MOK enrollment, which is
untested, so keep Secure Boot off there for now
([docs/secureboot-tpm2.md](docs/secureboot-tpm2.md)).
