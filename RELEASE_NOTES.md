# Release Notes

## v1.2.0-beta.8

Dashboard-ultra and v2 transport follow-up.

### Dashboard-ultra

- `dashboard-ultra` is documented as an alternate ultrawide shell dashboard:
  five top-row panels at 200+ columns, 3+2 panels at 120-199 columns, stacked
  output below 120 columns, and an optional `--tv` panel through the local
  `lgtv` CLI.
- Fixed the live AVR-X1600H AppCommand failure mode by splitting the previous
  12-verb POST into three four-verb POSTs. Validation found that five or fewer
  verbs per AppCommand POST are safe, six returns `<error>1</error>`, and seven
  or more can wedge the receiver's `:8080` goform daemon for about 51 seconds.
- Added stable-dashboard fallback for core zone fields when the first/core
  AppCommand batch fails, using the existing `_denon_info` / `get_config` /
  volume XML path.
- Restored the interactive keybindings in `dashboard-ultra`: volume, previous /
  next, play/pause, mute, source-number selection, zone toggle, and quit.
  The ultra watch loop now uses the shared sleep/key-poll helper so `Q` is
  still polled when collection consumes the whole interval.
- The TV panel now uses `lgtv audio status` first and maps webOS output codes
  such as `tv_speaker` and `external_arc` to readable labels.

### v2 Runtime Layout

- Added the v2 Bash library layer: `lib/config.sh`, `lib/protocol.sh`,
  `lib/transport.sh`, and `lib/compat.sh`.
- `denon.sh` sources those libraries from a checkout-local `lib/` directory
  first, then from the packaged `/usr/share/denon/lib/` runtime directory.
- The RPM release is `0.13.beta8` and installs the v2 libraries under
  `/usr/share/denon/lib/`, while Python helpers remain under
  `/usr/libexec/denon-avr-controller/`.
- Added the `bin/denon` checkout wrapper and expanded `raw` completions for
  `get`, `set`, `dump`, and `types`.

### Validation

- The Fable/Claude debug pass reported 354/354 tests passing after the
  dashboard-ultra fixes, plus live AVR-X1600H one-shot/watch validation with no
  Unknown frames and no repeated `:8080` daemon wedge.

## v1.2.0-beta.7

Small follow-up to beta.6 that places the running controller version where it
belongs in the dashboard.

### Dashboard

- The running `denon-avr-controller v<version>` is now shown in the dashboard
  **footer** in both the interactive (keyboard-active) and non-interactive watch
  modes. In the interactive footer it is right-aligned on the `Control Target:`
  line.
- Removed the short-lived `Tool:` line from the Receiver Info card. That card's
  `Version:` field remains the AVR mainboard firmware, which the receiver does
  not expose on read-only surfaces (shown as `Unknown` on AVR-X1600H).
- `dashboard-alt` continues to show the version in its top header alongside the
  key help.

## v1.2.0-beta.6

Follow-up beta focused on interactive dashboard controls, truthful HEOS
transport feedback, and receiver-validation hardening.

### Interactive Dashboard

- Added keyboard controls to the main `dashboard` and to `dashboard-alt`:
  arrow-key volume, `Space` play/pause, `←`/`→` previous/next, `M` mute,
  source-number selection from the Sources list (including multi-digit source
  numbers), and `Z` zone toggle.
- Transport keys now route through the HEOS helper and verify the selected
  player's state/metadata before reporting success. Recent Events distinguish
  `sent`, `verified`, `failed`, `no playback change verified`, and `throttled`
  outcomes instead of overstating dispatch as success.
- Standardized full and compact footer hints on a single `key=action` grammar.
- Receiver Info renders `Receiver`, `IP`, `Version`, and `HEOS` consistently,
  using `Unknown` instead of blanks and never showing HEOS firmware as AVR
  firmware.

### Security And Hardening

- Zone 2 volume now honors the `DENON_MAX_VOLUME_DB` hearing-safety cap and the
  supported raw range for `zone2 vol`, `zone2 up`, and `zone2 down`, matching
  Main Zone behavior.
- `set_config` write paths now require a real `2xx` HTTP status to report
  success (an empty status is no longer treated as success).
- Cached receiver IPs are validated as IPv4 before use in discovery and
  `doctor` output; invalid cache entries are ignored.

### Packaging

- The RPM installs `denon_dashboard_alt.py` and `denon_heos_helper.py` under
  `%{_libexecdir}/denon-avr-controller/`; `denon.sh` resolves helpers via an
  explicit env var, its own directory, then the installed libexec path.

## v1.2.0-beta.5

Follow-up beta after the PowerShell parity work, focused on PowerShell TLS
correctness and test/analyzer hardening.

### PowerShell TLS

- Replaced the PowerShell certificate-validation scriptblock (which could not
  run on the .NET TLS handshake thread, so `DENON_CURL_CACERT` and
  `DENON_CURL_PINNEDPUBKEY` requests failed) with a compiled
  `DenonAvrController.PowerShell.TlsValidator` delegate. Per-request custom CA
  and `sha256//` public-key pinning now work on PowerShell 7.

### Testing And Quality

- Added Pester coverage that exercises the PowerShell TLS path against a
  transient local self-signed HTTPS server (correct pin succeeds, wrong pin
  fails, custom CA succeeds).
- Enabled PowerShell analyzer validation and cleaned actionable warnings.

## v1.2.0-beta.4

This beta prepares the Denon AVR Controller for release after the completion
installer, hardening, portability, reliability, performance, TLS, and
release-readiness cleanup passes.

### PowerShell Parity

- Expanded the native PowerShell 7+ module to cover the Bash command surface
  where practical, including raw/data helpers, config/profile/cache behavior,
  source aliases, snapshots, presets, sleep/Quick Select, sound mode,
  Audyssey/tone controls, transport commands, data discovery, watch-event style
  polling, and HEOS helper integration.
- Added `Invoke-DenonCommand` as a Bash-style migration shim and
  `Get-DenonCompletionCommandSurface` / `Register-DenonArgumentCompleter` for
  PowerShell completion metadata.
- Added a no-dependency PowerShell validation script alongside the existing
  Pester tests so module parity can be checked without a live receiver.

### Shell Completion Installer

- Added `denon completion install` for per-user completion installation.
- Added completion generation commands for bash, zsh, and fish:
  `denon completion bash`, `denon completion zsh`, and `denon completion fish`.
- Documented the user-level completion targets:
  `~/.local/share/bash-completion/completions/denon`,
  `~/.local/share/zsh/site-functions/_denon`, and
  `~/.config/fish/completions/denon.fish`.

### Security And Hardening

- Validated HEOS player IDs before constructing any `pid=...` command,
  accepting only signed decimal IDs and rejecting separators or command
  injection strings.
- Removed unsafe inline Python source interpolation for HEOS volume lookup.
- Made `set_config` write paths return failure on rejected or non-2xx HTTP
  responses.
- Made AVR HTTPS/TLS behavior explicit and configurable while preserving the
  default receiver-compatible mode:
  `DENON_CURL_INSECURE`, `DENON_CURL_CACERT`, and
  `DENON_CURL_PINNEDPUBKEY`.

### Reliability And Accuracy

- Prefer known XML mute state and query telnet mute only as a fallback.
- Classify AppCommand probe responses more accurately as valid, empty,
  malformed, or curl errors.
- Display Zone 2 volume in dB in text `denon info` output when raw volume is
  known.

### Portability And Cleanup

- Clarified that the runtime is bash; zsh and fish support is completion-only.
- Replaced GNU-specific XML tag splitting and timestamp paths with portable
  helpers.
- Added a safer dynamic file-descriptor close helper.

### Performance

- Replaced the hot lowercase helper with bash-native parameter expansion.
- Use an `nc -q` telnet query path when the installed netcat supports it, with
  the previous bounded sleep fallback retained.
- Reduced `data discover` throttling after empty responses or immediate failed
  type fetches while keeping sequential discovery behavior.

### Documentation And Tests

- Updated README, man page, architecture notes, release plan, and packaging
  metadata for the hardening passes.
- Expanded offline regression coverage for completion install behavior, HEOS PID
  validation, write failure detection, portability helpers, AppCommand probe
  classification, TLS configuration, and release-readiness documentation.
