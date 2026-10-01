#!/usr/bin/env bash
#
# The updates feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Signature verification: the policy demands a cosign signature for every pull
# from the GHCR repo, so the key it names must exist and registries.d must
# enable sigstore attachments. Otherwise every `bootc upgrade` fails with
# "a signature was required".
test -s /etc/pki/containers/fedora-bootc.pub
grep -q 'sigstoreSigned' /etc/containers/policy.json
grep -q 'use-sigstore-attachments: true' /etc/containers/registries.d/ghcr-fedora-bootc.yaml
keypath=$(sed -n 's/.*"keyPath": "\([^"]*\)".*/\1/p' /etc/containers/policy.json)
test -s "$keypath"
