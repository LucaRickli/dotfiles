#!/usr/bin/env bash
#
# The Fedora security updates a local image lacks, and which of them count.
# dnf inside the image, against Fedora's updates repository as it is now
# (which carries an update from the day it goes stable), says what the image
# lacks; one of two rules says which of those count:
#
#   advisories.sh IMAGE           the push gate (scan.sh): each one of a
#                                 gated severity, one per line, ADVISORY
#                                 SEVERITY PACKAGES WHY; all but WHY "newer"
#                                 count
#   advisories.sh --due IMAGE     the daily check of the published images
#                                 (watch.sh): the ones a build started now
#                                 has, one per line: ADVISORY SEVERITY PACKAGES
#   advisories.sh [--due] --rule  the rule in words, for summaries
#   JSON=FILE advisories.sh ...   also dnf's full list (every severity), for
#                                 scan.sh's summary and sarif.jq
#
# The push gate needs no clock. Every build applies Fedora's updates and
# then records, from the same dnf metadata, every security advisory for the
# packages it installed ($record; image/base.Containerfile,
# devtools/Containerfile, installer/prepare-live.sh). A lacking update in
# that record is one the build's dnf knew and the image does not have (dnf
# could not install it, or a later step replaced the package): WHY "seen".
# One that is not in it reached Fedora's mirrors after the build read them
# ("newer"): it does not count, the next build has it, and watch.sh starts
# one when it is due. An image without a record counts every lacking update
# ("unrecorded"): nothing says it could not have had them.
#
# REQUIRE, the `security` input of a rebuild watch.sh started (ADVISORY
# SEVERITY PACKAGES, one per line or separated by ";"), adds WHY "required":
# a listed update for a package the image has that its build did not record
# or that the image lacks. So the rebuild contains the updates it was started
# for, or fails: its issue says nothing false, and the next day's check does
# not start another one for an update it already shipped.
#
# The daily check has no record to go by: a published image was built days
# ago. It asks Bodhi when each lacking update went stable and counts one that
# has been for 12 hours (SLACK_HOURS), the time an update takes to reach the
# mirrors a build reads. dnf's `buildtime` is no such time: on an update's
# first stable day it still holds when it went to testing. A mirror slower
# than that makes the rebuild fail on REQUIRE, and the next day's check
# starts it again.
#
# Exit 0 whether or not anything counts, 1 when dnf or Bodhi could not
# answer or REQUIRE is malformed.
set -euo pipefail

# The one place to tune how much a missing Fedora update weighs. Critical:
# about one Critical advisory a month touches these images, an Important
# one several a week, and each is a release of every image and an issue for
# you.
gate=${GATE:-Critical}
slack=${SLACK_HOURS:-12}
# Where the builds put their record: dnf's JSON, every security advisory of
# the updates repository for the packages installed at the time.
record=/usr/share/fedora-bootc/advisories-at-build.json

due=
if [ "${1:-}" = --due ]; then due=1; shift; fi
if [ "${1:-}" = --rule ]; then
    if [ -n "$due" ]; then
        echo "$gate, stable in Bodhi for ${slack} h"
    else
        echo "$gate, known to the build's dnf"
    fi
    exit 0
fi
image=${1:?usage: advisories.sh [--due] <local image> | [--due] --rule}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/advisories.XXXXXX")
trap 'rm -rf "$work"' EXIT
json=${JSON:-$work/dnf.json}
podman image exists "$image" || { echo "no local image $image" >&2; exit 1; }

# retry WHAT COMMAND...: three attempts, 30 s apart, like every other
# download in these scripts
retry() {
    local what=$1 attempt
    shift
    for attempt in 1 2 3; do
        "$@" && return 0
        [ "$attempt" = 3 ] || { echo "$what failed (attempt $attempt), retrying in 30s" >&2; sleep 30; }
    done
    echo "could not read $what" >&2
    return 1
}

# The updates repo only: it carries Fedora's advisories, and a third-party
# repository being down must not fail the check. One row per advisory and
# package the image has an older version of.
lacking() {
    podman run --rm --pull=never --entrypoint /usr/bin/dnf "$image" \
        -q advisory list --security --repo=updates --json > "$json"
}
retry "Fedora's advisories for $image" lacking || exit 1
# ADVISORY SEVERITY PACKAGES, one per lacking advisory of a gated severity
jq -r --arg gate "$gate" '
    ($gate | split(" ") | map(select(length > 0))) as $gated
    | map(select(.type == "security" and (.severity | IN($gated[]))))
    | group_by(.name)[]
    | "\(.[0].name) \(.[0].severity) \(map(.nevra) | join(","))"' "$json" > "$work/gated.txt"

if [ -n "$due" ]; then
    # Bodhi's date_stable, UTC as "YYYY-MM-DD HH:MM:SS"
    # shellcheck disable=SC2329  # called through retry
    stable() {
        curl -fsS --max-time 60 "https://bodhi.fedoraproject.org/updates/${id}" \
            | jq -er '.update.date_stable' > "$work/stable"
    }
    now=$(date -u +%s)
    while read -r id severity packages; do
        retry "Bodhi's stable date of $id" stable || exit 1
        since=$(date -u -d "$(cat "$work/stable") UTC" +%s)
        if [ "$((now - since))" -ge "$((slack * 3600))" ]; then
            echo "$id $severity $packages"
        else
            echo "$id: stable since $(cat "$work/stable") UTC, due ${slack} h after that" >&2
        fi
    done < "$work/gated.txt"
    exit 0
fi

# The record, or the word "none" when the image has none.
podman run --rm --pull=never --network=none --entrypoint /usr/bin/bash "$image" \
    -c '[ -e "$1" ] || { echo none; exit 0; }; cat "$1"' _ "$record" > "$work/record"
if [ "$(cat "$work/record")" = none ]; then
    echo '{"recorded": false, "names": []}' > "$work/known.json"
else
    jq '{recorded: true, names: (map(.name) | unique)}' "$work/record" > "$work/known.json"
fi

# REQUIRE, one update per line, checked before any of it reaches a command,
# then which of its packages the image has.
tr ';' '\n' <<<"${REQUIRE:-}" | awk 'NF { print $1, $2, $3 }' > "$work/require.txt"
while read -r id severity packages; do
    [[ $id =~ ^FEDORA-[0-9]{4}-[0-9a-f]+$ && $severity =~ ^[A-Za-z]+$ &&
       $packages =~ ^[A-Za-z0-9._+~^:-]+(,[A-Za-z0-9._+~^:-]+)*$ ]] ||
        { echo "REQUIRE is not ADVISORY SEVERITY PACKAGES: $id $severity $packages" >&2; exit 1; }
done < "$work/require.txt"
: > "$work/installed.txt"
if [ -s "$work/require.txt" ]; then
    # name-[epoch:]version-release.arch to name
    names=$(cut -d' ' -f3 "$work/require.txt" | tr ',' '\n' \
        | sed -E 's/\.[^.]+$//; s/-[^-]+-[^-]+$//' | sort -u)
    # shellcheck disable=SC2086  # one argument per name, on purpose
    podman run --rm --pull=never --network=none --entrypoint /usr/bin/rpm "$image" \
        -q --qf '%{NAME}\n' $names > "$work/installed.txt" || true
fi

# One line per update, with the first reason that applies: the ones that
# count before the ones that do not.
jq -rn --rawfile gated "$work/gated.txt" --rawfile require "$work/require.txt" \
    --rawfile installed "$work/installed.txt" --slurpfile known "$work/known.json" \
    --slurpfile dnf "$json" '
    def lines: split("\n") | map(select(length > 0) | split(" "));
    def name: sub("\\.[^.]+$"; "") | sub("-[^-]+-[^-]+$"; "");
    $known[0] as $k
    | ($installed | split("\n") | map(select(length > 0))) as $have
    | ($dnf[0] | map(.name) | unique) as $lacking
    | ($gated | lines
       | map(. + [if $k.recorded | not then "unrecorded"
                  elif .[0] | IN($k.names[]) then "seen"
                  else "newer" end])) as $gated
    | [ ($gated[] | select(.[3] != "newer")),
        ($require | lines[]
         | select(.[2] | split(",") | any(name | IN($have[])))
         | select((.[0] | IN($lacking[])) or (.[0] | IN($k.names[]) | not))
         | . + ["required"]),
        ($gated[] | select(.[3] == "newer")) ]
    | unique_by(.[0])[] | join(" ")'
