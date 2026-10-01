# Features

The OS, one folder per feature. Each has a `pkg.yml`:

```yaml
packages: [greetd, greetd-selinux]  # RPMs it installs (required; [] for none)
exclude: [waybar]                   # RPMs kept out (weak dependencies that would only duplicate another)
requires: [sessions]                # features it needs in the same image
addon: true                         # not in the base image: built on top of it, for an image of its own
```

and may have:

| File | What it is | When it runs |
|---|---|---|
| `build.sh` | builds what Fedora does not package, from pinned upstream sources, in a throwaway system from the image's base, with the files next to it (a spec, a patch); RPMs it leaves in `$OUT/rpm` join the install, files in `$OUT/root` land on the image ([`image/builds.sh`](../image/builds.sh)) | first, base features only |
| `pre-install.sh` | what `pkg.yml` cannot say (repos from release packages, headers for the image's kernel) | before the install |
| `post-install.sh` | what must happen in the install's layer (removing keys a package generated) | right after the install: one dnf transaction for the base, one per add-on ([`image/packages.sh`](../image/packages.sh)) |
| `overlay/` | files copied verbatim onto the image; no two features may ship the same path | after the install |
| `setup.sh` | build-time setup once packages and files are in place, then the checks that prove it, in a marked `# --- Checks` section at the end | after the overlays, in name order ([`image/finalize.sh`](../image/finalize.sh)) |

[`image/features.sh`](../image/features.sh) checks all of this first, in
every build, `just check` and CI. A feature that enables services ships
`overlay/usr/lib/systemd/{system,user}-preset/80-fedora-bootc-<feature>.preset`.
Adding a base feature, a package or a build needs no change outside its
folder. To remove a feature, delete its folder; the build names any feature
that still requires it. Some are wired in elsewhere as well: the
Containerfile names updates (the live ISO's signature policy) and nvidia
(the NVIDIA images), `image/bootloader.sh` relies on boot's install config
and kernel arguments, and the installer on locale's keyboard layout (the
LUKS passphrase).

| Feature | |
|---|---|
| `base` | command-line basics, account defaults (fish, /var/home) |
| `boot` | bootc install and kernel arguments, LUKS, quiet boot, hidden boot menu |
| `cockpit` | web admin, off by default, loopback only |
| `containers` | docker next to podman, the podman API socket |
| `desktop` | the Noctalia shell, portals, keyring, file manager, audio, dark mode |
| `fail2ban` | bans repeated login failures on SSH and XRDP |
| `flatpak` | Flatpak with the Flathub and Devolutions remotes |
| `kernel-build` | kernel and module build tools |
| `llm` | shimmy, a local OpenAI-compatible LLM server on the GPU, off by default ([docs/os.md](../docs/os.md#local-llm)) |
| `locale` | timezone and keyboard layout (console, X11, Wayland) |
| `login` | greetd and noctalia-greeter (built from source, `build.sh`) |
| `nvidia` | add-on: the NVIDIA driver, its kernel module built and signed at build time ([docs/os.md](../docs/os.md#nvidia)) |
| `sessions` | niri, labwc, sway, river and wayfire, set up for Noctalia |
| `ssh` | sshd policy and its banner |
| `tailscale` | installed, not enabled |
| `terminal` | fish, ghostty, fastfetch |
| `updates` | the signature policy every update is checked against |
| `virtualization` | QEMU/KVM, libvirt, Virtual Machine Manager |
| `xrdp` | remote desktop on 3389 |
