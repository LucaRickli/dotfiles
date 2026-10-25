# Dotfiles

Configuration for fish, ghostty, niri, labwc, Noctalia and fastfetch, kept in
`home/.config` and linked into `~/.config` with
[GNU Stow](https://www.gnu.org/software/stow/), and the desktop apps to
install.

## On a new machine

Clone this repository anywhere, then in the checkout:

```sh
./dotfiles.sh
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub $(grep -vE '^\s*(#|$)' flatpaks.txt)
```

`dotfiles.sh` (needs GNU Stow) links each entry of `home/.config` into
`~/.config`, asking before it replaces anything. With the links in place,
editing a config in `~/.config` edits this checkout; run it again after
pulling changes that add or rename entries. `flatpaks.txt` lists the apps:
Firefox, Remmina and Bazaar (the app store).

## Checks

`./check.sh` checks the syntax of `dotfiles.sh`, the fish files and the JSON
(needs fish and jq). CI runs it on every push to main and every pull
request.
