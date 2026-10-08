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
# Claude Code, under Anthropic's terms, is extra-data the same way. The rest
# is Flathub's Freedesktop Sdk as the runtime (compilers, git, gdb, strace
# inside the sandbox), the Electron BaseApp (zypak) and the tools from
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
VSCODE_VERSION=1.140.0
# Anthropic's stable channel (renovate.json follows its npm dist-tag); the
# dev container's pin (devtools/Containerfile) moves with it.
# renovate: datasource=npm depName=@anthropic-ai/claude-code
CLAUDE_VERSION=2.1.285

src=${SRC:-/src}
out=${OUT:-/out}
here=$src/devtools/flatpak

dnf -y install --setopt=install_weak_deps=False \
    flatpak dbus-daemon desktop-file-utils gnupg2 jq openssl unzip xz util-linux
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
# mise's settings, and the Go and Deno above as its installs
# (devtools/mise-system.sh), for /app; build-finish names the dirs.
"$src/devtools/mise-system.sh" "$build/files" "$build/files/etc/mise" /app
# fish behind a wrapper that gives it your dotfiles (devtools/flatpak/fish),
# bcvk behind one that runs it on the host (devtools/flatpak/bcvk).
install -Dm755 "$build/files/bin/fish" "$build/files/libexec/fish"
install -Dm755 "$here/fish" "$build/files/bin/fish"
install -Dm755 "$build/files/bin/bcvk" "$build/files/libexec/bcvk"
install -Dm755 "$here/bcvk" "$build/files/bin/bcvk"
# The language extensions, as .vsix files in /app/share/vscode/vsix; the
# launcher (devtools/flatpak/code) installs them into the profile.
"$src/devtools/install.sh" --list "$src/devtools/extensions.txt" "$build/files"
install -Dm755 "$here/code" "$here/claude" "$here/claude-sandboxed" "$here/apply_extra" -t "$build/files/bin"
# The host's commands the app uses (devtools/flatpak/host-command).
install -Dm755 "$here/host-command" -t "$build/files/libexec"
for c in podman docker qemu-img qemu-system-x86_64; do
    ln -s ../libexec/host-command "$build/files/bin/$c"
done
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
# Claude Code's zstd file (a third of the size; apply_extra unpacks it): URL,
# sha256 and size from the manifest Anthropic signs for the release, checked
# against its key (devtools/claude-code.sh). The test downloads it too.
claude=$("$src/devtools/claude-code.sh" --zst "$CLAUDE_VERSION")
read -r claude_url claude_sha claude_size <<<"$claude"

# A sandbox, with host access an opt-in (docs/devtools.md, Sandbox). Granted:
# - the network (Marketplace, git, downloads, dev servers on the host's
#   localhost), the Wayland display (X11 only where there is none), the GPU
#   (dri), and ptrace and perf for dlv, gdb and strace (devel);
# - ssh-auth: git over SSH signs with the session's agent and never reads a
#   key; ~/.ssh/known_hosts and config come as single files, read-only;
# - ~/Developer, the projects, read-write (made if missing), and your fish
#   and git configuration, read-only;
# - ~/go, ~/.cargo, ~/.deno and ~/.vscode, kept in the app's own directory
#   (--persist; the rest of the home in here is a tmpfs, new at each start):
#   what `go install` and the like build, the module and crate caches, VS
#   Code's argv.json;
# - Notifications, for the toasts. libnotify would use the portal, but which
#   backend serves it on labwc, wayfire and river is untested, and the name
#   only lets the app post notifications that look like another's.
# Not granted, each a way out or more than VS Code needs:
# - host. Since flatpak 1.17 it brings the host's whole / at /run/host/root
#   as well: the unfiltered session and system buses, niri's IPC socket,
#   podman's socket dir, the host's /proc. That makes every other limit here
#   moot, so leaving it out is the largest reduction of all.
# - org.freedesktop.Flatpak: any command on the host, through host-spawn. One
#   override grants it, for Dev Containers, podman and the VM recipes;
#   devtools/flatpak/host-command prints it where it is missing.
# - /tmp: the launcher's TMPDIR, a directory the host sees at the same path,
#   carries what Dev Containers hands the host's podman, and the host's
#   EDITOR passes its files in through the document portal
#   (home/.config/fish/conf.d/env.fish).
# - org.freedesktop.secrets: every item in the login keyring, not only VS
#   Code's; sign-ins stay in the profile (the launcher's --password-store).
# - login1: power off, reboot and inhibit without a password, for VS Code's
#   suspend events only. Every device beyond the GPU (input, uinput, hidraw,
#   kvm, cameras), pulseaudio (and so the microphone), and ipc (X11 shared
#   memory, a speed-up only).
# SHELL: the terminal runs fish from /app with your dotfiles, whatever the
# caller's shell is. EDITOR and VISUAL: git, sops, kubectl and gh edit in VS
# Code (`code --wait` reaches the running window from any instance of the
# app), never in a value inherited from the caller, such as the host's
# `flatpak run ...`, which does not exist in here. GIT_EDITOR stays unset, so
# a core.editor still wins for git. DISABLE_UPDATES: Claude Code is the
# app's version; its own updater would put a newer one in ~/.local/bin. Set
# here, not only in /app/bin/claude, for the copy the VS Code extension
# runs. MISE_SYSTEM_*: mise's system config and installs in /app, as /etc in
# here is the runtime's. Its shims are not on this PATH, which cannot name a
# per-user dir: the launcher adds them (devtools/flatpak/code). The other
# MISE_*: mise-config.toml's downloads, versions host and paranoid mode (a
# project's mise config runs only as you trusted it, so not what
# claude-sandboxed adds to it), also here: mise ranks the environment above
# every config file, so a project's mise.toml, once trusted, cannot change
# them.
flatpak build-finish "$build" --command=code \
    --share=network \
    --socket=wayland --socket=fallback-x11 --socket=ssh-auth \
    --device=dri --allow=devel \
    --filesystem=~/Developer:create \
    --filesystem=~/.config/fish:ro \
    --filesystem=~/.gitconfig:ro --filesystem=xdg-config/git:ro \
    --filesystem=~/.ssh/known_hosts:ro --filesystem=~/.ssh/config:ro \
    --persist=go --persist=.cargo --persist=.deno --persist=.vscode \
    --talk-name=org.freedesktop.Notifications \
    --env=PATH=/app/bin:/app/go/bin:/app/cargo/bin:/usr/bin \
    --env=RUSTUP_HOME=/app/rustup \
    --env=DENO_NO_UPDATE_CHECK=1 \
    --env=SHELL=/app/bin/fish \
    --env="EDITOR=code --wait" \
    --env="VISUAL=code --wait" \
    --env=DISABLE_UPDATES=1 \
    --env=DISABLE_INSTALLATION_CHECKS=1 \
    --env=MISE_SYSTEM_CONFIG_DIR=/app/etc/mise \
    --env=MISE_SYSTEM_DATA_DIR=/app/share/mise \
    --env=MISE_AUTO_INSTALL=0 \
    --env=MISE_USE_VERSIONS_HOST=0 \
    --env=MISE_USE_VERSIONS_HOST_TRACK=0 \
    --env=MISE_PARANOID=1 \
    --env=LD_LIBRARY_PATH=/app/lib \
    --env=XCURSOR_PATH=/run/host/user-share/icons:/run/host/share/icons \
    --extra-data="code.deb:$sha:$size:0:$url" \
    --extra-data="claude.zst:$claude_sha:$claude_size:0:$claude_url"

# The secret scan every published image gets (.github/actions/scan-image), with
# the trivy just installed and the same rules. Everything in /app is someone
# else's release, so vulnerabilities are left to the dev container's scan of
# the same tools. Run in $work, which has no trivy.yaml or .trivyignore:
# trivy reads those from its working directory.
(cd "$work" && "$build/files/bin/trivy" fs --scanners secret --cache-backend memory \
    --secret-config "$src/.github/actions/scan-image/trivy-secret.yaml" \
    --quiet --exit-code 1 "$build/files")

rm -rf "$out/repo" "$out/oci"
flatpak build-export --arch=x86_64 --subject="VS Code $VSCODE_VERSION, Claude Code $CLAUDE_VERSION" \
    "$out/repo" "$build" stable
flatpak build-bundle --oci "$out/repo" "$out/oci" "$APP_ID" stable
rm -rf "$work"

# --- Test: install it as a machine would, run what it ships ------------------
# System-wide, and used by an ordinary account: flatpak shows a user's home
# in the sandbox, but not root's. The install downloads code.deb from
# Microsoft and claude.zst from Anthropic and runs apply_extra, which proves
# the extra-data above. The terminal's shell must be /app's fish (whatever
# the caller's is) and read ~/.config/fish; a first start installs the
# extensions into the profile (devtools/flatpak/code).
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
unbundled="ms-vscode-remote.remote-containers anthropic.claude-code"
installed=$(mktemp)
# A first start offline: the bundled extensions, Dev Containers and Claude
# Code left for later.
run --unshare=network "$APP_ID" --list-extensions >"$installed"
for id in $bundled; do grep -qixF "$id" "$installed"; done
for id in $unbundled; do if grep -qxF "$id" "$data/extensions-offered"; then exit 1; fi; done
as_tester rm -rf "/home/tester/.var/app/$APP_ID"
# An editor call (EDITOR is "code --wait") installs nothing, offline it
# does not even try.
out=$(run --unshare=network "$APP_ID" --wait --version 2>&1)
if grep -q 'Installing extensions' <<<"$out"; then exit 1; fi
test ! -e "$data/extensions-offered"
# A first start online: all of them from the Marketplace, so none pinned
# (VS Code updates them), each recorded once, and a removed one stays removed.
# The new profile keeps Local History out of /tmp and /run/user (sops and
# kubectl edit plaintext there), gives containers no Wayland socket, and has
# claude-sandboxed as a terminal profile.
as_tester rm -rf "/home/tester/.var/app/$APP_ID"
test "$(run "$APP_ID" --version | head -1)" = "$VSCODE_VERSION"
jq -e '."workbench.localHistory.exclude" == { "/tmp/**": true, "/run/user/**": true } and
    ."dev.containers.mountWaylandSocket" == false and
    ."terminal.integrated.profiles.linux"."claude-sandboxed".path == "/app/bin/claude-sandboxed"' \
    "/home/tester/.var/app/$APP_ID/config/Code/User/settings.json"
run "$APP_ID" --list-extensions >"$installed"
for id in $bundled $unbundled; do
    grep -qixF "$id" "$installed"
    test "$(grep -cxF "$id" "$data/extensions-offered")" = 1
done
jq -e '[.[] | select(.metadata.pinned == true)] | length == 0' "$data/extensions/extensions.json"
run "$APP_ID" --uninstall-extension golang.go
run "$APP_ID" --list-extensions >"$installed"
if grep -qixF golang.go "$installed"; then exit 1; fi
# The terminal's fish reads your config, which is read-only in here, and
# keeps universal variables of its own: a link to the whole directory, as
# the wrapper made before, becomes links to its entries.
# shellcheck disable=SC2016  # the sandbox's variables, not this shell's
as_tester sh -c 'mkdir -p ~/.config/fish && echo "set -g devtools_dotfiles yes" >~/.config/fish/config.fish &&
    rm -rf "$1/fish" && ln -s ~/.config/fish "$1/fish"' sh "/home/tester/.var/app/$APP_ID/config"
# shellcheck disable=SC2016
run --command=bash "$APP_ID" -c 'test "$SHELL" = /app/bin/fish'
run --command=fish "$APP_ID" -c 'set -q devtools_dotfiles && set -U devtools_universal yes'
test -L "/home/tester/.var/app/$APP_ID/config/fish/config.fish"
grep -q devtools_universal "/home/tester/.var/app/$APP_ID/config/fish/fish_variables"
test ! -e /home/tester/.config/fish/fish_variables
# EDITOR and VISUAL come from the app, whatever the caller's are, and git
# resolves to them; Claude Code's updates are off for every process.
# shellcheck disable=SC2016
as_tester env EDITOR=vi VISUAL=vi DISABLE_UPDATES=0 dbus-run-session -- \
    flatpak run --command=bash "$APP_ID" -c \
    'test "$EDITOR" = "code --wait" && test "$VISUAL" = "code --wait" &&
     test "$(cd / && git var GIT_EDITOR)" = "code --wait" &&
     test "$DISABLE_UPDATES" = 1 && test "$DISABLE_INSTALLATION_CHECKS" = 1'
# Claude Code, at the pinned version.
test "$(run --command=claude "$APP_ID" --version)" = "$CLAUDE_VERSION (Claude Code)"
# test.sh, with tools.txt next to it, from this container: shown to that run
# only.
run --filesystem="$src/devtools":ro --command=bash "$APP_ID" "$src/devtools/test.sh"
# mise takes /app's Go as its install of that version with no network at all
# (test.sh only turns off mise's own), in mise exec and in fish.
# shellcheck disable=SC2016
run --unshare=network --command=bash "$APP_ID" -c \
    'cd "$(mktemp -d)" && go=$(go env GOVERSION) &&
     printf "[tools]\ngo = \"%s\"\n" "${go#go}" >mise.toml && mise trust -q &&
     test "$(PATH=/app/bin mise exec -- go env GOVERSION)" = "$go" &&
     test "$(fish -c "go env GOROOT")" = "/app/share/mise/installs/go/${go#go}"'
# The sandbox, with no override: the grants and nothing else of the home or
# the host (this container's /tmp included), no device beyond the GPU, your
# configuration read-only.
as_tester sh -c 'mkdir -p ~/.ssh ~/.kube && touch ~/outside ~/.ssh/id_test ~/.ssh/known_hosts ~/.kube/config ~/.gitconfig'
touch /tmp/outside
# shellcheck disable=SC2016
run --command=sh "$APP_ID" -c \
    'test -w ~/Developer && test -r ~/.gitconfig && test -r ~/.ssh/known_hosts &&
     ! touch ~/.gitconfig 2>/dev/null && ! touch ~/.ssh/known_hosts 2>/dev/null &&
     ! touch ~/.config/fish/x 2>/dev/null &&
     test ! -e ~/outside && test ! -e ~/.ssh/id_test && test ! -e ~/.kube &&
     test ! -e /tmp/outside && test ! -e /run/host/root && test ! -e /dev/kvm'
# What `go install` builds stays, in the app's own ~/go (--persist) with the
# module cache, while the rest of the home in here starts empty each time.
# shellcheck disable=SC2016
run --command=sh "$APP_ID" -c \
    'cd "$(mktemp -d)" && printf "package main\n\nfunc main() {}\n" >main.go &&
     go mod init example.com/persisted && go install && touch ~/gone'
# shellcheck disable=SC2016
run --command=sh "$APP_ID" -c \
    'test -x ~/go/bin/persisted && test ! -e ~/gone && test "$(go env GOMODCACHE)" = "$HOME/go/pkg/mod"'
test -x "/home/tester/.var/app/$APP_ID/go/bin/persisted"
# No host commands: host-command says how to allow them, with podman's 125.
rc=0
out=$(run --command=podman "$APP_ID" --version 2>&1) || rc=$?
test "$rc" = 125
grep -qxF '  flatpak override --user --talk-name=org.freedesktop.Flatpak io.github.lucarickli.Code' <<<"$out"
# With the permission, for one run (the name, or the whole session bus) and
# then as the documented user override, which /.flatpak-info shows: host
# commands run, here on this container, and so does bcvk's way to the host
# (devtools/flatpak/bcvk), the file flatpak deployed.
run --talk-name=org.freedesktop.Flatpak --command=/app/libexec/host-command "$APP_ID" test ! -e /.flatpak-info
run --socket=session-bus --command=/app/libexec/host-command "$APP_ID" test ! -e /.flatpak-info
as_tester flatpak override --user --talk-name=org.freedesktop.Flatpak "$APP_ID"
# shellcheck disable=SC2016
run --command=sh "$APP_ID" -c \
    'grep -qx org.freedesktop.Flatpak=talk /.flatpak-info &&
     /app/libexec/host-command test ! -e /.flatpak-info &&
     /app/libexec/host-command test -x "$(sed -n "s/^app-path=//p" /.flatpak-info)/libexec/bcvk"'
as_tester flatpak override --user --reset "$APP_ID"
# claude-sandboxed's box (--shell runs a shell in it, here probe.sh): the
# repository read-write, its .git, .vscode, .devcontainer, .devcontainer.json
# and .claude read-only, the directories made where missing, a Claude config
# of its own and none of the app's: not its CLAUDE_CONFIG_DIR, not its
# D-Bus. Outside a repository it does not start, nor with that
# CLAUDE_CONFIG_DIR in the repository, also when spelled through a link (as
# /home is one on the target).
run --command=git "$APP_ID" init -q /home/tester/Developer/agent
as_tester sh -c 'echo {} >~/Developer/agent/.devcontainer.json && cat >~/Developer/agent/probe.sh' <<'PROBE'
set -eu
touch file
for d in .git .vscode .devcontainer .claude; do
    if touch "$d/x" 2>/dev/null; then echo "$d is writable" >&2; exit 1; fi
done
if echo '{"initializeCommand": "x"}' >.devcontainer.json 2>/dev/null; then exit 1; fi
if rm -f .devcontainer.json 2>/dev/null; then exit 1; fi
test ! -e "$1" && test "$CLAUDE_CONFIG_DIR" != "$1"
mkdir -p "$CLAUDE_CONFIG_DIR" && touch "$CLAUDE_CONFIG_DIR/inner"
test ! -e /run/flatpak/bus && test ! -e "$XDG_RUNTIME_DIR/bus"
test ! -e /dev/kvm
PROBE
# shellcheck disable=SC2016
run --command=sh "$APP_ID" -c \
    'mkdir -p "$XDG_CONFIG_HOME/claude" && cd ~/Developer/agent &&
     SHELL=/bin/sh claude-sandboxed --shell probe.sh "$XDG_CONFIG_HOME/claude" &&
     ln -s ~/Developer ~/link &&
     ! CLAUDE_CONFIG_DIR=~/link/agent/.claude claude-sandboxed --shell -c true 2>/dev/null &&
     cd ~/Developer && ! claude-sandboxed --shell -c true 2>/dev/null'
test -e /home/tester/Developer/agent/file
test "$(cat /home/tester/Developer/agent/.devcontainer.json)" = "{}"
test -e "/home/tester/.var/app/$APP_ID/data/claude-sandboxed/claude/inner"
test -z "$(ls -A "/home/tester/.var/app/$APP_ID/config/claude")"
# In a worktree, whose .git names the repository: git works in the box, and
# that repository is read-only there, its other files out of sight.
# shellcheck disable=SC2016
run --command=sh "$APP_ID" -c \
    'cd ~/Developer/agent && git add probe.sh &&
     git -c user.name=t -c user.email=t@example.invalid commit -q -m probe &&
     git worktree add -q ../agent-wt && cd ../agent-wt &&
     SHELL=/bin/sh claude-sandboxed --shell -c "
         git status --porcelain >/dev/null && git log -1 --format=%s | grep -qx probe &&
         ! touch ../agent/.git/x 2>/dev/null &&
         ! touch \"\$(git rev-parse --git-dir)/x\" 2>/dev/null &&
         test ! -e ../agent/probe.sh"'
# The app is on the host's network (--share=network): a server started in it,
# a dev server in the terminal, is reachable from outside on localhost.
as_tester dbus-run-session -- flatpak run --command=python3 "$APP_ID" \
    -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 &
for _ in $(seq 30); do curl -fsS -o /dev/null http://127.0.0.1:8765/ && break; sleep 1; done
curl -fsS -o /dev/null http://127.0.0.1:8765/
as_tester flatpak kill "$APP_ID"
