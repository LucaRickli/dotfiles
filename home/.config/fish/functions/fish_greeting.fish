# fastfetch is on the host only, not in the VS Code Flatpak or a toolbox.
function fish_greeting
    command -q fastfetch; and fastfetch --config ~/.config/fastfetch/config.json
end