#!/usr/bin/env bash
#
# What install.sh cannot check: that the pinned downloads in tools.txt and
# extensions.txt are the files upstream's own release process made.
# install.sh compares a download with the sha256 on the line or in a
# checksum file from the same release, and whoever can replace a release
# file can usually replace that checksum file too. Here each pin is checked,
# at its version, against what upstream publishes beyond that: a cosign
# signature by the release workflow's identity, GitHub's build provenance
# or release attestation (immutable releases), a GPG or minisign signature
# by a pinned key, SLSA provenance, and for an extension the publisher's own
# copy of the file. CI runs it on every pull request that changes a pin
# (ci.yml, `pins`).
#
#   devtools/verify-pins.sh [FILE...]     (default: tools.txt extensions.txt)
#
# The table below says how, per name. A line whose name is not in it fails,
# so a new tool needs a decision: its check, or `none` with the reason.
# Nothing here catches a malicious release made by upstream's real release
# pipeline (trivy 0.69.4 was signed by trivy's release workflow); Renovate's
# 3-day minimumReleaseAge is what keeps those out.
#
# Needs bash, curl, sha256sum, unzip, jq, gpg, cosign, gh (logged in, or
# GH_TOKEN), minisign and slsa-verifier.
set -euo pipefail

here=$(dirname "$0")

# How each name is checked, one check per row (a name may have several):
#
#   NAME  METHOD  ARGUMENTS
#
# In ARGUMENTS {v} is the version verbatim, {n} without a leading "v",
# {asset} and {sum} the line's asset and checksum URLs. SUBJECT is the file
# a signature is over: asset (the download), sums (the line's checksum file)
# or a URL. A SUBJECT other than the asset must list the asset's sha256 next
# to its name, which ties the download to the signature.
#
#   attestation REPO WORKFLOW [REF]   GitHub build provenance (gh attestation
#                                     verify) by REPO's WORKFLOW, run on REF
#                                     (default refs/tags/{v})
#   release REPO                      GitHub's release attestation: the file
#                                     is part of REPO's immutable release {v}
#   cosign SUBJECT BUNDLE IDENTITY [ISSUER]
#                                     cosign verify-blob of a Sigstore
#                                     bundle, or of SIG,CERT (two URLs); the
#                                     issuer defaults to GitHub Actions'
#   gpg SUBJECT SIG KEYS FINGERPRINTS a detached signature by one of the
#                                     primary keys FINGERPRINTS (comma list),
#                                     imported from the URL KEYS
#   minisign SUBJECT KEY              SUBJECT's URL plus .minisig, by KEY. A
#                                     checksum written URL,minisign:KEY in
#                                     the list gets this check without a row
#   slsa SUBJECT PROVENANCE SOURCE    slsa-verifier: built from SOURCE at {v}
#   github-vsix REPO TAG FILE         the .vsix is FILE of REPO's release TAG
#   marketplace-vsix PUBLISHER NAME   the .vsix is the Visual Studio
#                                     Marketplace's file of that version
#   openvsx-vsix NAMESPACE/NAME/TARGET
#                                     the .vsix is Open VSX's file of the
#                                     version its package.json names
#   none WHY                          upstream publishes nothing to check
#                                     beyond the sha256
#
# go: lines need no row: go install checks every module against
# sum.golang.org.
table=$(cat <<'EOF'
kubectl                 cosign       asset {asset}.sig,{asset}.cert krel-staging@k8s-releng-prod.iam.gserviceaccount.com https://accounts.google.com
kubelogin               release      int128/kubelogin
kubectl-radar           none         a checksums.txt in the release, nothing else
# The tarball is get.helm.sh's, its signature on the GitHub release. The
# keys: the release managers who signed helm's last 30 releases (Scott
# Rigby, Matt Farina, George Jenkins, Robert Sirchia); a release by anyone
# else fails until they are added here.
helm                    gpg          asset https://github.com/helm/helm/releases/download/{v}/helm-{v}-linux-amd64.tar.gz.asc https://raw.githubusercontent.com/helm/helm/{v}/KEYS 208DD36ED5BB3745A16743A4C7C6FBB5B91C1155,672C657BE06B4B30969C4A57461449C25E36B98E,BF888333D96A1C18E2682AAED79D67C9EC016739,7FEC81FACC7FFB2A010ADD13C2D40F4D8196E874
helmfile                attestation  helmfile/helmfile .github/workflows/releaser.yaml
flux                    cosign       sums {sum}.sig,{sum}.pem https://github.com/fluxcd/flux2/.github/workflows/release.yaml@refs/tags/{v}
talosctl                cosign       asset {asset}.bundle https://github.com/siderolabs/talos/.github/workflows/ci.yaml@refs/tags/{v}
talosctl                release      siderolabs/talos
talhelper               none         a checksums.txt in the release, nothing else
go-containerregistry    slsa         asset https://github.com/google/go-containerregistry/releases/download/{v}/multiple.intoto.jsonl github.com/google/go-containerregistry
trivy                   cosign       asset {asset}.sigstore.json https://github.com/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/{v}
trivy                   attestation  aquasecurity/trivy .github/workflows/reusable-release.yaml
certinfo                none         a checksums.txt in the release, nothing else
sops                    cosign       sums https://github.com/getsops/sops/releases/download/{v}/sops-{v}.checksums.sigstore.json https://github.com/getsops/sops/.github/workflows/release.yml@refs/tags/{v}
cosign                  cosign       asset {asset}.sigstore.json keyless@projectsigstore.iam.gserviceaccount.com https://accounts.google.com
bcvk                    release      bootc-dev/bcvk
# Google's Linux package key (fingerprint as on google.com/linuxrepositories).
go                      gpg          asset {asset}.asc https://dl.google.com/dl/linux/linux_signing_key.pub EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796
golangci-lint           attestation  golangci/golangci-lint .github/workflows/release.yml
protoc                  none         no checksum, signature or attestation for the zip (pinned sha256)
# buf's key as on buf.build/docs/cli/installation.
buf                     minisign     sums RWQ/i9xseZwBVE7pEniCNjlNOeeyp4BQgdZDLQcAohxEAH5Uj5DEKjv6
deno                    release      denoland/deno
rustup                  none         a .sha256 from the same host, nothing else
# The channel manifest holds the sha256 of every component rustup installs
# and is signed with the Rust release key (as on keybase.io/rust); rustup
# itself does not check that signature.
rust                    gpg          https://static.rust-lang.org/dist/channel-rust-{v}.toml https://static.rust-lang.org/dist/channel-rust-{v}.toml.asc https://static.rust-lang.org/rust-key.gpg.ascii 108F66205EAEB0AAA8DD5E1C85AB96E6FA1BE5FE
fish                    none         no checksum, signature or attestation for the binary tarball (pinned sha256)
mise                    attestation  jdx/mise .github/workflows/release.yml
mise                    release      jdx/mise
ripgrep                 none         a .sha256 in the release, nothing else
fd                      attestation  sharkdp/fd .github/workflows/CICD.yml
just                    none         a SHA256SUMS in the release, nothing else
# gh is built from the trunk branch, so its provenance names no tag; the
# release attestation ties the file to the tag.
gh                      attestation  cli/cli .github/workflows/deployment.yml refs/heads/trunk
gh                      release      cli/cli
yq                      cosign       https://github.com/mikefarah/yq/releases/download/{v}/checksums https://github.com/mikefarah/yq/releases/download/{v}/checksums.bundle https://github.com/mikefarah/yq/.github/workflows/release.yml@refs/tags/{v}
yq                      release      mikefarah/yq
shellcheck              none         no checksum, signature or attestation (pinned sha256)
actionlint              attestation  rhysd/actionlint .github/workflows/release.yaml
host-spawn              none         no checksum, signature or attestation (pinned sha256)

# The extensions: Open VSX's file against the publisher's own.
golang.go               github-vsix  golang/vscode-go v{v} go-{v}.vsix
denoland.vscode-deno    github-vsix  denoland/vscode_deno {v} vscode-deno.vsix
bufbuild.vscode-buf     marketplace-vsix bufbuild vscode-buf
# From the GitHub release (pinned sha256), against Open VSX's copy.
rust-lang.rust-analyzer openvsx-vsix rust-lang/rust-analyzer/linux-x64
EOF
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() { curl -fsSL --retry 5 --retry-all-errors -o "$2" "$1"; }

# GitHub's attestation API fails with a 503 at times.
retry() {
    local i
    for i in 1 2 3; do
        "$@" && return 0
        [ "$i" = 3 ] || sleep 10
    done
    return 1
}

# As in install.sh: the sha256 for file $1 from the checksum file on stdin.
pick() {
    local h f
    while read -r h f _ || [ -n "$h" ]; do
        f=${f#\*} f=${f#./}
        if [[ $h =~ ^[0-9a-f]{64}$ ]] && { [ -z "$f" ] || [ "$f" = "$1" ]; }; then
            echo "$h"
            return 0
        fi
    done
    return 1
}

# The file a signature is over, into $s (and its URL into $surl): the
# download, the checksum file, or a URL. One other than the download has to
# list the download's sha256 next to its name.
subject() {
    case $1 in
    asset) s=$f surl=$asset ;;
    sums)
        [ -n "$sums" ] || { echo "the line has no checksum file"; return 1; }
        s=$d/sums surl=$sums
        [ -f "$s" ] || fetch "$surl" "$s"
        ;;
    https://*)
        s=$d/subject-${1##*/} surl=$1
        fetch "$surl" "$s"
        ;;
    *) echo "unknown subject $1"; return 1 ;;
    esac
    if [ -n "$f" ] && [ "$s" != "$f" ] && ! grep -F -- "${f##*/}" "$s" | grep -qF -- "$sha"; then
        echo "${surl##*/} does not list ${f##*/} with sha256 $sha"
        return 1
    fi
}

check_attestation() {
    local ref=${3:-refs/tags/$ver}
    retry gh attestation verify "$f" --repo "$1" --signer-workflow "$1/$2" \
        --source-ref "$ref" --deny-self-hosted-runners
}

check_release() {
    retry gh release verify-asset "$ver" "$f" -R "$1"
}

check_cosign() {
    local sig
    subject "$1" || return 1
    case $2 in
    *,*)
        fetch "${2%%,*}" "$d/sig" && fetch "${2#*,}" "$d/cert" || return 1
        sig=(--signature "$d/sig" --certificate "$d/cert")
        ;;
    *)
        fetch "$2" "$d/bundle" || return 1
        sig=(--bundle "$d/bundle")
        ;;
    esac
    cosign verify-blob "${sig[@]}" --certificate-identity "$3" \
        --certificate-oidc-issuer "${4:-https://token.actions.githubusercontent.com}" "$s"
}

# Only VALIDSIG counts, and only by a pinned primary key: gpg's exit status
# alone accepts any key that happens to be in the keyring.
check_gpg() {
    local home signer ok=1
    subject "$1" || return 1
    home=$(mktemp -d -p "$work")
    fetch "$2" "$d/sig.asc" && fetch "$3" "$d/keys" || return 1
    GNUPGHOME=$home gpg --batch --quiet --import "$d/keys" 2>/dev/null
    for signer in $(GNUPGHOME=$home gpg --batch --status-fd 1 --verify "$d/sig.asc" "$s" 2>/dev/null |
        awk '$2 == "VALIDSIG" { print $NF }'); do
        if [[ ,$4, == *",$signer,"* ]]; then ok=0; else echo "signed by $signer, not a pinned key"; fi
    done
    GNUPGHOME=$home gpgconf --kill all 2>/dev/null || true
    [ "$ok" = 0 ] || echo "no valid signature by a pinned key"
    return "$ok"
}

check_minisign() {
    subject "$1" || return 1
    fetch "$surl.minisig" "$d/minisig" && minisign -Vm "$s" -x "$d/minisig" -P "$2"
}

check_slsa() {
    subject "$1" || return 1
    fetch "$2" "$d/provenance" &&
        slsa-verifier verify-artifact "$s" --provenance-path "$d/provenance" --source-uri "$3" --source-tag "$ver"
}

same() {
    [ "$1" = "$sha" ] || { echo "$2 is sha256 ${1:-(none)}, the pin is $sha"; return 1; }
}

check_github-vsix() {
    local digest
    digest=$(retry gh api "repos/$1/releases/tags/$2" --jq ".assets[] | select(.name == \"$3\") | .digest") &&
        same "${digest#sha256:}" "$3 of $1 $2"
}

check_marketplace-vsix() {
    curl -fsSL --compressed --retry 5 --retry-all-errors -o "$d/marketplace.vsix" \
        "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$1/vsextensions/$2/$ver/vspackage" &&
        same "$(sha256sum "$d/marketplace.vsix" | cut -d' ' -f1)" "the Marketplace's $1.$2 $ver"
}

check_openvsx-vsix() {
    local ns=${1%%/*} rest=${1#*/} v
    local name=${rest%%/*} target=${rest#*/}
    v=$(unzip -p "$f" extension/package.json | jq -r .version)
    fetch "https://open-vsx.org/api/$1/$v/file/$ns.$name-$v@$target.sha256" "$d/openvsx" &&
        same "$(pick "" <"$d/openvsx")" "Open VSX's $ns.$name $v ($target)"
}

# {v}, {n}, {asset} and {sum} in $1, for the line at hand.
sub() {
    local s=${1//\{v\}/$ver}
    s=${s//\{n\}/$n} s=${s//\{asset\}/$asset}
    printf '%s' "${s//\{sum\}/$sums}"
}

failed=() unchecked=() report=()
lists=("$@")
[ $# -gt 0 ] || lists=("$here/tools.txt" "$here/extensions.txt")
for list in "${lists[@]}"; do
    # fd 3: nothing in the loop body can read the list by accident.
    while read -r name ver asset sum _ <&3; do
        case $name in '' | '#'*) continue ;; esac
        n=${ver#v} sums=
        asset=$(sub "$asset") sum=$(sub "$sum")
        key=
        if [[ $sum == *,minisign:* ]]; then key=${sum#*,minisign:} sum=${sum%%,*}; fi
        case $sum in
        http*) sums=$sum ;;
        .*) sums=$asset$sum ;;
        *) sums= ;;
        esac
        rows=$(awk -v n="$name" '$1 == n { $1 = ""; print substr($0, 2) }' <<<"$table")
        [ -z "$key" ] || rows+=$'\n'"minisign sums $key"
        rows=$(sed '/^$/d' <<<"$rows")
        echo "$name $ver"

        if [[ $asset == go:* ]]; then
            echo "  ok    go install checks sum.golang.org"
            report+=("| $name | $ver | sum.golang.org (go install) |")
            continue
        fi
        if [ -z "$rows" ]; then
            echo "  FAIL  not in verify-pins.sh's table: add its check, or none and why" >&2
            failed+=("$name") report+=("| $name | $ver | **failed** |")
            continue
        fi
        if [[ $rows == none* ]]; then
            echo "  --    sha256 only: ${rows#none }"
            unchecked+=("$name")
            report+=("| $name | $ver | sha256 only: ${rows#none } |")
            continue
        fi

        d=$work/$name f='' sha=''
        mkdir -p "$d"
        # The bytes install.sh would install, checked the way it checks them.
        if [[ $asset == https://* ]]; then
            f=$d/${asset##*/}
            if ! fetch "$asset" "$f"; then
                echo "  FAIL  cannot download $asset" >&2
                failed+=("$name") report+=("| $name | $ver | **failed** |")
                rm -rf "$d"
                continue
            fi
            sha=$(sha256sum "$f" | cut -d' ' -f1)
            want=
            case $sum in
            sha256:*) want=${sum#sha256:} ;;
            *) [ -z "$sums" ] || { fetch "$sums" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums"); } || want= ;;
            esac
            if [ "$want" != "$sha" ]; then
                echo "  FAIL  ${f##*/} is sha256 $sha, the line or its checksum file says ${want:-nothing}" >&2
                failed+=("$name") report+=("| $name | $ver | **failed** |")
                rm -rf "$d"
                continue
            fi
        fi

        ok=1 how=()
        while read -r method args; do
            # shellcheck disable=SC2046  # the arguments are words
            set -f && set -- $(sub "$args") && set +f
            if out=$("check_$method" "$@" 2>&1); then
                echo "  ok    $method $*"
            else
                echo "  FAIL  $method $*" >&2
                tail -n 15 <<<"$out" | sed 's/^/        /' >&2
                ok=0
            fi
            how+=("$method")
        done <<<"$rows"
        if [ "$ok" = 1 ]; then
            report+=("| $name | $ver | ${how[*]} |")
        else
            failed+=("$name") report+=("| $name | $ver | **failed** |")
        fi
        rm -rf "$d"
    done 3<"$list"
done

echo
echo "sha256 only (upstream publishes nothing else): ${unchecked[*]:-none}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "| pin | version | checked by |"
        echo "|---|---|---|"
        printf '%s\n' "${report[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
fi
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${failed[*]}" >&2
    exit 1
fi
echo "all pins check out"
