# Per-user environment.
# fish sources conf.d/*.fish before config.fish, so config.fish can override.
# VS Code is the Flathub Flatpak (packages/flatpaks.txt).
set -gx EDITOR "flatpak run com.visualstudio.code --wait"
# sudoedit hands the editor a copy in /var/tmp, which the Flatpak cannot see.
set -gx SUDO_EDITOR vim
set -gx SOPS_AGE_KEY_FILE ~/.config/sops/age/keys.txt
