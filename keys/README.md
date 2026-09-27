# keys/

- **Secure Boot** (PK/KEK/db, `just keygen`): the db key signs systemd-boot,
  the UKI and the NVIDIA modules.
- **Image signing** (cosign, `just cosign-keygen`): CI signs every pushed
  image, and the machine verifies its updates against `cosign.pub`
  (`overlay/etc/containers/policy.json`).

```text
keys/GUID           owner GUID                      committed
keys/PK/PK.pem      platform key certificate        committed
keys/KEK/KEK.pem    key-exchange certificate        committed
keys/db/db.pem      signature-db certificate        committed  (the build needs it)
keys/cosign.pub     image-signing public key        committed  (baked into the image)
keys/*.key          PRIVATE keys                    git-ignored, never commit
keys/*/*.key        PRIVATE keys                    git-ignored, never commit
```

Local builds read `db.key`/`db.pem` as podman secrets; the directory is kept
out of the build context except `cosign.pub`. CI needs `db.key` and
`cosign.key` as repository secrets (README, Make it yours).

Back up every private key: `PK/PK.key`, `KEK/KEK.key` and `db/db.key` (sbctl
needs all three to enroll a machine) and `cosign.key`. A new Secure Boot key
means re-enrolling every machine. A new cosign key is rejected by machines
that still trust the old one, so rotate in two steps: one update signed with
the OLD key that carries the NEW public key, then sign with the new key.
