# Updates, scanning and CI

How a change gets from this repository onto machines, what keeps everything
current, and what stops a bad image. The workflows under `.github/workflows/`
explain their details in comments.

## From a commit to a machine

1. **Pull request.** `ci.yml` builds and tests what the PR can affect (every
   image, sealed; the dev container; the VS Code Flatpak; the live ISO),
   lints the rest and rehearses signing and promotion. Its last job,
   `ci-ok`, is the one required check: nothing merges before it is green
   (repository admins can bypass it).
2. **`main`.** `build.yml` builds every image `just images` lists (the OS
   and one per add-on), unsealed and sealed, and pushes each to one tag:
   `build-<sha>` and `build-<sha>-uki` for the OS, `build-<sha>-<add-on>`
   and `build-<sha>-<add-on>-uki` for an add-on such as `nvidia`. Its `sign`
   job then signs them (below). The newest two builds' worth of these images
   are kept, a release's `build-<sha>-live` included
   (`2 x (2 x images + 1)`: 10 today).
3. **Release.** `release.yml` runs every Monday at 10:00 UTC: it builds again,
   builds the ISO, publishes a GitHub release named `<year>.<week>` and moves
   the tags machines follow to that build: `latest` and `latest-uki` for the
   OS, `<add-on>` and `<add-on>-uki` for each add-on, and `live`. To ship
   sooner: Actions, release, Run workflow.
4. **Machine.** `sudo bootc upgrade` stages the tag the machine follows, after
   checking its cosign signature against the key in the image (commands in
   the [README](../../README.md#the-os)). The Fedora base also enables
   `bootc-fetch-apply-updates.timer`: an hour after boot and then every 8
   hours it runs `bootc upgrade --apply`, which reboots into a new image when
   there is one. It only runs where `/run/ostree-booted` exists. To turn it
   off: `sudo systemctl disable --now bootc-fetch-apply-updates.timer`.

The dev container (`devcontainer.yml`) is rebuilt on change and every Monday.
The VS Code Flatpak (`flatpak.yml`) is rebuilt only on change, because every
new image is a full download of about 950 MB for each machine that follows
it. Both are signed with the same cosign key as the OS. podman on this OS
refuses an unsigned dev container (the same `policy.json`); flatpak does not
check the Flatpak's signature (`cosign verify --key keys/cosign.pub` does).

## Signing

The job that builds and scans an image pushes it unsigned. A `sign` job then
signs every digest the run pushed and verifies it the way a machine does
([`.github/actions/sign`](../../.github/actions/sign/action.yml); in
`build.yml`, in `release.yml` for the live image, in `devcontainer.yml` and
`flatpak.yml`). It is the only job with the cosign key and runs nothing but
cosign. The Secure Boot key reaches only the jobs that build on a push, and
pull requests get neither. Kept as secrets of the `release` environment,
limited to `main` and its release tags, the keys are out of reach of every
other branch's workflows ([fork.md](../fork.md)). An unsigned tag is
unusable: machines refuse it, and a release promotes only what it verifies.

## Keeping things current

**Fedora packages** come with the base image, `quay.io/fedora/fedora-bootc` at
the release the Containerfiles name, which Fedora refreshes daily; every
build takes its current state. A critical Fedora security update the base
does not carry yet fails the push (see Scanning) until Fedora's next refresh
has it. For a fix that cannot wait for Monday, run the release workflow by
hand.

**Pins** (GitHub actions, chunkah, what features build from source in their
`build.sh` (noctalia-greeter, shimmy), VS Code, and the tools and extensions
in `devtools/`) are kept current by [Renovate](../../renovate.json):

- On weekends, every minor, patch and digest update goes into one PR,
  `renovate/weekly`, once each release is three days old (container image
  pins, which carry no release date, right away). It merges itself
  when `ci-ok` is green, and Monday's release ships it. noctalia-greeter,
  built from source, gets its own PR the same way.
- Majors get a PR of their own and wait for you. That includes the next
  Fedora release: one PR moves every Fedora pin once endoflife.date lists it.
- A GitHub action or noctalia-greeter tag that upstream moved to another
  commit gets a PR labelled `security`, never merged automatically.
- A PR that changes a development tool or extension pin also checks it
  against what upstream signs or attests for that version
  ([`devtools/verify-pins.sh`](../../devtools/verify-pins.sh): cosign, GitHub
  provenance, GPG, minisign; for an extension, the publisher's own file). It
  lists the tools whose upstream publishes nothing but a checksum. Locally,
  with cosign, gh, gpg, minisign and slsa-verifier: `devtools/verify-pins.sh`.

**By hand:** the VS Code Flatpak's Freedesktop runtime (`RUNTIME` in
`devtools/flatpak/build.sh`), once a year, when Flathub's Electron BaseApp
exists for the new branch.

## When something fails

A failed run on `main` (build, check, devcontainer, flatpak, release, ci),
scheduled or started by hand, opens an issue assigned to you (`notify.yml`);
the workflow's next successful run closes it. A weekly PR whose checks fail
is assigned to you by Renovate. A release you publish by hand reports through
GitHub's own email.

## Scanning

Every container image is scanned right before it is pushed, and on pull
requests ([`scan-image`](../../.github/actions/scan-image/scan.sh)). trivy
runs in rootless containers with no secret, no token and, for the scan
itself, no network. The build fails on:

- any secret in the image (trivy);
- known malicious code (CWE-506 in a vulnerability database), wherever it
  is in the image;
- a critical Fedora security update the image does not contain yet (dnf; a
  warning on pull requests);
- a critical vulnerability with a fix in a file the image adds itself, not
  from an RPM and not an upstream release it pins (trivy).

The run summary counts the rest and lists pending important Fedora updates;
the job log has every trivy finding. What needs action is also in the
Security tab as code scanning alerts, one category per image, which close
once a build no longer has them. The VS Code Flatpak gets the secret scan
only, inside [its build](../../devtools/flatpak/build.sh). Locally:

```sh
devtools/install.sh /tmp/scan trivy
TRIVY=/tmp/scan/bin/trivy .github/actions/scan-image/scan.sh localhost/fedora-bootc:latest-uki
```

## Workflows

| Workflow | Runs | Does |
|---|---|---|
| `ci.yml` | every PR; pushes to `.github/`, `renovate.json`, `scripts/`, `installer/`, `devtools/verify-pins.sh` | the PR gate `ci-ok`: runs the others as needed, lint (actionlint, zizmor), pin checks, signing rehearsal |
| `build.yml` | pushes that change the image; by hand; from release and ci | builds and signs `build-<sha>` images |
| `release.yml` | Mondays 10:00 UTC; by hand; a release you publish | images, ISO, GitHub release, moves the tags machines follow |
| `check.yml` | dotfile changes | validates `home/.config` with the tools in the published image |
| `devcontainer.yml` | changes; Mondays | builds, tests, scans, pushes and signs `ghcr.io/lucarickli/devcontainer` |
| `flatpak.yml` | changes | builds, tests, pushes and signs `ghcr.io/lucarickli/code` |
| `notify.yml` | after the others on `main` | opens and closes the failure issues |
