# kubectl is in the VS Code Flatpak and the dev container (the devtools), not
# on the host, which reaches it through the Flatpak.
function k --wraps=kubectl --description 'alias k=kubectl'
    if command -q kubectl
        kubectl $argv
    else if command -q flatpak; and test -e /var/lib/flatpak/exports/bin/io.github.lucarickli.Code -o -e ~/.local/share/flatpak/exports/bin/io.github.lucarickli.Code
        flatpak run --command=kubectl io.github.lucarickli.Code $argv
    else
        echo "k: no kubectl here, and no VS Code Flatpak to run it from" >&2
        return 127
    end
end
