#!/usr/bin/env bash
#
# Assign every open code scanning alert that nobody is assigned to, to one
# user. An assignment is what GitHub emails a user about; nothing else that
# happens to an alert is, and no workflow trigger exists for a new one. So
# alerts.yml runs this after every workflow that uploads scan results
# (build, release, devcontainer) and once a day, for the alerts CodeQL's
# default setup uploads on its own schedule. An alert a later upload reopens
# is caught here whether or not GitHub kept its assignee. From anywhere,
# with gh logged in:
#
#   .github/actions/scan-image/assign-alerts.sh [--dry-run] [USER]
#
# USER defaults to the owner of the repository (GH_REPO, or the checkout's
# origin). The token needs "code scanning alerts: write" (security-events:
# write for GITHUB_TOKEN), and USER needs write access to the repository,
# which an owner that is an organisation does not have: name a member then.
# --dry-run lists what would be assigned and changes nothing.
set -euo pipefail

dry=
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
repo=${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
user=${1:-${repo%%/*}}
alerts=$(mktemp)
trap 'rm -f "$alerts"' EXIT

# Every open alert without an assignee, whatever uploaded it and whichever
# branch or tag its newest instance is on.
gh api --paginate "repos/${repo}/code-scanning/alerts?state=open&assignees=none&per_page=100" \
    --jq '.[] | [.number, .rule.id, (.most_recent_instance.category // "-"), .html_url] | @tsv' \
    > "$alerts"
n=$(wc -l < "$alerts")
if [ "$n" = 0 ]; then
    echo "no open alert without an assignee"
    exit 0
fi
while IFS=$'\t' read -r number rule category url; do
    echo "#${number} ${rule} (${category}): ${url}"
    [ -z "$dry" ] || continue
    # The endpoint wants the state along; open is what these are.
    jq -n --arg user "$user" '{state: "open", assignees: [$user]}' \
        | gh api --silent -X PATCH "repos/${repo}/code-scanning/alerts/${number}" --input -
done < "$alerts"
echo "${n} alert(s) ${dry:+would be }assigned to ${user}"
