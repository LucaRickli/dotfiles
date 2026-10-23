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
#   - a Critical Fedora security update the image lacks although its build's
#     own dnf knew it (advisories.sh has the rule and why): dnf could not
#     install it, or a later step replaced it. One that reached Fedora's
#     mirrors after the build read them only warns: the next build has it,
#     and security.yml releases a rebuild of the published images once it is
#     due. In a rebuild security.yml started (REQUIRE, from its `security`
#     input), also an update it was started for and does not contain.
#     Reported, not failed, on pull requests, which push nothing.
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
# advisories.sh asks dnf inside the image and applies the push gate's rule:
# the missing updates that fail the push, one per line with the reason, and
# dnf's full list for the summary and the alerts.
rule=$("$here/advisories.sh" --rule)
JSON="$work/advisories.json" "$here/advisories.sh" "$image" > "$work/gated.txt"

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
# ids WHY: the missing updates advisories.sh gives that reason, comma-separated
ids() { awk -v why="$1" '$4 == why { print $1 }' "$work/gated.txt" | paste -sd,; }
fedora_failures=()
[ -z "$(ids seen)" ] || fedora_failures+=("Fedora security update(s) the build's own dnf knew and the image lacks: $(ids seen). dnf could not install them, or a later step replaced them: the build log says which")
[ -z "$(ids unrecorded)" ] || fedora_failures+=("Fedora security update(s) ($rule) the image lacks: $(ids unrecorded). It has no record of what its build's dnf knew (/usr/share/fedora-bootc/advisories-at-build.json), so nothing says it could not have had them")
[ -z "$(ids required)" ] || fedora_failures+=("Fedora security update(s) this rebuild was started for and does not contain: $(ids required). Its build's dnf did not have them yet (a mirror behind) or could not install them (the build log says); security.yml starts the rebuild again tomorrow")
for f in "${fedora_failures[@]}"; do
    if [ "${EVENT:-}" = pull_request ]; then
        echo "::warning::$f (fails a push)"
    else
        failures+=("$f")
    fi
done
if [ -n "$(ids newer)" ]; then
    echo "::warning::Fedora security update(s) not in the image that reached Fedora's mirrors after its build read them: $(ids newer). The next build has them; security.yml releases a rebuild of the published images once they are due"
fi

{
    echo "### Scan of \`$image\`"
    echo
    echo "| Check | Found | Fails the build |"
    echo "|---|---|---|"
    echo "| Secrets | $n_secrets | any |"
    echo "| Known-malicious code (CWE-506), in any file | $n_malicious | any |"
    echo "| Vulnerabilities in files the image adds itself | $n_image_crit critical with a fix, $n_image_high high | critical with a fix |"
    echo "| Fedora security updates not in the image | $n_fedora_crit critical, $n_fedora_imp important | $rule, or one a rebuild was started for |"
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
    if [ "$((n_fedora_crit + n_fedora_imp))" != 0 ] || [ -s "$work/gated.txt" ]; then
        echo
        echo "**Fedora security updates not in the image**"
        echo
        echo "| Advisory | Severity | Verdict | Packages |"
        echo "|---|---|---|---|"
        jq -r --rawfile gated "$work/gated.txt" '
            ($gated | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[3]}) | add // {}) as $why
            | {seen: "fails: its build knew it", unrecorded: "fails: no record of the build",
               required: "fails: the rebuild is for it", newer: "warns: newer than the build"} as $text
            | (map(select(.type == "security" and (.severity == "Critical" or .severity == "Important")))
               | group_by(.name) | map({name: .[0].name, severity: .[0].severity, packages: map(.nevra)}))
              + ($gated | split("\n") | map(select(length > 0) | split(" ")
                 | {name: .[0], severity: .[1], packages: (.[2] | split(","))}))
            | unique_by(.name)[]
            | "| \(.name) | \(.severity) | \($text[$why[.name] // ""] // "reported") | \(.packages | join(", ")) |"' "$work/advisories.json"
    fi
    echo
} >> "$summary"

if [ -n "${SARIF:-}" ]; then
    jq -n --rawfile secrets "$work/secrets.tsv" --rawfile vulns "$work/classified.tsv" \
        --slurpfile adv "$work/advisories.json" --rawfile gated "$work/gated.txt" --arg rule "$rule" \
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
