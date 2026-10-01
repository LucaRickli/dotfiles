# Updates, scanning and CI

How a change gets from this repository onto machines, what keeps everything
current, and what stops a bad image. The workflows under `.github/workflows/`
explain their details in comments.

## From a commit to a machine

1. **Pull request.** `ci.yml` builds and tests what the PR can affect (both
   image variants, sealed; the dev container; the VS Code Flatpak; the live
   ISO), lints the rest and rehearses signing and promotion. Its last job,
   `ci-ok`, is the one required check: nothing merges before it is green
   (repository admins can bypass it).
2. **`main`.** `build.yml` builds both variants and pushes one signed tag per
   image: `build-<sha>`, `build-<sha>-uki`, `build-<sha>-nvidia`,
   `build-<sha>-nvidia-uki`. The newest ten of these images (about two
   builds) are kept.
3. **Release.** `release.yml` runs every Monday at 10:00 UTC: it builds again,
   builds the ISO, publishes a GitHub release named `<year>.<week>` and moves
   `latest`, `latest-uki`, `nvidia` and `nvidia-uki` to that build. To ship
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
new image is a full ~750 MB download for each machine that follows it.

## Keeping things current

**Fedora packages** come with the base image, `quay.io/fedora/fedora-bootc` at
the release the Containerfile names, which Fedora refreshes daily; every build takes its current state. A
critical Fedora security update the base does not carry yet fails the push
(see Scanning) until Fedora's next refresh has it. For a fix that cannot wait
for Monday, run the release workflow by hand.

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
requests ([`scan-image`](../../.github/actions/scan-image/scan.sh)). The build
fails on:

- any secret in the image (trivy);
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
TRIVY=/tmp/scan/bin/trivy .github/actions/scan-image/scan.sh localhost/fedora-bootc:latest
```

## Workflows

| Workflow | Runs | Does |
|---|---|---|
| `ci.yml` | every PR; pushes to `.github/`, `renovate.json`, `scripts/` | the PR gate `ci-ok`: runs the others as needed, lint, signing rehearsal |
| `build.yml` | pushes that change the image; by hand; from release and ci | builds and signs `build-<sha>` images |
| `release.yml` | Mondays 10:00 UTC; by hand; a release you publish | images, ISO, GitHub release, moves the tags machines follow |
| `check.yml` | dotfile changes | validates `home/.config` with the tools in the published image |
| `devcontainer.yml` | changes; Mondays | builds, tests, scans and pushes `ghcr.io/lucarickli/devcontainer` |
| `flatpak.yml` | changes | builds, tests and pushes `ghcr.io/lucarickli/code` |
| `notify.yml` | after the others on `main` | opens and closes the failure issues |
