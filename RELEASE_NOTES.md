# Release Notes

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
