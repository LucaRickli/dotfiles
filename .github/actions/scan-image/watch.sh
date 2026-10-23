#!/usr/bin/env bash
#
# The daily check behind security.yml: which Fedora security updates the
# published images lack, and a rebuild when they lack one they must not.
# Run from the root of the checkout, by security.yml and locally the same
# way (rootless podman, cosign, just, jq, and gh logged in):
#
#   .github/actions/scan-image/watch.sh [--dry-run]
#
# Checked: the sealed image of every entry of `just images` (<name>-uki,
# the tag machines follow; the unsealed one has the same packages), `live`
# (the ISO's system) and the dev container. A tag that does not exist yet
# (an add-on not released yet, a fork before its first release) is skipped.
# Each is verified against keys/cosign.pub before dnf runs in it, the way a
# machine verifies it, and pulled by that digest. One that cannot be checked
# (a registry, mirror or Bodhi down, a missing or bad signature) does not
# keep the others from being checked and rebuilt, and fails the run at the
# end, which is notify.yml's issue until a run gets through.
#
# advisories.sh --due decides: a Critical update the image lacks that has
# been stable in Bodhi for 12 hours, long enough for a build started now to
# have it. Then:
#   - an OS image (an entry of `just images`, live) lacks one: release.yml,
#     started without a version, releases HEAD of main as the next patch
#     level of this week, <yy>.<ww>.<n> (the week's own version when that is
#     still free; the Monday run then finds it released), with the list as
#     its `security` input;
#   - the dev container lacks one: devcontainer.yml, with the same input.
# The input is one line (ADVISORY SEVERITY PACKAGES, separated by ";"), so
# a rebuild can be started from the Run workflow form the same way. The
# scan of every image the rebuild makes requires those updates (REQUIRE in
# advisories.sh): the rebuild contains them or fails. Each opens an issue
# assigned to you when it is done, saying what it fixed and what to run:
# nothing on a machine moves by itself. The release is the Monday one in
# every other respect: build.yml builds, tests, scans and signs every image
# again, and the tags machines follow move last, only if all of that
# worked, so a HEAD whose push build has not finished, or failed, is
# checked the same way and cannot be released broken.
#
# Nothing is started while a run of that workflow is in flight (it releases
# whatever it was started for; the next check looks again). Otherwise one
# run a day at most, because the schedule is daily: a rebuild that fails
# (main broken, a registry down, a mirror behind) is notify.yml's issue and
# its own, and the next day's check starts it again, so a fix waiting on a
# broken main says so every day until main is fixed. One that succeeded
# contains every update it was started for, so none is released twice.
#
# --dry-run checks and reports, and says what it would start; it starts
# nothing.
set -euo pipefail

dry=
[ "${1:-}" != --dry-run ] || dry=1
here=$(cd "$(dirname "$0")" && pwd)
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
registry="ghcr.io/${repo%%/*}"
registry=${registry,,}
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/watch.XXXXXX")
trap 'rm -rf "$work"' EXIT
export GH_REPO="$repo"

images=()
for name in $(just images | jq -r '.[]'); do
    images+=("${registry}/fedora-bootc:${name}-uki")
done
images+=("${registry}/fedora-bootc:live" "${registry}/devcontainer:latest")

# --- What the published images lack -----------------------------------------
: > "$work/os.txt"
: > "$work/dev.txt"
: > "$work/report.md"
checked=0 problems=0
for image in "${images[@]}"; do
    # The digest cosign verified, then that digest pulled: never a tag
    # that might have moved in between, and no local tag changed.
    digest=''
    for attempt in 1 2 3; do
        if cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true "$image" \
               > "$work/verified.json" 2> "$work/verify.err"; then
            digest=$(jq -r 'first(.[].critical.image."docker-manifest-digest")' "$work/verified.json")
            break
        fi
        grep -qi 'manifest.unknown' "$work/verify.err" && break
        [ "$attempt" = 3 ] || sleep 30
    done
    if [ -z "$digest" ]; then
        if grep -qi 'manifest.unknown' "$work/verify.err"; then
            echo "::notice::$image does not exist (yet), skipped"
        else
            sed 's/^/  /' "$work/verify.err" >&2
            echo "::error::$image: no valid signature by keys/cosign.pub, or the registry could not be read"
            problems=$((problems + 1))
        fi
        continue
    fi
    ref="${image%:*}@${digest}"
    pulled=
    if ! podman image exists "$ref"; then
        for attempt in 1 2 3; do
            podman pull --quiet "$ref" > /dev/null && { pulled=1; break; }
            [ "$attempt" = 3 ] || sleep 30
        done
        [ -n "$pulled" ] || { echo "::warning::could not pull $ref, skipped"; problems=$((problems + 1)); continue; }
    fi
    rc=0
    "$here/advisories.sh" --due "$ref" > "$work/missing.txt" || rc=$?
    # Room for the next one on a runner; only what this script pulled.
    [ -z "$pulled" ] || podman rmi --force "$ref" > /dev/null || true
    if [ "$rc" != 0 ]; then
        echo "::warning::could not read Fedora's advisories or Bodhi's dates for $image, skipped"
        problems=$((problems + 1))
        continue
    fi
    checked=$((checked + 1))
    if [ ! -s "$work/missing.txt" ]; then
        echo "$image ($digest): lacks no update that is due"
        continue
    fi
    echo "$image ($digest) lacks:"
    sed 's/^/  /' "$work/missing.txt"
    case $image in
        */devcontainer:*) cat "$work/missing.txt" >> "$work/dev.txt" ;;
        *) cat "$work/missing.txt" >> "$work/os.txt" ;;
    esac
    { echo "\`$image\` lacks:"; echo; sed 's/^/    /' "$work/missing.txt"; echo; } >> "$work/report.md"
done
[ "$checked" != 0 ] || { echo "::error::no published image could be checked"; exit 1; }

# One line per advisory, the packages of every image that lacks it.
merge() {
    awk '{
        if (!($1 in sev)) { sev[$1] = $2; order[++n] = $1 }
        k = split($3, p, ",")
        for (i = 1; i <= k; i++)
            if (!seen[$1, p[i]]++) pkgs[$1] = pkgs[$1] (pkgs[$1] == "" ? "" : ",") p[i]
    } END { for (i = 1; i <= n; i++) print order[i], sev[order[i]], pkgs[order[i]] }' "$1"
}

# --- The rebuilds ------------------------------------------------------------
# start WORKFLOW LIST: dispatch WORKFLOW on main with LIST, one line per
# update, as `security` (one line, ";" between them), unless a run of it is
# in flight
start() {
    local wf=$1 list=$2 busy input
    input=$(paste -sd';' <<<"$list")
    busy=$(gh api "repos/${repo}/actions/workflows/${wf}/runs?per_page=20" \
        --jq '[.workflow_runs[] | select(.status != "completed")] | length')
    if [ "$busy" != 0 ]; then
        echo "$wf: a run is in flight, starting nothing; the next check looks again" | tee -a "$work/decision.md"
        return 0
    fi
    if [ -n "$dry" ]; then
        echo "$wf: would be started on main for $(cut -d' ' -f1 <<<"$list" | paste -sd' ') (dry run)" | tee -a "$work/decision.md"
        echo "  security=$input"
        return 0
    fi
    gh workflow run "$wf" --ref main -f "security=$input"
    echo "$wf: started on main for $(cut -d' ' -f1 <<<"$list" | paste -sd' ')" | tee -a "$work/decision.md"
}

: > "$work/decision.md"
[ ! -s "$work/os.txt" ] || start release.yml "$(merge "$work/os.txt")"
[ ! -s "$work/dev.txt" ] || start devcontainer.yml "$(merge "$work/dev.txt")"
if [ -s "$work/decision.md" ]; then
    {
        echo "### Fedora security updates the published images lack"
        echo
        cat "$work/report.md"
        sed 's/^/- /' "$work/decision.md"
        echo
    } >> "$summary"
else
    echo "no published image lacks a Fedora security update that is due"
fi
[ "$problems" = 0 ] || { echo "::error::$problems published image(s) could not be checked, see above"; exit 1; }
