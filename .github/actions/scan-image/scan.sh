#!/usr/bin/env bash
#
# Scan a locally built image before it is pushed. Run by action.yml from the
# root of the checkout; works locally the same way:
#
#   .github/actions/scan-image/scan.sh localhost/fedora-bootc:latest
#   UPSTREAM="usr/local/ var/home/dev/.vscode-server/" \
#       .github/actions/scan-image/scan.sh localhost/devcontainer:latest
#
# Needs rootless podman, jq, and the trivy binary on PATH or in $TRIVY
# (devtools/install.sh PREFIX trivy fetches the pinned one); trivy itself
# only ever runs inside containers, see below. Optional outputs, for
# action.yml: $SARIF, the findings that need action as a code scanning
# report (sarif.jq); $RESULT, "pass" or "fail", written only when the scan
# completed.
#
# Fails on what must not be published:
#   - a secret anywhere in the image (trivy's rules plus trivy-secret.yaml)
#   - a package or binary that a vulnerability database marks as malicious
#     (CWE-506, embedded malicious code: a compromised release), wherever
#     it is, RPM, upstream release or the image's own file, fixed or not
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
# Upstream releases are the paths in $UPSTREAM (space- or newline-separated
# prefixes, no leading slash: the dev container's tools, the live image's
# Flatpaks). Each is someone else's build, kept current by Renovate, by hand
# or by its remote: their vulnerabilities are for upstream to fix, and
# failing on them would only hold back every other update until upstream
# ships. Known-malicious code is the exception: a release found to be
# compromised must leave the image whoever built it.
# shellcheck disable=SC2016  # jq and awk programs, single-quoted on purpose
set -euo pipefail

image=${1:?usage: scan.sh <local image>}
here=$(cd "$(dirname "$0")" && pwd)
trivy=$(command -v "${TRIVY:-trivy}") || { echo "no trivy (PATH or \$TRIVY)" >&2; exit 1; }
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
podman image exists "$image" || { echo "no local image $image" >&2; exit 1; }

# --- trivy: secrets and vulnerabilities --------------------------------------
# trivy is a third-party binary and never runs on the host, where it would
# sit next to the job's secrets and tokens (a process on a GitHub runner can
# read every secret the job holds out of the runner's memory, and the runner
# has passwordless sudo). Each invocation is a rootless container from
# Fedora's minimal image with trivy, its database and this script's work
# directory mounted in and nothing else: no secret, no token, and, for the
# scan itself, no network. A bad trivy release can then at most lie about
# one scan. The database comes first, in a container of its own, the one
# trivy run with network, retried like the dnf metadata below.
#
# Configured by this script and trivy-secret.yaml only: trivy also reads
# TRIVY_* variables and a trivy.yaml or .trivyignore in its working
# directory, any of which would quietly drop findings. The container has no
# environment of the host's, and its working directory is the work
# directory, which holds only this script's own files.
test -s "$here/trivy-secret.yaml" || { echo "missing $here/trivy-secret.yaml" >&2; exit 1; }
scanner=registry.fedoraproject.org/fedora-minimal:44
mkdir -p "$work/cache"
in_scanner() {   # in_scanner [podman run options] -- trivy arguments
    local opts=()
    while [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    podman run --rm --pull=never --security-opt label=disable \
        -v "$trivy":/trivy:ro -v "$work/cache":/cache -v "$work":/work -w /work \
        "${opts[@]}" "$scanner" /trivy --cache-dir /cache "$@"
}
for attempt in 1 2 3; do
    podman pull --quiet "$scanner" >/dev/null && in_scanner -- image --download-db-only --quiet && break
    [ "$attempt" = 3 ] && { echo "could not download the trivy DB" >&2; exit 1; }
    echo "trivy DB download failed (attempt $attempt), retrying in 30s" >&2
    sleep 30
done
in_scanner --network=none -- --version
# The image's filesystem, mounted into the container read-only, rather than
# an archive of its layers. From an archive trivy reads only one path of a
# hardlinked file, and it skips the secret scan in layers whose history makes
# them look like a base image; a mounted tree has neither problem. The memory
# cache keeps an earlier run's result from being reused. The default timeout
# (5m) is too short for a 12 GB image.
in_scanner --network=none --mount type=image,src="$image",dst=/scan \
    -v "$here/trivy-secret.yaml":/trivy-secret.yaml:ro -- \
    rootfs --skip-db-update --cache-backend memory --quiet --timeout 60m \
    --scanners vuln,secret --secret-config /trivy-secret.yaml \
    --format json --output /work/trivy.json /scan
in_scanner --network=none -- convert --format table /work/trivy.json

# One row per finding: path, id, severity, status, package, installed, fixed,
# and "malicious" when the advisory is one of embedded malicious code
# (CWE-506). Paths without the leading slash, as trivy reports image paths.
jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]?
       | [((.PkgPath // $t) | ltrimstr("/")), .VulnerabilityID, .Severity, .Status,
          .PkgName, .InstalledVersion, (.FixedVersion // ""),
          (if (.CweIDs // []) | any(. == "CWE-506") then "malicious" else "" end)] | @tsv' \
    "$work/trivy.json" > "$work/vulns.tsv"
jq -r '.Results[]? | .Target as $t | .Secrets[]?
       | [($t | ltrimstr("/")), .RuleID, .Severity, .Title, (.StartLine | tostring)] | @tsv' \
    "$work/trivy.json" > "$work/secrets.tsv"

# Who put each flagged file there. An unsealed image carries its base's ostree
# repository (/sysroot/ostree), whose objects duplicate files that are also in
# the image under their real paths, so those are dropped; the rest are asked
# of the image's own rpm database.
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
    FILENAME == ARGV[1] { if ($1 != "") prefix[$1] = 1; next }
    FILENAME == ARGV[2] { owner[$1] = $2; next }
    $1 ~ /^sysroot\/ostree\// { next }
    {
        class = "image"
        if (owner[$1] != "" && owner[$1] != "-") class = "rpm"
        else for (p in prefix) if (index($1, p) == 1) class = "upstream"
        print class, $0
    }
' "$work/upstream.txt" "$work/owners.tsv" "$work/vulns.tsv" > "$work/classified.tsv"

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
n_malicious=$(count '$9 == "malicious"' "$work/classified.tsv")
n_image_crit=$(count '$1 == "image" && $4 == "CRITICAL" && $5 == "fixed"' "$work/classified.tsv")
n_image_high=$(count '$1 == "image" && $4 == "HIGH"' "$work/classified.tsv")
n_rpm=$(count '$1 == "rpm"' "$work/classified.tsv")
n_upstream=$(count '$1 == "upstream"' "$work/classified.tsv")
fedora() { jq -r --arg s "$1" '[.[] | select(.type == "security" and .severity == $s) | .name] | unique | length' "$work/advisories.json"; }
n_fedora_crit=$(fedora Critical)
n_fedora_imp=$(fedora Important)

failures=()
[ "$n_secrets" = 0 ] || failures+=("$n_secrets secret(s) in the image")
[ "$n_malicious" = 0 ] || failures+=("$n_malicious file(s) from a release known to carry malicious code (CWE-506)")
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
    echo "| Known-malicious code (CWE-506), in any file | $n_malicious | any |"
    echo "| Vulnerabilities in files the image adds itself | $n_image_crit critical with a fix, $n_image_high high | critical with a fix |"
    echo "| Fedora security updates not in the image yet | $n_fedora_crit critical, $n_fedora_imp important | critical |"
    echo "| trivy on RPM binaries (Fedora's advisories are what counts) | $n_rpm | malicious only |"
    echo "| trivy on upstream releases (dev tools, Flatpaks) | $n_upstream | malicious only |"
    if [ "$n_secrets" != 0 ]; then
        echo
        echo "**Secrets**"
        echo
        echo "| File | Rule | Severity | Line |"
        echo "|---|---|---|---|"
        awk -F'\t' '{ printf "| /%s | %s (%s) | %s | %s |\n", $1, $2, $4, $3, $5 }' "$work/secrets.tsv"
    fi
    if [ "$n_malicious" != 0 ]; then
        echo
        echo "**Known-malicious code**"
        echo
        echo "| File | Advisory | Package | Installed | Where |"
        echo "|---|---|---|---|---|"
        awk -F'\t' '$9 == "malicious" {
            printf "| /%s | %s | %s | %s | %s |\n", $2, $3, $6, $7, $1 }' "$work/classified.tsv"
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
