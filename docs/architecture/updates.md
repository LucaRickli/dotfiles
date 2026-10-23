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
   sooner: Actions, release, Run workflow. A second release in the same
   week is `<year>.<week>.<n>`: yours by hand, or `security.yml`'s (below).
4. **Machine.** `sudo bootc upgrade` stages the tag the machine follows, after
   checking its cosign signature against the key in the image, and the next
   boot runs it (`--apply` reboots right away; commands in the
   [README](../../README.md#the-os)). Nothing else moves a machine: the
   timer Fedora's bootc package enables for that is masked in the image
   (`features/updates/`), on machines installed earlier too.

The dev container (`devcontainer.yml`) is rebuilt on change, every Monday
and for a security update (below).
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
the release the Containerfiles name (`fedora-toolbox` for the dev
container), and every build first applies every stable Fedora update to it
(`dnf upgrade`, [`image/base.Containerfile`](../../image/base.Containerfile)
has the why) and records the security advisories its dnf knew, so a build
is current the day it runs, whenever Fedora last refreshed the base. A
build that lacks a critical Fedora security update its own dnf knew fails
its push (see Scanning).

**Security releases.** Every day `security.yml` checks the published images
(each sealed OS image, `live`, the dev container) for critical Fedora
security updates they lack that have been stable in Bodhi for 12 hours,
long enough for a new build to have them
([`advisories.sh`](../../.github/actions/scan-image/advisories.sh); `GATE`
there widens it). For an OS image it starts `release.yml` without a
version, which releases the HEAD of `main` as this week's next patch level,
`<year>.<week>.<n>`, with the updates in its notes; for the dev container,
`devcontainer.yml`. Every image the rebuild makes must contain them, or it
fails and the next day's check starts it again. Each opens an issue
assigned to you (label `security-release`) with what it fixed and the
command to run, or that it failed
([`watch.sh`](../../.github/actions/scan-image/watch.sh) has the details).

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

A failed run on `main` (build, check, devcontainer, flatpak, release, ci,
security, alerts), scheduled or started by hand, opens an issue assigned to
you (`notify.yml`); the workflow's next successful run closes it. A weekly PR
whose checks fail is assigned to you by Renovate. A release you publish by
hand reports through GitHub's own email.

## Scanning

Every container image is scanned right before it is pushed, and on pull
requests ([`scan-image`](../../.github/actions/scan-image/scan.sh)). trivy
runs in rootless containers with no secret, no token and, for the scan
itself, no network. The build fails on:

- any secret in the image (trivy);
- known malicious code (CWE-506 in a vulnerability database), wherever it
  is in the image;
- a critical Fedora security update the image lacks although its build's
  own dnf knew it, and in a rebuild `security.yml` started, one it was
  started for (dnf). One that reached Fedora's mirrors after the build read
  them only warns (the next build has it), and pull requests only warn on
  either;
- a critical vulnerability with a fix in a file the image adds itself, not
  from an RPM and not an upstream release it pins (trivy).

The run summary counts the rest and lists pending important Fedora updates;
the job log has every trivy finding. What needs action is also in the
Security tab as code scanning alerts, one category per image, which close
once a build no longer has them; `alerts.yml` assigns each new one to you
after every upload and once a day, which is what makes GitHub email you. A
Fedora update that only warned stays such an alert until a later build of
that image has it, and `security.yml` rebuilds the published one for it
once it is due.
The VS Code Flatpak gets the secret scan only, inside
[its build](../../devtools/flatpak/build.sh). Locally:

```sh
devtools/install.sh /tmp/scan trivy
TRIVY=/tmp/scan/bin/trivy .github/actions/scan-image/scan.sh localhost/fedora-bootc:latest-uki
```

## Workflows

| Workflow | Runs | Does |
|---|---|---|
| `ci.yml` | every PR; pushes to `.github/`, `renovate.json`, `scripts/`, `installer/`, `devtools/verify-pins.sh` | the PR gate `ci-ok`: runs the others as needed, lint (actionlint, zizmor), pin checks, signing rehearsal |
| `build.yml` | pushes that change the image; by hand; from release and ci | builds and signs `build-<sha>` images |
| `release.yml` | Mondays 10:00 UTC; by hand; from security; a release you publish | images, ISO, GitHub release, moves the tags machines follow |
| `security.yml` | daily 15:23 UTC; by hand | starts a release `<year>.<week>.<n>` or a dev container rebuild when the published images lack a critical Fedora security update that is due |
| `alerts.yml` | after build, release and devcontainer; daily | assigns new code scanning alerts to you |
| `check.yml` | dotfile changes | validates `home/.config` with the tools in the published image |
| `devcontainer.yml` | changes; Mondays; from security | builds, tests, scans, pushes and signs `ghcr.io/lucarickli/devcontainer` |
| `flatpak.yml` | changes | builds, tests, pushes and signs `ghcr.io/lucarickli/code` |
| `notify.yml` | after the others on `main` | opens and closes the failure issues |
