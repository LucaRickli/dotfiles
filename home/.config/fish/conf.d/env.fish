# Per-user environment.
# fish sources conf.d/*.fish before config.fish, so config.fish can override.
# EDITOR: VS Code, the repository's own Flatpak (devtools/flatpak/). In its
# terminal, which runs this fish too (the app sets EDITOR as well, but this
# file comes after and would replace it), and in a Dev Containers one (VS
# Code's remote CLI, its socket in VSCODE_IPC_HOOK_CLI), `code` is VS Code
# itself. On the host flatpak runs it and hands it the file through the
# document portal (--file-forwarding: the file a tool adds after the @@),
# as the app does not see the host's /tmp, where sops, kubectl edit and
# crontab -e put theirs. The app keeps write access to each file handed in
# so until logout (the portal's grant outlives --wait; docs/devtools.md,
# EDITOR); one it already sees goes in as it is, read-only where so granted.
# Without flatpak (a toolbox) vim, or without vim the system's default.
if set -q FLATPAK_ID; or test -S "$VSCODE_IPC_HOOK_CLI"
    set -gx EDITOR "code --wait"
else if command -q flatpak
    set -gx EDITOR "flatpak run --file-forwarding io.github.lucarickli.Code --wait @@"
else if command -q vim
    set -gx EDITOR vim
end
# sudoedit hands the editor a copy in /var/tmp, which the Flatpak cannot see.
set -gx SUDO_EDITOR vim
set -gx SOPS_AGE_KEY_FILE ~/.config/sops/age/keys.txt
