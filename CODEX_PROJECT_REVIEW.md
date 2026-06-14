# Codex Project Review - 2026-06-10

## Scope

Reviewed the current `v2-impl` branch at `554d0ad` against `85e8e26^`, which covers:

- `85e8e26 feat(v2): add transport/protocol/config/compat layer and wire avr_send into core`
- `e849fce fix(dashboard-ultra): resolve Unknown fields, dead quit key, and missing keybindings`
- `554d0ad chore(rpm): bump release to 0.13.beta8, install v2 lib/ scripts`

The prompt's dashboard-ultra hash was corrected from `85e8e26` to `e849fce` after checking `git log`. I also read `/home/administrator/organized_projects/denon/debug-log-20260610_105138.txt` and ignored untracked generated artifact directories (`dist/`, `rpmbuild-review-*/`) as requested.

## Findings

| Severity | File:line | Issue | Recommendation |
|---|---:|---|---|
| Medium | `lib/protocol.sh:91` | HTTP fallback synthesizes `MV?` replies by stripping the sign from StatusLite `MasterVolume` (`-37.5` becomes `MV37.5`). Telnet `MV?` replies are raw absolute scale (`MV375` for `-42.5 dB` style values depending on receiver scale), so callers using `denon raw MV? --http` can receive a plausible but wrong telnet-shaped value. | Either stop synthesizing `MV?`/`Z2?` volume replies from StatusLite and return rc 2, or convert dB to raw with the centralized volume math before emitting telnet-shaped output. Add Bats coverage with a negative dB StatusLite fixture. |
| Low | `lib/protocol.sh:36` | `zone_cmd vol` accepts zero-padded decimal input but passes it directly to `printf '%02d'`. In Bash `printf`, values like `075` are parsed as octal, producing `MV61`. This is dormant scaffolding today, but it is a footgun for future callers. | Normalize with base-10 arithmetic before formatting, for example `value=$((10#$value))`, then `printf '%02d'`. Add a regression for `zone_cmd 1 vol 075`. |
| Low | `lib/transport.sh:52` | `_avr_telnet_oneshot` assumes `ncat` exists. The RPM now requires `nmap-ncat`, but checkout/runtime users without `ncat` get an implicit command-not-found path that falls through to HTTP. That is bounded, but the behavior is silent and can make Telnet-only commands look unavailable. | Add an explicit `command -v ncat >/dev/null` guard that returns the existing unreachable/fallback code path with an optional debug message. Document `ncat` as a runtime dependency for v2 transport. |

No high-confidence exploitable security regression was found in the reviewed changes. Raw protocol input is gated by `protocol_valid_cmd` before the v2 transport path, JSON config writes are validated through `jq`, and dashboard-ultra uses plain HTTP only for the receiver's local goform/AppCommand endpoints.

## Notes From Debug Log

- The live AVR-X1600H AppCommand limit is now reflected in code comments and docs: five or fewer verbs per POST are safe, six returns `<error>1</error>`, and seven or more can wedge `:8080` for about 51 seconds.
- `dashboard-ultra` now splits its 12 verbs into three four-verb batches and pads failed batches to preserve positional parser alignment (`denon.sh:6916`).
- If the first/core AppCommand batch fails, the ultra dashboard falls back to the stable dashboard's core status path (`denon.sh:6947`, `denon.sh:6815`).
- Interactive keyboard handling is delegated to the shared dashboard key handler and shared sleep/key-poll loop, including the slow-collect case where the remaining sleep time is zero (`denon.sh:7323`, `denon.sh:7453`).

## Documentation Updates Made

- `README.md`: updated version to beta.8, added `dashboard-ultra` behavior, AppCommand batching limit/fallback details, restored keybindings, v2 runtime layout, and raw `dump/types` examples.
- `RELEASE_NOTES.md`: added `v1.2.0-beta.8` notes for dashboard-ultra fixes, v2 library layout, RPM release/runtime paths, and current validation.
- `ARCHITECTURE.md`: updated project shape, protocol strategy, v2 `avr_send` routing, AppCommand batching limit, dependency guardrail, RPM runtime layout, and dashboard surface responsibilities.
- `PROJECT_SUMMARY.md`: updated branch/status, v2 library/dashboard-ultra summary, runtime dependencies, and validation warnings.
- `man/denon.1`: bumped version, added `dashboard-ultra`, raw `dump/types`, and packaged helper/library paths.

## Validation

- `git diff --check` - passed.
- `groff -man -Tascii man/denon.1 >/tmp/denon-man.txt` - passed after replacing non-portable manpage arrow escapes with `Up/Down` and `Left/Right`.
- Fixed-string documentation sanity checks - passed:
  - no remaining `\(ua` manpage escapes in edited docs/manpage surfaces.
  - no remaining `1.2.0-beta.5` stale version string in the edited top-level docs/manpage/review surfaces.
  - `dashboard-ultra` references are present in README, release notes, architecture, project summary, man page, and this review report.

I did not run `./test/run` or `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q` because this pass changed documentation/review files only.

## Unresolved Risks

- The AppCommand batch limit was validated on AVR-X1600H. Other Denon/Marantz models may differ, so keeping batches at four verbs is a conservative default, not a universal firmware proof.
- The v2 HTTP volume synthesis bug is not currently fixed in this docs-only pass.
- The v2 library layer adds Bats coverage and a large vendored `test/vendor/bats-core/` tree; dependency provenance and future update policy should be reviewed before release publication.
