# Version bookkeeping — update these three globals and the %%changelog entry
# together.  The `make tag` target reminds you to keep them in sync.
#
# Pre-release ordering: Release 0.<N>.<label> sorts below 1.<dist> (GA),
# which is what we want so `dnf upgrade` moves cleanly from beta to final.
%global version_base  1.2.0
%global pre_tag       beta.8
%global rpm_release   0.15.beta8

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
Requires:       python3-cryptography
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
install -Dm644 VERSION %{buildroot}%{_datadir}/denon-avr-controller/VERSION

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

# v2 transport/protocol/config/compat libs → /usr/share/denon/lib/
for lib in lib/transport.sh lib/protocol.sh lib/config.sh lib/compat.sh; do
    install -Dm644 "$lib" %{buildroot}%{_datadir}/denon/lib/"$(basename $lib)"
done

# Man page → /usr/share/man/man1/denon.1
install -Dm644 man/denon.1 %{buildroot}%{_mandir}/man1/denon.1


%files
%license LICENSE
%doc README.md RELEASE_NOTES.md
%{_bindir}/denon
%{_bindir}/denon-mpris
%{_datadir}/denon-avr-controller/VERSION
%{_libexecdir}/denon-avr-controller/denon_dashboard_alt.py
%{_libexecdir}/denon-avr-controller/denon_heos_helper.py
%{_userunitdir}/denon-mpris.service
%{_datadir}/bash-completion/completions/denon
%{_datadir}/zsh/site-functions/_denon
%{_datadir}/fish/vendor_completions.d/denon.fish
%{_mandir}/man1/denon.1*
%{_datadir}/denon/lib/transport.sh
%{_datadir}/denon/lib/protocol.sh
%{_datadir}/denon/lib/config.sh
%{_datadir}/denon/lib/compat.sh


# We intentionally omit %%post/%%preun systemd scriptlets for user units.
# systemd_user_post applies the system preset (disabled by default) and
# systemd_user_preun handles uninstall cleanup.  Neither auto-enables
# the service, but they add confusion.  Document the manual enable step
# in %%description and the README instead.


%changelog
* Wed Jun 10 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.15.beta8
- Fix dashboard-ultra Sources panel after adaptive layout: format source entries
  against final panel width, preserve full source names, and use +N more when
  space is constrained instead of truncating to orphaned fragments.

* Wed Jun 10 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.14.beta8
- Make dashboard-ultra adaptive: priority-tiered panel/field layout driven by
  the terminal cell grid, with graceful tier shedding and column reflow.
- Add DSP/Audyssey, Device/Firmware, and System/Locks panels; promote non-zero
  pending firmware updates into the high-priority receiver area.
- Add simulated-grid render coverage for 80x24, 140x40, 200x55, and 320x90.

* Wed Jun 10 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.13.beta8
- Add v2 transport/protocol/config/compat library layer; wire avr_send routing
  into _denon_telnet/_denon_telnet_query with DENON_UNIT_TEST bypass
- Add `denon raw dump [type…]` and `denon raw types` subcommands
- Fix dashboard-ultra Unknown fields: split 12-verb AppCommand batch into
  3x4-verb batches to avoid AVR-X1600H goform daemon wedge (~51 s blackout);
  add _denon_dashboard_fetch_core_status fallback via _denon_info / get_config
- Fix quit key (q) in dashboard-ultra: delegate to shared sleep/poll loop
- Port full interactive keybindings (↑/↓/←/→/Space/M/#/Z/Q) to dashboard-ultra
- Fix dashboard-ultra TV panel: use lgtv audio status; friendly output labels
- Install v2 lib/ scripts to /usr/share/denon/lib/ for runtime discovery

* Tue Jun 09 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.11.beta8
- Add `denon dashboard-ultra`, an alternate ultrawide multi-panel dashboard
  (5 panels at 200+ columns, 3+2 panels at 120-199, stacked below 120).
  Surfaces audio signal/sample rate, speaker config and per-channel levels,
  tone/dialog/subwoofer, ECO/dimmer/auto-standby, and Zone 2 detail via a
  single batched AppCommand POST plus one pipelined telnet session per refresh.
  Optional `--tv` panel via the lgtv CLI when present. The original
  `denon dashboard` is unchanged.
- Fix the AppCommand probe request in `denon data capabilities --probe-safe`
  to include the XML declaration and trailing newline the firmware requires;
  read-only Get* verbs now report real results instead of "malformed".

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.10.beta7
- Show the running controller version in the dashboard footer (interactive and
  non-interactive watch modes); remove the Tool: line from the Receiver Info card

* Mon Jun 01 2026 Tiffany Von Arnim <tiffany.vonarnim@gmail.com> - 1.2.0-0.9.beta6
- Show the running controller version in the dashboard (shell and dashboard-alt)
- Correct the embedded controller version string to 1.2.0-beta.6
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
