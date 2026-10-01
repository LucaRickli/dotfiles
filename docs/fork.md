# Make it yours

To build and publish your own copy. Needs rootless `podman`, `just`, `sbctl`
and `cosign`, plus [`bcvk`](https://github.com/bootc-dev/bcvk), `qemu` and
OVMF for VM tests (the recipes assume Arch paths).

1. Fork and point everything at your fork:

   ```sh
   git grep -il lucarickli | xargs sed -i \
     -e 's#lucarickli/dotfiles#<you>/<repo>#g' \
     -e 's/io\.github\.lucarickli\./io.github.<you, lowercase, - as _>./g' \
     -e 's/lucarickli/<you, lowercase>/g'
   ```

2. Replace the keys with your own; commit the public halves and back up every
   `.key` file ([keys/README.md](../keys/README.md)):

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
   [`.github/rulesets/main.json`](../.github/rulesets/main.json) (Rules,
   Rulesets, New ruleset, Import a ruleset). It requires the `ci-ok` check
   from GitHub Actions before anything merges into `main`, so Renovate's
   automerge waits for the whole build ([updates.md](architecture/updates.md)), and lets
   repository admins bypass it, so you can still push to `main` directly.
5. After the first push, make the GHCR packages public. If a package already
   exists (pushed from another repository), grant this one access in the
   package settings (Manage Actions access: Write, or Admin so that CI can
   delete old builds).
6. Run the release workflow once (Actions, release): builds only push
   `build-<sha>` tags, the release publishes the ISO and the tags machines
   follow.
