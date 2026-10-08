#!/usr/bin/env bash
#
# Every tool from tools.txt runs, and the toolchains build something. Run
# inside the dev container and the VS Code Flatpak (devcontainer.yml,
# flatpak/build.sh), as the user who will use them, with tools.txt next to
# this file.
set -euxo pipefail

kubectl version --client
kubectl-oidc_login --version
kubectl-radar --version
helm version
helmfile version
flux --version
talosctl version --client
talhelper --version
crane version
trivy --version
certinfo --version
sops --version
cosign version
# On the host where it can reach it (devtools/flatpak/bcvk,
# devtools/host-command), in place where not: --version works either way.
bcvk --version
age --version
rg --version
fd --version
just --version
gh --version
yq --version
shellcheck --version
actionlint -version
host-spawn --version
fish --version
mise --version

# From the distribution (dev container) or the runtime (Flatpak).
gcc --version
git --version
git lfs version
jq --version
strace -V

go version
gopls version
dlv version
staticcheck -version
gofumpt -version
golangci-lint version
deno --version
rustc --version
cargo --version
cargo clippy --version
rustfmt --version
rust-analyzer --version
protoc --version
buf --version
protoc-gen-go --version
protoc-gen-go-grpc --version

cd "$(mktemp -d)"
printf 'package main\n\nfunc main() { println("go ok") }\n' >main.go
go mod init example.com/hello
go build
./hello
cargo new --vcs none hello-rs
cargo run --manifest-path hello-rs/Cargo.toml
deno eval 'console.log("deno ok")'
# A service with a well-known type: protoc finds google/protobuf/*.proto next
# to itself, the Go plugins generate, buf lints and builds the same file.
cd "$(mktemp -d)"
mkdir -p proto/hello/v1
cat >proto/hello/v1/hello.proto <<'PROTO'
syntax = "proto3";
package hello.v1;
option go_package = "example.com/hello/hellov1";
import "google/protobuf/timestamp.proto";
message SayHelloRequest { google.protobuf.Timestamp at = 1; }
message SayHelloResponse { string text = 1; }
service HelloService { rpc SayHello(SayHelloRequest) returns (SayHelloResponse); }
PROTO
protoc -I proto --go_out=. --go_opt=paths=source_relative \
    --go-grpc_out=. --go-grpc_opt=paths=source_relative proto/hello/v1/hello.proto
test -s hello/v1/hello.pb.go && test -s hello/v1/hello_grpc.pb.go
printf 'version: v2\nmodules:\n  - path: proto\n' >buf.yaml
buf lint
buf build
fish -c 'echo fish ok'

# mise (devtools/mise-system.sh, mise-config.toml), its network off: the Go
# and Deno here are its installs of their versions, which a project naming
# them gets without the rest of PATH, once trusted, and so does fish there;
# `mise use` finds nothing to change in the read-only system part; GOBIN and
# DENO_INSTALL_ROOT stay in $HOME; a version that is not installed is not
# downloaded, the pinned one runs, also in a trusted project whose settings
# ask for downloads and the versions host and turn paranoid off (the
# environment's MISE_* win; offline, mise exec fails where it tries).
export MISE_OFFLINE=1
prefix=$(dirname "$(dirname "$(command -v mise)")")
go=$(go env GOVERSION) deno=$(deno --version | awk 'NR == 1 { print $2 }')
cd "$(mktemp -d)"
printf '[tools]\ngo = "%s"\ndeno = "%s"\n' "${go#go}" "$deno" >mise.toml
mise trust -q
test "$(PATH=$prefix/bin mise exec -- go env GOVERSION)" = "$go"
test "$(PATH=$prefix/bin mise exec -- deno --version | awk 'NR == 1 { print $2 }')" = "$deno"
mise ls --json go | jq -e --arg dir "$prefix/share/mise/installs/go/${go#go}" \
    'any(.[]; .install_path == $dir and .installed)'
test "$(fish -c 'go env GOROOT')" = "$prefix/share/mise/installs/go/${go#go}"
mise use "go@${go#go}" "deno@$deno"
test "$(mise exec -- go env GOBIN)" = "$(go env GOBIN)"
test "$(mise exec -- printenv DENO_INSTALL_ROOT)" = "$HOME/.deno"
printf '[settings]\nauto_install = true\nuse_versions_host = true\nuse_versions_host_track = true\nparanoid = false\n[tools]\ngo = "1.20.0"\n' >mise.toml
mise trust
for s in auto_install use_versions_host use_versions_host_track; do test "$(mise settings get "$s")" = false; done
test "$(mise settings get paranoid)" = true
test "$(mise exec -- go env GOVERSION)" = "$go"
test "$(fish -c 'go env GOVERSION')" = "$go"
# Paranoid: a trusted project's mise config runs nothing new until `mise
# trust` again, neither a file added next to it (as claude-sandboxed can) nor
# a change to it; here exec() templates that make a file, once trusted.
cat >mise.local.toml <<'TOML'
[env]
RAN = "{{ exec(command='touch ran') }}"
TOML
if mise env >/dev/null 2>&1; then exit 1; fi
fish -c true 2>/dev/null
rm mise.local.toml
printf '[env]\nRAN = "{{ exec(command=%s) }}"\n' "'touch ran'" >mise.toml
if mise env >/dev/null 2>&1; then exit 1; fi
fish -c true 2>/dev/null
test ! -e ran
mise trust -q
mise env >/dev/null
test -e ran

# Each tool's license texts, next to the tools (/app or /usr/local): every
# line of tools.txt (next to this file) has them, and SOURCES where it names
# a source.
licenses=$(dirname "$(dirname "$(command -v rg)")")/share/licenses
test -d "$licenses"
for d in "$licenses"/*/; do test -n "$(ls -A "$d")"; done
while read -r name _ _ _ _ _ source; do
    case $name in '' | '#'*) continue ;; esac
    test -n "$(ls -A "$licenses/$name")"
    if [ -n "$source" ]; then test -s "$licenses/$name/SOURCES"; else test ! -e "$licenses/$name/SOURCES"; fi
done <"$(dirname "$0")/tools.txt"
