# Per-user environment.
# fish sources conf.d/*.fish before config.fish, so config.fish can override.
# VS Code is the repository's own Flatpak (devtools/flatpak/). Its terminal
# runs this fish too, and there `code` is VS Code itself; where there is
# neither (a toolbox), vim.
if set -q FLATPAK_ID
    set -gx EDITOR "code --wait"
else if command -q flatpak
    set -gx EDITOR "flatpak run io.github.lucarickli.Code --wait"
else
    set -gx EDITOR vim
end
# sudoedit hands the editor a copy in /var/tmp, which the Flatpak cannot see.
set -gx SUDO_EDITOR vim
set -gx SOPS_AGE_KEY_FILE ~/.config/sops/age/keys.txt
