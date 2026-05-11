# Live CHROOT

Find the partition containing your root filesystem:

```sh
lsblk
```

Decrypt if encrypted:

```sh
cryptsetup open /dev/nvme1n1p2 cryptroot
```

Mount the root partition:

```sh
mount /dev/mapper/cryptroot /mnt

# If the root partition is a btrfs subvolume, mount it like this instead:
moubnt -o subvol=@ /dev/mapper/cryptroot /mnt

# If the root partition is not encrypted, mount it directly:
mount /dev/nvme1n1p2 /mnt
```

Mount the EFI partition:

```sh
mount /dev/nvme1n1p1 /mnt/boot
```

Chroot into the system:

```sh
arch-chroot /mnt
```
