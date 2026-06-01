# Release Notes

## v1.2.0-beta.4

This beta prepares the Denon AVR Controller for release after the completion
installer, hardening, portability, reliability, performance, TLS, and
release-readiness cleanup passes.

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
