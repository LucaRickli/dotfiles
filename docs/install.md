# Installing

Both routes need UEFI, a network and a release (README, Make it yours, step
6): they pull `ghcr.io/lucarickli/fedora-bootc:latest-uki`, or `:nvidia-uki`
for NVIDIA. Install with Secure Boot off; enroll your keys afterwards
([secureboot-tpm2.md](secureboot-tpm2.md)). The initramfs keymap is Swiss
(`ch`), so pick a LUKS passphrase you can type on it.

## Live ISO

Write it to a USB stick (`sudo cp fedora-bootc-live.iso /dev/sdX && sync`)
and boot it; the [bootc-installer](https://github.com/tuna-os/bootc-installer)
wizard opens by itself.

- **16 GB of RAM**: the live system's writable layer is RAM, and the image
  needs about 9 GB of it.
- **Secure Boot off**: the ISO carries no shim on purpose, so it cannot boot
  a root shell on a locked-down machine.
- **Wi-Fi**: the wizard has no network step. Ctrl+Alt+F2, `nmtui`, then
  Ctrl+Alt+F1 back to the wizard.
- **NVIDIA** is detected: with a GTX 16 / RTX 20 series or newer (hybrid
  laptops included) the wizard installs `:nvidia-uki`, whose open driver
  supports nothing older. To choose yourself, press `e` in the boot menu and
  add `fedora-bootc.variant=nvidia` or `fedora-bootc.variant=default` to the
  `linux` line.
- **Through a pull-through cache**: add `fedora-bootc.mirror=<address>`
  there too ([pull-through-cache.md](pull-through-cache.md)).
- **Encryption**: set a passphrase and turn *Use hardware-backed encryption*
  (TPM2) off: on this image it only leaves a copy of the passphrase on the
  encrypted disk. If it was on, change the passphrase after first boot
  (`sudo cryptsetup luksChangeKey /dev/nvme0n1p2`). Bind the TPM after first
  boot ([secureboot-tpm2.md](secureboot-tpm2.md)).
- **Create your user in the wizard.** Nothing else creates one.
- **If the install fails**, the error is in the log (the wizard's shims for
  this image: [`live/configure-installer.sh`](../live/configure-installer.sh)):

  ```sh
  cat ~/.cache/bootc-installer/fisherman-output.log   # as liveuser
  dmesg | grep 'writable overlay'                     # space the live system has
  ```

## Manual, from any live USB

On a live system whose root is an overlay (any Fedora live ISO), podman exits
125 with `'overlay' is not supported over overlayfs` until it gets a mount
program. This repo's ISO already has it:

```sh
sudo tee /etc/containers/storage.conf > /dev/null << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
```

To pull through a cache, set that up now too
([pull-through-cache.md](pull-through-cache.md#manual-install)).

### The disk contract

The kernel command line is sealed into the UKI and has no `root=`: the
initramfs finds the root partition by GPT type. Every install must use these
partition types and filesystems:

| Partition | GPT type | Content |
| --- | --- | --- |
| ESP, 1 GiB or more | `esp` (`c12a7328-...`) | vfat, systemd-boot + the UKIs, mounted at `/boot` |
| root, rest of disk | `root (x86-64)` (`4f68bce3-...`) | btrfs **at the top level, no subvolumes**, optionally inside LUKS2 |

The ESP holds one UKI (about 270 MB) per kept deployment.

### Option A: whole disk, one command (no LUKS)

Wipes the disk and creates the layout itself:

```sh
sudo podman run --rm --privileged --pid=host \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    --security-opt label=type:unconfined_t \
    ghcr.io/lucarickli/fedora-bootc:latest-uki \
    bootc install to-disk --wipe \
      --bootloader=systemd --composefs-backend \
      /dev/nvme0n1
```

### Option B: LUKS, with systemd-repart

Run from a checkout of this repo; [`repart.d/`](../repart.d/) defines the
ESP and a LUKS2 btrfs root filling the disk.

```sh
# 1. Partition (DESTROYS the disk)
sudo systemd-repart --empty=force --dry-run=no --discard=no \
    --definitions=repart.d /dev/nvme0n1

# 2. Open and mount. repart created the LUKS volume with an EMPTY passphrase
sudo cryptsetup open /dev/nvme0n1p2 root      # just press Enter
sudo mount /dev/mapper/root /mnt
sudo mkdir /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot

# 3. Pull the image and install it into the mounted filesystem
sudo podman pull ghcr.io/lucarickli/fedora-bootc:latest-uki
sudo podman run --rm --privileged --pid=host --ipc=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
    -v /:/run/host \
    ghcr.io/lucarickli/fedora-bootc:latest-uki \
    bootc install to-filesystem \
      --source-imgref=containers-storage:ghcr.io/lucarickli/fedora-bootc:latest-uki \
      --bootloader=systemd --composefs-backend --skip-finalize \
      /run/host/mnt

# 4. Set a real LUKS passphrase, drop the empty one
sudo cryptsetup luksAddKey /dev/nvme0n1p2     # existing passphrase: Enter (empty), then your new one
sudo cryptsetup luksRemoveKey /dev/nvme0n1p2  # passphrase to remove: Enter (empty)

# 5. Done
sync
sudo umount -R /mnt
sudo cryptsetup close root
sudo reboot
```

Out of space for the pull, with enough RAM:
`sudo mount -t tmpfs -o size=10G tmpfs /var/lib/containers/storage`.
The flow follows
[travier/fedora-atomic-desktops-sealed](https://github.com/travier/fedora-atomic-desktops-sealed)
and has not been run on hardware from this repo yet (`man bootc-install`).

### A user for manual installs

The image has no users, so add `--root-ssh-authorized-keys <file>` to the
`bootc install` line. The path is read inside the container: for Option A
mount the key (`-v ~/.ssh/id_ed25519.pub:/key.pub:ro`, then `/key.pub`), for
Option B prefix it with `/run/host`. After the first boot:

```sh
ssh root@<machine>
useradd -m -G wheel <name>
passwd <name>
```

To add one offline instead, follow [`dev/add-demo-user.sh`](../dev/add-demo-user.sh)
(a composefs deployment has no `/usr` to chroot into).

## First boot

The machine boots to the Noctalia greeter; continue with "First login" in the
[README](../README.md). "wrong composefs= parameter" during install means the
sealed digest does not match the pulled image: rebuild and push. A dracut
emergency shell at boot: [rescue.md](rescue.md).
