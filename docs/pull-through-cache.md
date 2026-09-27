# Pull-through cache

Installs and updates can pull the image through a pull-through cache or
registry mirror. The image keeps its `ghcr.io` name, so its cosign signature
is still checked. Only this image (`ghcr.io/lucarickli/fedora-bootc`, every
tag) goes through the cache; every other image is pulled as usual.

## The cache

It has to allow anonymous pulls and serve cosign's `sha256-<digest>.sig` tags
like any other tag. The CNCF registry in proxy mode does both; on any machine
with podman:

```sh
podman run -d --name ghcr-cache -p 5000:5000 -v ghcr-cache:/var/lib/registry \
    -e REGISTRY_PROXY_REMOTEURL=https://ghcr.io docker.io/library/registry:3
```

Its address is then `http://<that machine>:5000`: plain HTTP, and TCP port
5000 has to be open in that machine's firewall.

When the cache cannot be reached, pulls go to `ghcr.io`. When it answers but
has no `.sig` for the image, the pull fails: the signature is only looked for
where the image came from.

## Live ISO

In the ISO's boot menu press `e`, add the argument to the end of the `linux`
line and boot with Ctrl+X. The address stands in for `ghcr.io`; its host
needs a dot or a port (`nas.lan`, `nas:5000`):

| Argument | The image comes from |
| --- | --- |
| `fedora-bootc.mirror=http://192.168.1.10:5000` | `192.168.1.10:5000/lucarickli/fedora-bootc`, plain HTTP |
| `fedora-bootc.mirror=cache.example.com/ghcr` | `cache.example.com/ghcr/lucarickli/fedora-bootc`, HTTPS |

Then install as usual ([install.md](install.md#live-iso)).
`sudo journalctl -b -u select-installer-image` on the Ctrl+Alt+F2 console
shows the mirror in use, or why the argument was ignored.

## The installed system

The ISO copies the two files it wrote into the installed `/etc`, so
`bootc upgrade`, `bootc switch` to another tag and `podman pull` of this image
keep using the cache:

```
/etc/containers/registries.conf.d/50-fedora-bootc-mirror.conf
/etc/containers/registries.d/50-fedora-bootc-mirror.yaml
```

Edit them to move to another cache, or delete both to pull from `ghcr.io`
again. A plain-HTTP cache is trusted on every network the machine joins:
whoever answers at its address elsewhere can hold back updates or serve an
older signed image. On a laptop, use HTTPS or delete the files after
installing. Other images go through a cache only with a `[[registry]]` block
of their own (`man containers-registries.conf`).

## Manual install

Run this in bash on the live system before installing
([install.md](install.md#manual-from-any-live-usb)), and again on the
installed system after its first boot, with `m` set to where the cache has
the image:

```sh
m=192.168.1.10:5000/lucarickli/fedora-bootc
sudo tee /etc/containers/registries.conf.d/50-fedora-bootc-mirror.conf > /dev/null << EOF
[[registry]]
prefix = "ghcr.io/lucarickli/fedora-bootc"
location = "ghcr.io/lucarickli/fedora-bootc"

[[registry.mirror]]
location = "$m"
insecure = true    # plain HTTP only: drop this line for HTTPS
EOF
sudo tee /etc/containers/registries.d/50-fedora-bootc-mirror.yaml > /dev/null << EOF
docker:
  $m:
    use-sigstore-attachments: true
EOF
```

Keep using the `ghcr.io` name in every command: the installed system updates
from, and checks the signature of, the name it was installed as.
