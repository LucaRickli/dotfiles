# The OS

greetd with noctalia-greeter, five Wayland sessions (niri, labwc, sway, river,
wayfire) running the [Noctalia](https://noctalia.dev) shell, ghostty and fish,
podman and docker, QEMU/KVM with Virtual Machine Manager, XRDP, a local LLM
server, and an NVIDIA variant. Desktop apps are Flatpaks (`flatpaks.txt`);
the development tools are not on the host ([devtools.md](devtools.md)).

## Remote desktop (XRDP)

Port 3389, your normal account (not root), labwc by default: `niri`, `sway`,
`river` or `wayfire` in the client's alternate shell field (Remmina: Advanced,
"Start-up program"; xfreerdp: `/shell:sway`) or in `~/.config/xrdp-session`
picks another (niri needs a GPU). For resizing, enable Remmina's "Dynamic
resolution update" and "Use initial window size". Sessions log to
`~/.xrdp-session.log`; details in
[`startwm.sh`](../features/xrdp/overlay/etc/xrdp/startwm.sh).

Each machine generates its own XRDP keys before xrdp first starts, so a
client asks once to trust the certificate. Compare the fingerprint it shows
with `sudo openssl x509 -noout -fingerprint -sha256 -in /etc/xrdp/cert.pem`
(`-sha1` for Windows clients).

## Virtual machines

Virtual Machine Manager (`virt-manager`) and `virt-install` on the system's
libvirt (`qemu:///system`), with the default NAT network. Accounts the
installer created can manage VMs without a password; for another account:
`sudo usermod -aG libvirt <user>`, then log in again.

## Local LLM

[shimmy](https://github.com/Michael-A-Kuykendall/shimmy) serves GGUF models
as an OpenAI-compatible API on `http://127.0.0.1:11435/v1`, on the GPU
through Vulkan. Off by default; per user:

```sh
mkdir -p ~/.local/share/shimmy/models    # put .gguf files here
systemctl --user enable --now shimmy
curl http://127.0.0.1:11435/v1/models
```

It also finds models in `~/models` and the Hugging Face, Ollama and LM Studio
caches; upstream lists the models it certifies. The VS Code Flatpak reaches
it at the same address. Its WebGPU engine is young: on a Ryzen 7000 iGPU
(RADV) a request hangs the GPU until the kernel resets it.

## Other defaults

- Boot is silent: a splash with a spinner, no text (Esc shows the messages),
  and no boot menu unless you hold Space at power-on.
- SSH: passwords for users, keys only for root. fail2ban guards SSH and XRDP.
- Every session has an SSH agent (gcr's), which offers the keys in `~/.ssh`;
  for one with a passphrase, run `ssh-add` once after login. Flatpaks with
  SSH access, such as the VS Code one, sign through it without reading the
  keys.
- Tailscale is installed but off:
  `sudo systemctl enable --now tailscaled && sudo tailscale up`.
- Cockpit (web admin) is installed but off:
  `sudo systemctl enable --now cockpit.socket`, then <http://localhost:9090>.
  It listens on loopback only; from another machine use
  `ssh -L 9090:localhost:9090 <user>@<machine>`. Services (fail2ban too), logs,
  firewall, storage, SELinux, files and podman containers; Fedora has no
  Cockpit plugin for docker. Its Metrics page is switched off.

## NVIDIA

`nvidia` and `nvidia-uki` add the RPM Fusion driver
([`features/nvidia/`](../features/nvidia/)), built with akmods and signed
with the same db key (open kernel modules unless built with `closed`).
The live ISO installs it on machines with a GTX 16 / RTX 20 series or newer
(what the open modules support); to move an existing install,
`sudo bootc switch ghcr.io/lucarickli/fedora-bootc:nvidia-uki`. Under Secure
Boot the modules also need shim + MOK enrollment, which is untested, so keep
Secure Boot off there for now ([secureboot-tpm2.md](secureboot-tpm2.md)).
