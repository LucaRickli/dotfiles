#!/usr/bin/env bash
#
# Every tool from tools.txt runs, and the toolchains build something. Run
# inside the dev container and the VS Code Flatpak (devcontainer.yml,
# flatpak/build.sh), as the user who will use them.
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
age --version
rg --version
fd --version
just --version
gh --version
shellcheck --version
host-spawn --version
fish --version

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
