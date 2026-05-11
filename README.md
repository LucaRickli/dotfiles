# Dotfiles

## Assumptions

- Arch Linux installed
- User has `sudo` privileges

Relevant for secure-boot:

- Unified kernel images (UKI) enabled
- Systemd-boot as bootloader
- Btrfs root with subvolumes

## Install

Clone This Repo

```bash
git clone https://github.com/LucaRickli/dotfiles.git ~/dotfiles
cd ~/dotfiles
```

Run the Installer

```bash
chmod +x scripts/*.sh
chmod +x install.sh

./install.sh
```

After rebooting GDM will start. Select **Niri** (⚙ icon) as desktop environment.

## NVIDIA Setup

### Required Packages

See `packages/nvidia.txt`. Key packages:

| Package               | Purpose                              |
| --------------------- | ------------------------------------ |
| `nvidia`              | Proprietary kernel driver            |
| `nvidia-utils`        | Userspace utilities                  |
| `egl-wayland`         | EGL platform support for Wayland     |
| `libva-nvidia-driver` | Hardware video acceleration (VA-API) |

### Bootloader Kernel Parameters

Add these to your bootloader entry:

**systemd-boot** (`/boot/loader/entries/arch.conf`):

```txt
options ... nvidia_drm.modeset=1 nvidia_drm.fbdev=1
```

#### Kernel Parameters

| Parameter              | Purpose                                   |
| ---------------------- | ----------------------------------------- |
| `nvidia_drm.modeset=1` | Enable DRM KMS — **required for Wayland** |
| `nvidia_drm.fbdev=1`   | Enable NVIDIA framebuffer (kernel ≥ 6.2)  |

### Early KMS

`system/mkinitcpio-nvidia.conf` is copied to `/etc/mkinitcpio.conf.d/` and
adds the four NVIDIA modules to the initramfs, ensuring DRM is initialised
before SDDM starts.

### Environment Variables

```ini
env = LIBVA_DRIVER_NAME,nvidia
env = GBM_BACKEND,nvidia-drm
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
```

`cursor { no_hardware_cursors = true }` is already set in
`config/hypr/appearance.conf` — hardware cursors cause artefacts on NVIDIA.
