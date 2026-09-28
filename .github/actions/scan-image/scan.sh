#!/usr/bin/env bash
#
# Scan a locally built image before it is pushed. Run by action.yml from the
# root of the checkout; works locally the same way:
#
#   .github/actions/scan-image/scan.sh localhost/fedora-bootc:latest
#   UPSTREAM="usr/local/ var/home/dev/.vscode-server/" \
#       .github/actions/scan-image/scan.sh localhost/devcontainer:latest
#
# Needs rootless podman, jq and yq (either flavour), and trivy on PATH or in
# $TRIVY. Optional outputs, for action.yml: $SARIF, the findings that need
# action as a code scanning report (sarif.jq); $RESULT, "pass" or "fail",
# written only when the scan completed.
#
# Fails on what must not be published:
#   - a secret anywhere in the image (trivy's rules plus trivy-secret.yaml)
#   - a CRITICAL vulnerability with a fixed version, in a file the image adds
#     itself: not installed by an RPM, not part of an upstream release (below)
#   - a Critical Fedora security update that the image does not contain yet
#     (reported, not failed, on pull requests: that is Fedora's timing, and
#     the push after the merge fails on it anyway)
# Everything else goes into the step summary, and all of trivy's findings into
# the log.
#
# Why RPM content is judged by dnf and not by trivy: trivy has no Fedora
# vulnerability data ("Unsupported os"). For a Fedora binary it can only read
# the Go or Python dependency versions compiled into it, and Fedora ships
# fixes as patches that leave those unchanged, so its findings there are
# neither complete (it sees nothing in C code, sshd, the kernel) nor reliable.
# Fedora's own advisories are.
#
# Upstream releases are the bm binaries (packages/binary.yaml) plus the paths
# in $UPSTREAM (space- or newline-separated prefixes, no leading slash: the
# dev container's toolchains, the live image's Flatpaks). Each is someone
# else's build, kept current by Renovate, by hand or by its remote: their
# findings are for upstream to fix, and failing on them would only hold back
# every other update until upstream ships.
# shellcheck disable=SC2016  # jq, yq and awk programs, single-quoted on purpose
set -euo pipefail

image=${1:?usage: scan.sh <local image>}
here=$(cd "$(dirname "$0")" && pwd)
trivy=$(command -v "${TRIVY:-trivy}") || { echo "no trivy (PATH or \$TRIVY)" >&2; exit 1; }
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
podman image exists "$image" || { echo "no local image $image" >&2; exit 1; }

# --- trivy: secrets and vulnerabilities --------------------------------------
# Configured by this script and trivy-secret.yaml only. trivy also reads
# TRIVY_* variables and a trivy.yaml or .trivyignore in its working directory,
# any of which would quietly drop findings, so those are cleared and trivy
# runs in $work.
unset "${!TRIVY_@}"
test -s "$here/trivy-secret.yaml" || { echo "missing $here/trivy-secret.yaml" >&2; exit 1; }
cd "$work"
# The DB first, retried like the dnf metadata below: those two downloads are
# the scan's only network access.
for attempt in 1 2 3; do
    "$trivy" image --download-db-only --quiet && break
    [ "$attempt" = 3 ] && { echo "could not download the trivy DB" >&2; exit 1; }
    echo "trivy DB download failed (attempt $attempt), retrying in 30s" >&2
    sleep 30
done
# The image's filesystem, mounted (rootless podman needs its own namespace for
# that), rather than an archive of its layers. From an archive trivy reads only
# one path of a hardlinked file, and it skips the secret scan in layers whose
# history makes them look like a base image; a mounted tree has neither
# problem. The memory cache keeps an earlier run's result from being reused.
# The default timeout (5m) is too short for a 12 GB image.
podman unshare bash -c '
    set -euo pipefail
    root=$(podman image mount "$1")
    trap "podman image unmount \"\$1\" >/dev/null" EXIT
    "$2" rootfs --skip-db-update --cache-backend memory --quiet --timeout 60m \
        --scanners vuln,secret --secret-config "$3" \
        --format json --output trivy.json "$root"
' scan "$image" "$trivy" "$here/trivy-secret.yaml"
"$trivy" convert --format table trivy.json
cd - >/dev/null

# One row per finding: path, id, severity, status, package, installed, fixed.
# Paths without the leading slash, as trivy reports image paths.
jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]?
       | [((.PkgPath // $t) | ltrimstr("/")), .VulnerabilityID, .Severity, .Status,
          .PkgName, .InstalledVersion, (.FixedVersion // "")] | @tsv' \
    "$work/trivy.json" > "$work/vulns.tsv"
jq -r '.Results[]? | .Target as $t | .Secrets[]?
       | [($t | ltrimstr("/")), .RuleID, .Severity, .Title, (.StartLine | tostring)] | @tsv' \
    "$work/trivy.json" > "$work/secrets.tsv"

# Who put each flagged file there. An unsealed image carries its base's ostree
# repository (/sysroot/ostree), whose objects duplicate files that are also in
# the image under their real paths, so those are dropped; the rest are asked
# of the image's own rpm database.
yq -r '.releases[] | .dst as $d | .assets[] | $d + "/" + .dst' packages/binary.yaml \
    | sed 's|^/||' > "$work/bm.txt"
# shellcheck disable=SC2086  # split into one prefix per line on purpose
printf '%s\n' ${UPSTREAM:-} > "$work/upstream.txt"
cut -f1 "$work/vulns.tsv" | grep -v '^sysroot/ostree/' | sort -u > "$work/paths.txt" || true
podman run --rm -i --pull=never --network=none --entrypoint /usr/bin/bash "$image" -c '
    while IFS= read -r p; do
        if owner=$(rpm -qf --qf "%{NAME}\n" -- "/$p" 2>/dev/null); then
            printf "%s\t%s\n" "$p" "${owner%%[[:space:]]*}"
        else
            printf "%s\t-\n" "$p"
        fi
    done' < "$work/paths.txt" > "$work/owners.tsv"
# Prefixes each row with its class: rpm, upstream or image.
awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { bm[$1] = 1; next }
    FILENAME == ARGV[2] { if ($1 != "") prefix[$1] = 1; next }
    FILENAME == ARGV[3] { owner[$1] = $2; next }
    $1 ~ /^sysroot\/ostree\// { next }
    {
        class = "image"
        if (owner[$1] != "" && owner[$1] != "-") class = "rpm"
        else if ($1 in bm) class = "upstream"
        else for (p in prefix) if (index($1, p) == 1) class = "upstream"
        print class, $0
    }
' "$work/bm.txt" "$work/upstream.txt" "$work/owners.tsv" "$work/vulns.tsv" > "$work/classified.tsv"

# --- dnf: Fedora security updates the image does not contain -----------------
# The updates repo only: it carries Fedora's advisories, and a third-party
# repository being down must not fail the scan. One row per advisory and
# package; retried like every other download here.
for attempt in 1 2 3; do
    if podman run --rm --pull=never --entrypoint /usr/bin/dnf "$image" \
           -q advisory list --security --repo=updates --json > "$work/advisories.json"; then
        break
    fi
    [ "$attempt" = 3 ] && { echo "could not read Fedora's advisories" >&2; exit 1; }
    echo "dnf advisory list failed (attempt $attempt), retrying in 30s" >&2
    sleep 30
done

# --- Verdict and summary ------------------------------------------------------
count() { awk -F'\t' "$1" "$2" | wc -l; }
n_secrets=$(wc -l < "$work/secrets.tsv")
n_image_crit=$(count '$1 == "image" && $4 == "CRITICAL" && $5 == "fixed"' "$work/classified.tsv")
n_image_high=$(count '$1 == "image" && $4 == "HIGH"' "$work/classified.tsv")
n_rpm=$(count '$1 == "rpm"' "$work/classified.tsv")
n_upstream=$(count '$1 == "upstream"' "$work/classified.tsv")
fedora() { jq -r --arg s "$1" '[.[] | select(.type == "security" and .severity == $s) | .name] | unique | length' "$work/advisories.json"; }
n_fedora_crit=$(fedora Critical)
n_fedora_imp=$(fedora Important)

failures=()
[ "$n_secrets" = 0 ] || failures+=("$n_secrets secret(s) in the image")
[ "$n_image_crit" = 0 ] || failures+=("$n_image_crit critical vulnerabilities with a fix in files the image adds itself")
if [ "$n_fedora_crit" != 0 ]; then
    if [ "${EVENT:-}" = pull_request ]; then
        echo "::warning::$n_fedora_crit Critical Fedora security update(s) are not in this image yet (fails the push after merging)"
    else
        failures+=("$n_fedora_crit Critical Fedora security update(s) not in the image yet; rebuild once its Fedora base image has them")
    fi
fi

{
    echo "### Scan of \`$image\`"
    echo
    echo "| Check | Found | Fails the build |"
    echo "|---|---|---|"
    echo "| Secrets | $n_secrets | any |"
    echo "| Vulnerabilities in files the image adds itself | $n_image_crit critical with a fix, $n_image_high high | critical with a fix |"
    echo "| Fedora security updates not in the image yet | $n_fedora_crit critical, $n_fedora_imp important | critical |"
    echo "| trivy on RPM binaries (Fedora's advisories are what counts) | $n_rpm | never |"
    echo "| trivy on upstream releases (bm binaries, toolchains, Flatpaks) | $n_upstream | never |"
    if [ "$n_secrets" != 0 ]; then
        echo
        echo "**Secrets**"
        echo
        echo "| File | Rule | Severity | Line |"
        echo "|---|---|---|---|"
        awk -F'\t' '{ printf "| /%s | %s (%s) | %s | %s |\n", $1, $2, $4, $3, $5 }' "$work/secrets.tsv"
    fi
    if [ "$n_image_crit" != 0 ]; then
        echo
        echo "**Critical, with a fix, in files the image adds itself**"
        echo
        echo "| File | Vulnerability | Package | Installed | Fixed |"
        echo "|---|---|---|---|---|"
        awk -F'\t' '$1 == "image" && $4 == "CRITICAL" && $5 == "fixed" {
            printf "| /%s | %s | %s | %s | %s |\n", $2, $3, $6, $7, $8 }' "$work/classified.tsv"
    fi
    if [ "$((n_fedora_crit + n_fedora_imp))" != 0 ]; then
        echo
        echo "**Fedora security updates not in the image yet**"
        echo
        echo "| Advisory | Severity | Packages |"
        echo "|---|---|---|"
        jq -r 'map(select(.type == "security" and (.severity == "Critical" or .severity == "Important")))
               | group_by(.name)[]
               | "| \(.[0].name) | \(.[0].severity) | \(map(.nevra) | join(", ")) |"' "$work/advisories.json"
    fi
    echo
} >> "$summary"

if [ -n "${SARIF:-}" ]; then
    jq -n --rawfile secrets "$work/secrets.tsv" --rawfile vulns "$work/classified.tsv" \
        --slurpfile adv "$work/advisories.json" \
        --arg repo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-lucarickli/dotfiles}" \
        -f "$here/sarif.jq" > "$SARIF"
fi

if [ "${#failures[@]}" != 0 ]; then
    for f in "${failures[@]}"; do echo "::error::$image: $f"; done
    if [ -n "${RESULT:-}" ]; then echo fail > "$RESULT"; fi
    exit 1
fi
if [ -n "${RESULT:-}" ]; then echo pass > "$RESULT"; fi
echo "$image: nothing that blocks a push"
