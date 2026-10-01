# Development tools

[`devtools/tools.txt`](../devtools/tools.txt) pins them: Go, Deno, Rust and
Protocol Buffers (protoc, buf) with their language servers and linters,
kubectl, helm, flux, talosctl, sops, age, trivy, gh, fish and more;
[`extensions.txt`](../devtools/extensions.txt) the VS Code extensions for
those languages. [`install.sh`](../devtools/install.sh) installs both lists,
checking every download, and [`test.sh`](../devtools/test.sh) is the test
both builds pass. They are not on the host.

## VS Code

`io.github.lucarickli.Code` ([`devtools/flatpak/`](../devtools/flatpak/build.sh))
is a Flatpak on Flathub's Freedesktop Sdk (gcc, git, gdb) with every tool, so
its terminal (fish, with your `~/.config/fish`) is a development environment
of its own. Its first start installs the language extensions and Dev
Containers into your profile from the Marketplace (offline, the language
ones from copies in the app); from then on they are ordinary extensions. VS
Code itself is downloaded from Microsoft when the app is installed or
updated. CI publishes it to `ghcr.io/lucarickli/code`, an OCI image for a
Flatpak remote to point at; nothing installs it on its own. To try a build
without CI:

```sh
just flatpak           # build and test it in a container: output/flatpak/
just flatpak-install   # install that build for your user (again to update)
flatpak run io.github.lucarickli.Code
```

Outside VS Code, the same shell: `flatpak run --command=fish
io.github.lucarickli.Code`. Rust is the pinned toolchain only; a project that
needs another toolchain or target uses the dev container.

Dev Containers runs your rootless podman through host-spawn. A new VS Code
profile starts with `"dev.containers.dockerPath": "podman"`; add it to an
existing `settings.json`.

## The dev container

`ghcr.io/lucarickli/devcontainer` ([`devtools/Containerfile`](../devtools/Containerfile),
CI weekly and on change, `just devcontainer` locally): Fedora toolbox with the
same tools and extensions. In a project:

```jsonc
// .devcontainer/devcontainer.json
{ "image": "ghcr.io/lucarickli/devcontainer:latest" }
```

If docker on an SELinux host denies the workspace mount, add
`"runArgs": ["--security-opt", "label=disable"]` (podman does that itself). As
a toolbox: `toolbox create --image ghcr.io/lucarickli/devcontainer:latest dev`.

## Ports

A server started in the VS Code Flatpak, or in a toolbox, is on the host's
network: `localhost:<port>` reaches it. Dev Containers forwards the ports a
container listens on to `localhost` (or list them in `forwardPorts`).

## Offline

For no internet for VS Code or the container:

- Move the image with `podman save` / `podman load`; the name stays the same.
- Install Dev Containers (0.447.0 or newer) from a `.vsix` (Extensions, `...`,
  Install from VSIX):
  `curl -fsSL --compressed -o dev-containers.vsix https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode-remote/vsextensions/remote-containers/0.469.0/vspackage`
- Put the VS Code Server for your VS Code's commit (Help, About) at
  `<folder>/<commit>/vscode-server-linux-x64.tar.gz`, from
  `https://update.code.visualstudio.com/commit:<commit>/server-linux-x64/stable`,
  and set `"remote.serverDownloadFolder": "<folder>"` (absolute path) in your
  user settings.
