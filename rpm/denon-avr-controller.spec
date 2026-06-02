# Version bookkeeping — update these three globals and the %%changelog entry
# together.  The `make tag` target reminds you to keep them in sync.
#
# Pre-release ordering: Release 0.<N>.<label> sorts below 1.<dist> (GA),
# which is what we want so `dnf upgrade` moves cleanly from beta to final.
%global version_base  1.2.0
%global pre_tag       beta.6
%global rpm_release   0.1.beta6

# GitHub archive for tag v<version_base>-<pre_tag> unpacks as:
#   denon-avr-controller-<version_base>-<pre_tag>/
# (GitHub strips the leading 'v' from directory names inside tarballs.)
%global tag_name      v%{version_base}-%{pre_tag}
%global source_dir    denon-avr-controller-%{version_base}-%{pre_tag}

Name:           denon-avr-controller
Version:        %{version_base}
Release:        %{rpm_release}%{?dist}
Summary:        Command-line controller for Denon/Marantz AVR receivers

License:        MIT
URL:            https://github.com/tiffany98101/denon-avr-controller
Source0:        https://github.com/tiffany98101/denon-avr-controller/archive/refs/tags/%{tag_name}.tar.gz#/denon-avr-controller-%{tag_name}.tar.gz

BuildArch:      noarch

Requires:       bash
Requires:       curl
Requires:       gawk
Requires:       sed
Requires:       grep
Requires:       iproute
Requires:       nmap-ncat
Requires:       jq
Requires:       python3
Requires:       python3-pydbus
Requires:       python3-gobject
Requires:       avahi-tools

# shellcheck is used by `denon doctor` when available; not strictly required.
Recommends:     ShellCheck

%description
denon-avr-controller is a bash command-line interface for Denon and Marantz
AVR receivers.  It uses the receiver's HTTP/XML API for control (power,
volume, input selection, EQ modes, Zone 2) and bundles an MPRIS2 D-Bus
bridge so Plasma 6 media controls, lock-screen keys, and KDE Connect relay
all work automatically.

Key features:
  - Auto-discovery via ARP / mDNS — no static IP required
  - Bash, Zsh, and Fish tab completion
  - MPRIS2 bridge published as a systemd user unit (denon-mpris.service)
  - Zone 2 control, sleep timer, presets, snapshot/diff

After install, enable the MPRIS bridge for your user account:
  systemctl --user enable --now denon-mpris.service


%prep
%setup -q -n %{source_dir}


%build
# Nothing to compile — pure bash + Python.


%install
# Main controller script → /usr/bin/denon
install -Dm755 denon.sh %{buildroot}%{_bindir}/denon

# MPRIS2 D-Bus bridge → /usr/bin/denon-mpris
install -Dm755 denon_mpris.py %{buildroot}%{_bindir}/denon-mpris

# Python helpers used by /usr/bin/denon → /usr/libexec/denon-avr-controller/
install -Dm755 denon_dashboard_alt.py \
    %{buildroot}%{_libexecdir}/denon-avr-controller/denon_dashboard_alt.py
install -Dm755 denon_heos_helper.py \
    %{buildroot}%{_libexecdir}/denon-avr-controller/denon_heos_helper.py

# Systemd user unit → /usr/lib/systemd/user/
# Patch ExecStart from the ~-relative dev path to the system binary path.
install -Dm644 denon-mpris.service \
    %{buildroot}%{_userunitdir}/denon-mpris.service
sed -i 's|ExecStart=.*|ExecStart=%{_bindir}/denon-mpris|' \
    %{buildroot}%{_userunitdir}/denon-mpris.service

# Bash completion → /usr/share/bash-completion/completions/denon
install -Dm644 completions/bash/denon \
    %{buildroot}%{_datadir}/bash-completion/completions/denon

# Zsh completion → /usr/share/zsh/site-functions/_denon
install -Dm644 completions/zsh/_denon \
    %{buildroot}%{_datadir}/zsh/site-functions/_denon

# Fish completion → /usr/share/fish/vendor_completions.d/denon.fish
install -Dm644 completions/fish/denon.fish \
    %{buildroot}%{_datadir}/fish/vendor_completions.d/denon.fish

# Man page → /usr/share/man/man1/denon.1
install -Dm644 man/denon.1 %{buildroot}%{_mandir}/man1/denon.1


%files
%license LICENSE
%doc README.md RELEASE_NOTES.md
%{_bindir}/denon
%{_bindir}/denon-mpris
%{_libexecdir}/denon-avr-controller/denon_dashboard_alt.py
%{_libexecdir}/denon-avr-controller/denon_heos_helper.py
%{_userunitdir}/denon-mpris.service
%{_datadir}/bash-completion/completions/denon
%{_datadir}/zsh/site-functions/_denon
%{_datadir}/fish/vendor_completions.d/denon.fish
%{_mandir}/man1/denon.1*


# We intentionally omit %%post/%%preun systemd scriptlets for user units.
# systemd_user_post applies the system preset (disabled by default) and
# systemd_user_preun handles uninstall cleanup.  Neither auto-enables
# the service, but they add confusion.  Document the manual enable step
# in %%description and the README instead.


%changelog
* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.1.beta6
- Add interactive keyboard controls to the main dashboard and dashboard-alt
  (volume, mute, transport, source-number selection, zone toggle)
- Verify dashboard HEOS transport commands against selected AVR player state
  and metadata before reporting success
- Standardize dashboard footer control hints with key=action wording
- Harden Zone 2 volume safety (dB cap and raw range), set_config HTTP status
  handling, and cached receiver IP validation

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.8.beta5
- Harden Zone 2 volume safety, set_config HTTP status handling, and cached IP validation

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.7.beta5
- Standardize interactive dashboard footer control hints with key=action wording

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.6.beta5
- Verify dashboard HEOS transport commands against selected AVR player state
  and metadata before reporting success

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.5.beta5
- Improve dashboard transport feedback, Receiver Info rendering, and packaged
  helper discovery for dashboard-alt and HEOS helper scripts
- Compile the PowerShell TLS validator so custom CA and sha256// public-key
  pinning work on PowerShell 7; add Pester TLS coverage and analyzer validation

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.4.beta4
- Prepare v1.2.0-beta.4 release after completion, hardening, portability,
  reliability, performance, TLS, and release-readiness updates

* Wed May 20 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.3.beta3
- Initial RPM packaging for Fedora/Copr
- Includes bash/zsh/fish completion, man page, and systemd user unit
