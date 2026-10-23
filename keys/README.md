# keys/

- **Secure Boot** (PK/KEK/db, `just keygen`): the db key signs systemd-boot,
  the UKI and the NVIDIA modules.
- **Image signing** (cosign, `just cosign-keygen`): CI signs every pushed
  image (the OS, the dev container, the VS Code Flatpak), and the machine
  verifies its updates and the dev container against `cosign.pub`
  (`features/updates/overlay/etc/containers/policy.json`).

The public halves live here, committed. The private keys live outside the
checkout, in the key directory `~/.local/share/fedora-bootc/keys`
(`$XDG_DATA_HOME/fedora-bootc/keys`, or the directory `FEDORA_BOOTC_KEYS`
names), in the same layout, next to copies of the GUID and the certificates:
sbctl enrolls a machine from that directory
([docs/secureboot-tpm2.md](../docs/secureboot-tpm2.md)).

```text
keys/GUID             owner GUID                      committed
keys/PK/PK.pem        platform key certificate        committed
keys/KEK/KEK.pem      key-exchange certificate        committed
keys/db/db.pem        signature-db certificate        committed  (the build needs it)
keys/cosign.pub       image-signing public key        committed  (baked into the image)

<key dir>/PK/PK.key   PRIVATE keys                    never in the checkout
<key dir>/KEK/KEK.key
<key dir>/db/db.key                                   (the build needs it)
<key dir>/cosign.key
<key dir>/GUID        copies of keys/GUID and keys/*/*.pem, for sbctl enroll-keys
<key dir>/*/*.pem
```

A build reads `db.key` and `keys/db/db.pem` as podman secrets, in the three
steps that sign and nowhere else; `SECUREBOOT_KEY` and `SECUREBOOT_CERT` name
other files (CI: a copy outside the checkout, a pull request's throwaway
pair). The key is always a file, never an environment secret. The checkout's
`keys/` is kept out of the build context except `cosign.pub`. CI needs
`db.key` and `cosign.key` as the secrets of its `release` environment
([docs/fork.md](../docs/fork.md), Make it yours).

Back up the key directory: `PK/PK.key`, `KEK/KEK.key` and `db/db.key` (sbctl
needs all three to enroll a machine) and `cosign.key`. A new Secure Boot key
means re-enrolling every machine. A new cosign key is rejected by machines
that still trust the old one, so rotate in two steps: one update signed with
the OLD key that carries the NEW public key, then sign with the new key.
