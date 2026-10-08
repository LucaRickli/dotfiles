#!/usr/bin/env bash
#
# The updates feature at build time, run by image/finalize.sh once every
# feature's packages and overlay/ are in place: nothing to set up, only its
# checks (the marked section at the end).
#
set -euxo pipefail

# --- Checks -----------------------------------------------------------------
# Signature verification: the policy demands a cosign signature for every pull
# from the GHCR repos it names (the OS, the dev container), so each key it
# names must exist and registries.d must enable sigstore attachments for each
# repo. Otherwise every `bootc upgrade` (or dev container pull) fails with
# "a signature was required".
test -s /etc/pki/containers/fedora-bootc.pub
signed=$(jq -r '.transports.docker | to_entries[] | select(any(.value[]; .type == "sigstoreSigned")) | .key' \
    /etc/containers/policy.json)
[[ $signed == *ghcr.io/lucarickli/fedora-bootc* ]]
for repo in $signed; do
    grep -A1 -Fx "  $repo:" /etc/containers/registries.d/ghcr-fedora-bootc.yaml |
        grep -qx '    use-sigstore-attachments: true'
done
for keypath in $(jq -r '.. | .keyPath? // empty' /etc/containers/policy.json | sort -u); do
    test -s "$keypath"
done
