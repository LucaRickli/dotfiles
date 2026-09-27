# Rescue

First resort: the previous deployment is in the systemd-boot menu (hold Space
at power-on to show it), or run `sudo bootc rollback` from a working boot. Esc
during the boot splash shows the boot messages.

If nothing boots, start any live Linux. The composefs layout differs from
the ostree one most guides describe:

```sh
lsblk                                               # find the partitions
cryptsetup open /dev/nvme0n1p2 root                 # if encrypted
mount /dev/mapper/root /mnt                         # btrfs top level, no subvolumes
ls /mnt                                             # boot composefs ostree state
ls /mnt/composefs                                   # objects + deployment images (managed by bootc)
ls /mnt/state/deploy/                               # one dir per deployment: its etc/, var links to the shared one
ls /mnt/state/os/default/var/home                   # the shared /var, with your home
```

Your data is in `/mnt/state/os/default/var/` (home included), shared by all
deployments; copy that out. The OS itself is content-addressed under
`/mnt/composefs` plus the UKIs on the ESP, and nothing there is meant to be
edited.

A dracut **emergency shell** usually means the disk does not match the sealed
kernel arguments (see the disk contract in [install.md](install.md));
`journalctl -b` there shows what failed. The console uses the `ch` keymap.

To repair, boot the previous UKI, or reinstall over the same disk:
`bootc install to-filesystem` on the existing, mounted filesystem keeps
`/state`, and with it your home. To look at the image's userspace without
booting it: `podman run -it ghcr.io/lucarickli/fedora-bootc:latest /bin/bash`.
