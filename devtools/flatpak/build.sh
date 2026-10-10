#!/usr/bin/env bash
#
# Build the VS Code Flatpak, then install and test it. Runs INSIDE a
# privileged Fedora container with devtools/ and the scan rules
# (.github/actions/scan-image) under /src and the output going to /out;
# `just flatpak` sets that up, and CI runs the same recipe. Writes:
#
#   /out/repo   the OSTree repo the app is exported to (the test installs it)
#   /out/oci    the same app as an OCI image layout, what CI pushes to ghcr.io
#
# VS Code itself is in neither: it is extra-data, which flatpak downloads from
# Microsoft on each machine and apply_extra unpacks, as Flathub's
# com.visualstudio.code does (Microsoft's license forbids redistributing it).
# The rest is Flathub's Freedesktop Sdk as the runtime (compilers, git, gdb,
# strace inside the sandbox), the Electron BaseApp (zypak) and the tools from
# devtools/tools.txt.
set -euxo pipefail
# libarchive, which writes the OCI layer, crashes on a non-ASCII file name
# under the C locale.
export LANG=C.UTF-8

APP_ID=io.github.lucarickli.Code
# Flathub's Freedesktop branch. The Electron BaseApp must exist for it, which
# lags a new branch by some weeks, so this moves by hand once a year.
RUNTIME=26.08
# renovate: datasource=github-releases depName=microsoft/vscode
VSCODE_VERSION=1.141.0

src=${SRC:-/src}
out=${OUT:-/out}
here=$src/devtools/flatpak

dnf -y install --setopt=install_weak_deps=False \
    flatpak dbus-daemon desktop-file-utils jq unzip xz util-linux
# System-wide, as on a machine: the test below installs the app there too.
flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --system -y --noninteractive flathub \
    "org.freedesktop.Sdk//$RUNTIME" "org.electronjs.Electron2.BaseApp//$RUNTIME"

work=$(mktemp -d /var/tmp/flatpak-build.XXXXXX)
build=$work/build
flatpak build-init --base=org.electronjs.Electron2.BaseApp --base-version="$RUNTIME" \
    "$build" "$APP_ID" org.freedesktop.Sdk org.freedesktop.Sdk "$RUNTIME"
"$src/devtools/install.sh" "$build/files"
# Go's own compiler test suite: not needed to use Go, and the only non-ASCII
# file names in the app.
rm -rf "$build/files/go/test"
# fish behind a wrapper that gives it your dotfiles (devtools/flatpak/fish).
install -Dm755 "$build/files/bin/fish" "$build/files/libexec/fish"
install -Dm755 "$here/fish" "$build/files/bin/fish"
# The language extensions, as .vsix files in /app/share/vscode/vsix; the
# launcher (devtools/flatpak/code) installs them into the profile.
"$src/devtools/install.sh" --list "$src/devtools/extensions.txt" "$build/files"
install -Dm755 "$here/code" "$here/apply_extra" -t "$build/files/bin"
install -Dm755 "$here/host-command" "$build/files/bin/podman"
ln -s podman "$build/files/bin/docker"
install -Dm644 "$here/code.desktop" "$build/files/share/applications/$APP_ID.desktop"
install -Dm644 "$here/code-url-handler.desktop" "$build/files/share/applications/$APP_ID-url-handler.desktop"

# The .deb Renovate pins: the redirect URL Flathub uses too (the file name
# behind it carries a build timestamp), its sha256 from Microsoft's update
# API, its size from the download server. The test below downloads it, which
# proves all three.
url=https://update.code.visualstudio.com/$VSCODE_VERSION/linux-deb-x64/stable
sha=$(curl -fsSL --retry 5 "https://update.code.visualstudio.com/api/versions/$VSCODE_VERSION/linux-deb-x64/stable" | jq -r .sha256hash)
size=$(curl -fsSIL --retry 5 "$url" | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }')
[[ $sha =~ ^[0-9a-f]{64}$ && $size =~ ^[1-9][0-9]*$ ]]

# Flathub's VS Code permissions (devel is ptrace for dlv and strace) without
# its KDE wallet and AppMenu names, plus the host's /tmp, where the Dev
# Containers CLI writes files it hands to the host's podman (the UID-mapping
# Dockerfile). SHELL: the terminal runs fish from /app with your dotfiles,
# whatever the caller's shell is.
flatpak build-finish "$build" --command=code \
    --share=network --share=ipc \
    --socket=wayland --socket=fallback-x11 --socket=pulseaudio --socket=ssh-auth \
    --device=all --allow=devel \
    --filesystem=host --filesystem=/tmp \
    --talk-name=org.freedesktop.Flatpak \
    --talk-name=org.freedesktop.Notifications \
    --talk-name=org.freedesktop.secrets \
    --system-talk-name=org.freedesktop.login1 \
    --env=PATH=/app/bin:/app/go/bin:/app/cargo/bin:/usr/bin \
    --env=RUSTUP_HOME=/app/rustup \
    --env=DENO_NO_UPDATE_CHECK=1 \
    --env=SHELL=/app/bin/fish \
    --env=LD_LIBRARY_PATH=/app/lib \
    --env=XCURSOR_PATH=/run/host/user-share/icons:/run/host/share/icons \
    --extra-data="code.deb:$sha:$size:0:$url"

# The secret scan every published image gets (.github/actions/scan-image), with
# the trivy just installed and the same rules. Everything in /app is someone
# else's release, so vulnerabilities are left to the dev container's scan of
# the same tools. Run in $work, which has no trivy.yaml or .trivyignore:
# trivy reads those from its working directory.
(cd "$work" && "$build/files/bin/trivy" fs --scanners secret --cache-backend memory \
    --secret-config "$src/.github/actions/scan-image/trivy-secret.yaml" \
    --quiet --exit-code 1 "$build/files")

rm -rf "$out/repo" "$out/oci"
flatpak build-export --arch=x86_64 --subject="VS Code $VSCODE_VERSION" "$out/repo" "$build" stable
flatpak build-bundle --oci "$out/repo" "$out/oci" "$APP_ID" stable
rm -rf "$work"

# --- Test: install it as a machine would, run what it ships ------------------
# System-wide, and used by an ordinary account: flatpak shows a user's home
# in the sandbox, but not root's. The install downloads code.deb from
# Microsoft and runs apply_extra, which proves the extra-data above. The
# terminal's shell must be /app's fish (whatever the caller's is) and read
# ~/.config/fish; a first start installs the extensions into the profile
# (devtools/flatpak/code).
flatpak remote-add --system --if-not-exists --no-gpg-verify built "$out/repo"
flatpak install --system -y --noninteractive --reinstall built "$APP_ID"
deploy=$(flatpak info --system --show-location "$APP_ID")
test -s "$deploy/export/share/icons/hicolor/512x512/apps/$APP_ID.png"
test -s "$deploy/export/share/applications/$APP_ID.desktop"
id -u tester >/dev/null 2>&1 || useradd -m tester
runtime=/run/user/$(id -u tester)
install -d -o tester -g tester -m 700 "$runtime"
as_tester() { runuser -u tester -- env HOME=/home/tester XDG_RUNTIME_DIR="$runtime" "$@"; }
run() { as_tester dbus-run-session -- flatpak run "$@"; }
data=/home/tester/.var/app/$APP_ID/data/vscode
bundled=$(awk '!/^#/ && NF { print $1 }' "$src/devtools/extensions.txt")
installed=$(mktemp)
# A first start offline: the bundled extensions, Dev Containers left for later.
run --unshare=network "$APP_ID" --list-extensions >"$installed"
for id in $bundled; do grep -qixF "$id" "$installed"; done
if grep -qxF ms-vscode-remote.remote-containers "$data/extensions-offered"; then exit 1; fi
# A first start online: all of them from the Marketplace, so none pinned
# (VS Code updates them), each recorded once, and a removed one stays removed.
as_tester rm -rf "/home/tester/.var/app/$APP_ID"
test "$(run "$APP_ID" --version | head -1)" = "$VSCODE_VERSION"
run "$APP_ID" --list-extensions >"$installed"
for id in $bundled ms-vscode-remote.remote-containers; do
    grep -qixF "$id" "$installed"
    test "$(grep -cxF "$id" "$data/extensions-offered")" = 1
done
jq -e '[.[] | select(.metadata.pinned == true)] | length == 0' "$data/extensions/extensions.json"
run "$APP_ID" --uninstall-extension golang.go
run "$APP_ID" --list-extensions >"$installed"
if grep -qixF golang.go "$installed"; then exit 1; fi
# shellcheck disable=SC2016  # the sandbox's variables, not this shell's
as_tester sh -c 'mkdir -p ~/.config/fish && echo "set -g devtools_dotfiles yes" >~/.config/fish/config.fish'
# shellcheck disable=SC2016
run --command=bash "$APP_ID" -c 'test "$SHELL" = /app/bin/fish'
run --command=fish "$APP_ID" -c 'set -q devtools_dotfiles'
run --command=bash "$APP_ID" "$src/devtools/test.sh"
# The app is on the host's network (--share=network): a server started in it,
# a dev server in the terminal, is reachable from outside on localhost.
as_tester dbus-run-session -- flatpak run --command=python3 "$APP_ID" \
    -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &
for _ in $(seq 30); do curl -fsS -o /dev/null http://127.0.0.1:8765/ && break; sleep 1; done
curl -fsS -o /dev/null http://127.0.0.1:8765/
as_tester flatpak kill "$APP_ID"
