# noctalia-greeter for this image only: build.sh (next to this file) builds it
# from the upstream tag pinned there and passes the version in.
Name:           noctalia-greeter
Version:        %{greeter_version}
Release:        1%{?dist}
Summary:        A minimal login greeter for greetd that matches the look and feel of Noctalia Shell
License:        MIT
URL:            https://github.com/noctalia-dev/noctalia-greeter
Source0:        %{name}-%{version}.tar.gz

# meson.build's dependency() and has_header() checks.
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  meson
BuildRequires:  stb-devel
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(cairo-ft)
BuildRequires:  pkgconfig(egl)
BuildRequires:  pkgconfig(fontconfig)
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gobject-2.0)
BuildRequires:  pkgconfig(libinput)
BuildRequires:  pkgconfig(librsvg-2.0)
BuildRequires:  pkgconfig(libwebp)
BuildRequires:  pkgconfig(libxml-2.0)
BuildRequires:  pkgconfig(nlohmann_json)
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(pangoft2)
BuildRequires:  pkgconfig(tomlplusplus)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-egl)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(wlroots-0.20)
BuildRequires:  pkgconfig(xkbcommon)

# What its scripts run; rpm finds the libraries itself.
Requires:       greetd
Requires:       /usr/bin/dbus-run-session

%description
Noctalia Greeter is the screen before the desktop session starts: pick a user,
enter the password, choose a Wayland session and a color scheme, in the visual
language of Noctalia Shell.

%prep
%autosetup

%build
# %%meson builds with --buildtype=plain; upstream's `release` buildtype would
# add -march=native (PACKAGING.md). meson.build's own default c_args replace
# Fedora's CFLAGS for the C sources (the compositor), which then come out
# without hardening, optimisation or PIE, and the PIE link fails. So hand
# them Fedora's flags plus upstream's one addition.
%meson -Db_pie=true -Dc_args="%{build_cflags} -Wno-error=switch"
%meson_build

%install
%meson_install
# The image ships its own (features/login/overlay/usr/lib/tmpfiles.d/noctalia-greeter.conf):
# upstream's creates the state dir for a `greeter` user, greetd runs the
# greeter as `greetd` here.
rm -f %{buildroot}%{_tmpfilesdir}/noctalia-greeter.conf

# Globs, so that a release adding a helper still builds unattended.
%files
%license LICENSE
%doc README.md
%{_bindir}/noctalia-greeter*
%{_datadir}/noctalia-greeter/
%{_datadir}/polkit-1/actions/org.noctalia.greeter.*.policy
