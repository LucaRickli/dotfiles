# Secure Boot + TPM2 auto-unlock

Do this once the installed machine boots: enroll the keys first and bind the
TPM last, because enrolling keys changes PCR 7.

## Enroll the keys

1. Try it in a VM: `just vm-secureboot`.
2. In the firmware setup, clear the Secure Boot keys or enter setup mode.
3. Boot a Linux that has sbctl (Fedora does not package it; the Arch ISO does,
   `pacman -Sy sbctl`) and copy your key directory there
   (`~/.local/share/fedora-bootc/keys`, [keys/README.md](../keys/README.md)):
   it holds the certificates, the GUID and the private `*.key` files, and
   sbctl signs the enrollment with all three. From inside that directory, with
   `keys/sbctl.conf` from the repo next to it:

   ```sh
   sbctl enroll-keys --config sbctl.conf -m   # -m keeps Microsoft's keys
   ```

   `-m` keeps option ROMs, Windows and the shim/MOK path working.
4. Reboot with Secure Boot on, then check:

   ```sh
   mokutil --sb-state          # SecureBoot enabled
   bootctl status              # Secure Boot: enabled
   ```

From then on the machine only boots UKIs signed with this key, which is why
CI refuses to push unsigned builds.

## NVIDIA variant: shim + MOK (untested)

The kernel trusts module signatures only from shim's MOK list, not from the
firmware db, so shim has to boot first with the db certificate as a MOK:

```sh
# on the installed machine, find the shim binary and the ESP first:
rpm -ql shim-x64 | grep shimx64.efi
bootctl -p                                       # ESP path, usually /boot
sudo cp <shimx64.efi>            /boot/EFI/BOOT/BOOTX64.EFI   # shim first
sudo cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
        /boot/EFI/BOOT/grubx64.efi               # the name shim chain-loads next
openssl x509 -in keys/db/db.pem -outform DER -out /tmp/db.der
sudo mokutil --import /tmp/db.der                # choose a one-time password
sudo reboot                                      # MOK Manager: Enroll MOK, then Continue
modinfo -F signer nvidia                         # the key's CN once booted
```

Keep Secure Boot off on that machine until this has been tried. If the
modules are rejected, `nvidia-fallback.service` silently loads nouveau;
`modinfo -F signer` and `mokutil --test-key` are the diagnostics.

## TPM2 auto-unlock

Bind the LUKS volume to PCR 7 (Secure Boot state), which image updates do not
change; the passphrase stays as the fallback.

```sh
lsblk -o NAME,FSTYPE,MOUNTPOINT                            # find the crypto_LUKS partition
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
sudo systemd-cryptenroll /dev/nvme0n1p2                    # list: SLOT 0 password, SLOT 1 tpm2
```

The UKI already asks the TPM first (`kargs.d/20-luks-tpm2.toml`). If the TPM
state changes (firmware update, new keys), type the passphrase at boot, then
replace the TPM2 slot:

```sh
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p2
```
