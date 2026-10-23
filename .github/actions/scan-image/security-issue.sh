#!/usr/bin/env bash
#
# Tell the owner how a rebuild security.yml started went (watch.sh), as an
# issue assigned to them: the last job of release.yml and of devcontainer.yml
# when their `security` input is set. There and not in security.yml,
# because the run that built the images knows the outcome and the version for
# certain, with nothing left waiting two hours for it.
#
# Done: an issue that says what the rebuild fixed and what to run, because
# nothing on a machine moves by itself; it closes an open "failed" issue of
# the same kind. Failed: one "failed" issue per kind, commented on again by
# every later failure (security.yml starts the rebuild again each day), as
# notify.yml does for any failed run. That one is a separate issue: it says
# which fix waits.
#
# From the workflow's environment: WHAT (release or devcontainer), OUTCOME
# (the result of its last job: success, or anything else), SECURITY (the
# `security` input: ADVISORY SEVERITY PACKAGES, one per line or separated by
# ";"), VERSION (release), RUN_URL, OWNER, GH_REPO and GH_TOKEN (issues:
# write, contents: read).
set -euo pipefail

: "${WHAT:?}" "${OUTCOME:?}" "${SECURITY:?}" "${RUN_URL:?}" "${OWNER:?}" "${GH_REPO:?}"
label=security-release
list=$(tr ';' '\n' <<<"$SECURITY" | awk 'NF { print $1, $2, $3 }')
ids=$(cut -d' ' -f1 <<<"$list" | paste -sd' ')
updates=$(awk '{ print "    " $0 }' <<<"$list")
case $WHAT in
    release) kind="Security release" ;;
    devcontainer) kind="Dev container security rebuild" ;;
    *) echo "WHAT is release or devcontainer, not $WHAT" >&2; exit 1 ;;
esac

gh label create "$label" --color B60205 \
    --description "A rebuild security.yml started for Fedora security updates" --force >/dev/null
failed=$(gh issue list --state open --label "$label" --limit 100 --json number,title \
    | jq -r --arg t "$kind failed" '[.[] | select(.title == $t)][0].number // empty')

# Assigning is what sends the notification. An owner that is an
# organisation cannot be assigned, so fall back to a plain issue.
open_issue() {
    gh issue create --title "$1" --label "$label" --assignee "$OWNER" --body "$2" ||
        gh issue create --title "$1" --label "$label" --body "$2"
}

server=${GITHUB_SERVER_URL:-https://github.com}
if [ "$OUTCOME" != success ]; then
    # What a failed run left behind, which differs by where it stopped.
    if [ "$WHAT" = release ]; then
        : "${VERSION:?}"
        if gh release view "$VERSION" > /dev/null 2>&1; then
            left="The tags machines follow did not move, but the GitHub release ${VERSION} and its tag exist (${server}/${GH_REPO}/releases/tag/${VERSION}): it failed after publishing them. Delete both (gh release delete ${VERSION} --cleanup-tag) or re-run the run's failed jobs; the next rebuild is a new patch level beside it."
        else
            left="The tags machines follow did not move, and no release ${VERSION} was published."
        fi
    else
        left="If it failed after the push, devcontainer:latest is unsigned until a rebuild gets through, and podman on this OS refuses to pull it; a machine that pulled before keeps the one it has."
    fi
    if [ -n "$failed" ]; then
        gh issue comment "$failed" --body "Failed again, for ${ids}: ${RUN_URL}

${left}"
    else
        open_issue "$kind failed" "security.yml started a rebuild for Fedora security updates the published images lack, and it did not succeed: ${RUN_URL}

${updates}

${left}

security.yml starts it again every day while the images lack them; notify.yml's issue for the workflow tracks the failure itself. This issue closes when a rebuild gets through."
    fi
    exit 0
fi

if [ "$WHAT" = release ]; then
    : "${VERSION:?}"
    # What else the release carries: the commits since the one before it.
    previous=$(gh release list --exclude-drafts --limit 20 --json tagName \
        | jq -r --arg v "$VERSION" '[.[].tagName | select(. != $v)][0] // empty')
    changes="(no earlier release)"
    if [ -n "$previous" ]; then
        changes=$(gh api "repos/${GH_REPO}/compare/${previous}...${VERSION}" \
            --jq '.commits[] | "    \(.sha[0:7]) \(.commit.message | split("\n")[0])"' | tail -n 30)
        changes="Since ${previous} (${server}/${GH_REPO}/compare/${previous}...${VERSION}):

${changes:-    nothing else}"
    fi
    title="$kind ${VERSION}: ${ids}"
    body="${VERSION} is released (${server}/${GH_REPO}/releases/tag/${VERSION}) with these Fedora security updates, which the published images lacked:

${updates}

Nothing on a machine moves by itself. On each one:

    sudo bootc upgrade --apply    # stage ${VERSION} and reboot into it

${changes}

Close this once your machines run it."
else
    registry="ghcr.io/${GH_REPO%%/*}"
    title="$kind: ${ids}"
    body="The dev container is rebuilt (${RUN_URL}) with these Fedora security updates, which the published one lacked:

${updates}

Nothing on a machine moves by itself. On each one:

    podman pull ${registry,,}/devcontainer:latest

then recreate the toolbox, or rebuild the Dev Container. Close this once your machines have it."
fi
open_issue "$title" "$body"
[ -z "$failed" ] || gh issue close "$failed" --comment "Done: ${RUN_URL}"
