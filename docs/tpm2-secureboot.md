# TPM2 + Secure Boot

## Prerequisites & Assumptions

- Arch is installed and boots (even if only with passphrase)
- systemd-boot is your bootloader
- LUKS2 on `/dev/nvme1n1p2`, Btrfs with `@` + `@home` subvolumes
- Windows on separate disk (untouched throughout)
- You're running this from your **live Arch install** (not chroot)

## Phase 1 — Dependencies

```sh
pacman -S --needed \
  sbctl \
  tpm2-tss \
  tpm2-tools \
  efitools \
  binutils
```

| Package      | Purpose                                     |
| ------------ | ------------------------------------------- |
| `sbctl`      | Manage Secure Boot keys, sign EFIs          |
| `tpm2-tss`   | TPM2 software stack (required by systemd)   |
| `tpm2-tools` | CLI tools to inspect/interact with TPM      |
| `efitools`   | Low-level EFI key manipulation              |
| `binutils`   | Required for `objcopy` used in UKI building |

## Phase 2 — Initramfs (mkinitcpio)

### 2.1 Edit hooks

```sh
nano /etc/mkinitcpio.conf
```

```text
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
```

> ⚠️ Critical rules:
>
> - `systemd` must come **before** `sd-encrypt`
> - Remove any legacy `encrypt` hook
> - Remove legacy `udev` (replaced by `systemd`)

## Phase 3 — Kernel Cmdline

### 3.1 Get your LUKS UUID

```sh
cryptsetup luksUUID /dev/nvme1n1p2
# copy this UUID, you'll use it everywhere below
```

### 3.2 Write the cmdline file

```sh
nano /etc/kernel/cmdline
```

```text
rd.luks.name=<LUKS-UUID>=cryptroot root=/dev/mapper/cryptroot rw rootflags=subvol=@ quiet splash
```

Replace `<LUKS-UUID>` with the UUID from above. **Single line, no line breaks.**

## Phase 4 — crypttab for initramfs

```sh
nano /etc/crypttab.initramfs
```

```text
cryptroot  /dev/disk/by-uuid/<LUKS-UUID>  -  tpm2-device=auto,discard
```

> Use `by-uuid` — never raw device paths like `/dev/nvme1n1p2`

## Phase 5 — UKI Configuration

### 5.1 Ensure the UKI preset exists

```sh
cat /etc/mkinitcpio.d/linux.preset
```

It should contain a `_uki` section. If not, replace with:

```sh
nano /etc/mkinitcpio.d/linux.preset
```

```ini
# mkinitcpio preset for linux

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default')

default_uki="/boot/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
```

> The key part is `default_uki=` — this tells mkinitcpio to build a UKI instead of a plain initramfs.

### 5.2 Create the output directory

```sh
mkdir -p /boot/EFI/Linux
```

### 5.3 Build the UKI

```sh
mkinitcpio -P
```

Verify it was created:

```sh
ls -lh /boot/EFI/Linux/
# Should show arch-linux.efi with a recent timestamp
```

## Phase 6 — Secure Boot

### 6.1 Check current state

```sh
sbctl status
```

You need to be in **Setup Mode** to enroll keys. If you're not:

- Reboot → UEFI firmware → clear Secure Boot keys → enter Setup Mode
- Come back and continue

### 6.2 Create your custom keys

```sh
sbctl create-keys
```

### 6.3 Enroll keys (include Microsoft keys for Windows compatibility)

```sh
sbctl enroll-keys --microsoft
```

> `--microsoft` is **mandatory** for dual boot — without it Windows won't boot

### 6.4 Sign all EFI binaries

```sh
# Sign and save to database (auto-re-signs on updates)
sbctl sign -s /boot/EFI/Linux/arch-linux.efi
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
```

### 6.5 Verify everything is signed

```sh
sbctl verify
```

Every entry should show `✔ Signed`.

### 6.6 Check Secure Boot is now active

```sh
sbctl status
```

```text
Installed:    ✓
Setup Mode:   Disabled
Secure Boot:  Enabled   ← you want this after reboot
```

## Phase 7 — TPM2 Enrollment

> ⚠️ **Do this after Secure Boot is enabled and stable.** PCR values must be in their final state before you bind to them.

### 7.1 Verify TPM is available

```sh
tpm2_getcap properties-fixed | grep TPMManufacturer
# Any output = TPM is accessible
```

### 7.2 Enroll TPM into LUKS2

```sh
systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=12 \
  /dev/nvme1n1p2
```

**Why PCR 12 for dual boot:**

| PCR  | Measures                | Dual-boot safe?                  |
| ---- | ----------------------- | -------------------------------- |
| 7    | Secure Boot policy/keys | ❌ Windows changes this          |
| 12   | UKI / kernel cmdline    | ✅ Only changes on kernel update |
| 7+12 | Both                    | ❌ Fragile with Windows          |

### 7.3 Confirm the TPM slot was added

```sh
systemd-cryptenroll /dev/nvme1n1p2
```

```text
SLOT  TYPE
   0  password
   1  tpm2      ← should appear
```

## Phase 8 — Pacman Hook (auto re-enroll after kernel updates)

Since PCR 12 measures your UKI, it changes whenever you update your kernel. This hook wipes and re-enrolls automatically.

### 8.1 Create the hook

```sh
mkdir -p /etc/pacman.d/hooks
nano /etc/pacman.d/hooks/tpm2-enroll.hook
```

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts

[Action]
Description = Re-enrolling TPM2 key after kernel update...
When = PostTransaction
Exec = /usr/local/bin/tpm2-reenroll.sh
NeedsTargets
```

### 8.2 Create the script

```sh
nano /usr/local/bin/tpm2-reenroll.sh
chmod +x /usr/local/bin/tpm2-reenroll.sh
```

```sh
#!/bin/bash
set -euo pipefail

DEVICE="/dev/nvme1n1p2"

echo "==> Wiping old TPM2 slot..."
systemd-cryptenroll --wipe-slot=tpm2 "$DEVICE"

echo "==> Re-enrolling TPM2 with PCR 12..."
systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=12 \
  "$DEVICE"

echo "==> TPM2 re-enrollment complete."
```

### 8.3 Also create an sbctl signing hook (if not already present)

```sh
nano /etc/pacman.d/hooks/sbctl-sign.hook
```

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = systemd

[Action]
Description = Signing EFI binaries with sbctl...
When = PostTransaction
Exec = /usr/bin/sbctl sign-all
NeedsTargets
```

## Phase 9 — Final Reboot & Verification

```sh
reboot
```

**Expected boot sequence:**

1. systemd-boot loads `arch-linux.efi` (your UKI)
2. initramfs starts, `sd-encrypt` hook runs
3. TPM2 unseals LUKS key (no password prompt)
4. Btrfs root mounted with `subvol=@`
5. Login appears

**After booting, verify:**

```sh
# Secure Boot active
sbctl status

# TPM slot intact
systemd-cryptenroll /dev/nvme1n1p2

# Correct root mount
findmnt /
# Should show /dev/mapper/cryptroot with subvol=@ in options
```

## Full Checklist Summary

```text
[ ] pacman -S sbctl tpm2-tss tpm2-tools efitools binutils
[ ] HOOKS updated in mkinitcpio.conf (sd-encrypt, no encrypt)
[ ] /etc/kernel/cmdline correct (rd.luks.name + rootflags=subvol=@)
[ ] /etc/crypttab.initramfs correct (by-uuid + tpm2-device=auto)
[ ] mkinitcpio.d preset has default_uki= defined
[ ] mkinitcpio -P succeeds, .efi file created
[ ] sbctl create-keys
[ ] sbctl enroll-keys --microsoft
[ ] sbctl sign -s (all 3 EFI paths)
[ ] sbctl verify (all ✔)
[ ] Reboot → confirm Secure Boot enabled
[ ] systemd-cryptenroll --tpm2-pcrs=12
[ ] Pacman hooks installed (re-enroll + sbctl sign-all)
[ ] Final reboot → auto-unlock confirmed
```
