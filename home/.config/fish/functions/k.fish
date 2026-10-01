# kubectl is in the VS Code Flatpak and the dev container (devtools/), not on
# the host, which reaches it through the Flatpak.
function k --wraps=kubectl --description 'alias k=kubectl'
    if command -q kubectl
        kubectl $argv
    else
        flatpak run --command=kubectl io.github.lucarickli.Code $argv
    end
end
