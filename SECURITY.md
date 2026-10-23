# Security

## Supported versions

Only the newest release gets fixes. A release moves the tags machines
follow (`latest`, `latest-uki`, `nvidia`, `nvidia-uki`) and `live`, the
install ISO's system, all under `ghcr.io/lucarickli/fedora-bootc`, and
`ghcr.io/lucarickli/devcontainer:latest` is always the newest dev
container. Older `<year>.<week>` releases, `build-*` tags and dated dev
container tags get none.

## Reporting a vulnerability

Privately, through GitHub:
<https://github.com/lucarickli/dotfiles/security/advisories/new>. Not in an
issue, a pull request or a discussion, where it would be public before it
is fixed. Say what is affected (an image tag or release, a file or feature
of this repository), how to reproduce or see it, and what it allows; a
patch is welcome. The advisory is where you hear back.

## How fixes ship

- Every build applies Fedora's stable updates first, and every image is
  scanned before it is pushed: a secret, known-malicious code or a critical
  Fedora security update the build's own dnf knew stops the push
  ([updates.md](docs/architecture/updates.md#scanning)).
- A release every Monday (`<year>.<week>`), and one within a day when the
  published images, `live` and the dev container included, lack a critical
  Fedora security update that a new build has (`<year>.<week>.<n>`,
  `security.yml`), with an issue to the owner.
- Pinned tools, actions and images are kept current by Renovate
  ([updates.md](docs/architecture/updates.md#keeping-things-current)).
- A machine takes a release only when its owner runs `sudo bootc upgrade`
  (then reboots, or `--apply`); nothing moves by itself.

## Verifying what you run

Every image is signed with cosign and verifies against `keys/cosign.pub`
(`cosign verify --key keys/cosign.pub`); a machine checks every pull
against the copy it ships, and the sealed images boot only under the
Secure Boot key enrolled from `keys/`:
[updates.md](docs/architecture/updates.md#signing),
[keys/README.md](keys/README.md),
[docs/secureboot-tpm2.md](docs/secureboot-tpm2.md).

## Scope

The OS images and the install ISO, the dev container and the VS Code
Flatpak, and the CI that builds, scans, signs and releases them. A bug in
Fedora, bootc, a package or an upstream tool belongs to that project; what
this repository can fix is how it builds, configures, signs and ships them.
The dotfiles in `home/` are configuration files on a machine you own.
