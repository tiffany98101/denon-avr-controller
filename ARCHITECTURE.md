# ARCHITECTURE.md — `denon-avr-controller`

> **Status:** Living document. Reflects the codebase as of `denon.sh` v1.2.0-beta.3 (~6,473 lines), `denon_heos_helper.py`, `denon_mpris.py`, the systemd user unit, and the Makefile-driven packaging workflow.
> **Audience:** Maintainer (you) and any future contributor or AI agent proposing changes. Every PR must be evaluated against this document. If a change conflicts with the rules here, *this document must be updated first* — never silently violated.
> **Revision note:** This is v2. The v1 baseline (committed `6dcc504`) was written against the GitHub public state, which lagged the working tree substantially. v2 reconciles the doc to the local truth. Sections that were wrong or obsolete in v1 are marked **[v1 superseded]** with the corrected understanding.

---

## 1. What this project is (and what it is not)

`denon-avr-controller` is an **operator's CLI plus a sanctioned optional desktop bridge** for a Denon AVR sitting on a trusted home LAN. It wraps the receiver's three native control surfaces — the HTTPS XML config API, the legacy Telnet ASCII protocol, and the HEOS JSON-over-TCP protocol — behind a bash runtime script and a single sourced Bash function called `denon`. A separate Python MPRIS2 daemon (`denon-mpris`) optionally bridges the receiver to the user's desktop session over D-Bus.

It is **not**:
- A daemon for the AVR's full state machine. The MPRIS bridge is narrow (media-key control + Now Playing surface), not a general control daemon.
- A home-automation hub. There's no MQTT, no Home Assistant integration, no rules engine. `watch-event` is a poll-and-fork primitive, deliberately minimal.
- A general-purpose AVR library. It is tuned to a **Denon AVR-X1600H** and the XML grammar that specific model emits.
- A hardened remote-management tool. It assumes a trusted LAN and uses `curl -k` against self-signed certificates.

It is a **terminal-native primitive** with a **packaged Fedora distribution path** — designed to compose into shell pipelines and personal scene scripts (`spotify-dj`, `lgtv`), and to be installable as a real user-space service via `make install-mpris` or a COPR-built RPM.

---

## 2. Repository Shape

```
denon_main/
├── denon.sh                     # Primary CLI, ~6,473 lines, sourceable
├── denon_heos_helper.py         # Python sidecar for HEOS JSON protocol
├── denon_mpris.py               # MPRIS2 D-Bus bridge (installed as denon-mpris)
├── denon-mpris.service          # User-scope systemd unit
├── denon_automated_test.sh      # Bash-level integration tests
├── tests/                       # pytest-based unit tests (use DENON_UNIT_TEST=1)
├── completions/                 # Shell completions (bash + zsh + fish)
├── man/                         # Man pages
├── docs/                        # Long-form documentation
├── scripts/                     # Build / dev helpers
├── rpm/                         # RPM spec + packaging for COPR
├── powershell/                  # Windows companion (out of scope here)
├── references/                  # Captured XML fixtures, protocol notes
├── local-live-runs/             # Runtime captures
├── Makefile                     # install-mpris, uninstall-mpris, srpm, tag
├── VERSION                      # Single source of truth for release version
├── README.md
├── ARCHITECTURE.md              # This file
└── LICENSE                      # MIT
```

The public `github.com/tiffany98101/denon-avr-controller` mirror currently lags this layout. Sync drift between the local working tree and the public remote is itself a maintenance concern — see §7.11.

---

## 3. Design Philosophy

### 3.1 Why XML snapshotting

The Denon receiver exposes its full state machine through `https://<ip>:10443/ajax/globals/get_config?type=N`, where each `type` (3 = identity, 4 = power, 7 = sources, 12 = volume, etc.) returns a self-contained XML document. **The receiver is its own state store.** This project never duplicates AVR state into a local cache, a database, or a long-lived process — with two narrow, deliberate exceptions (the IP cache in §4.3 and the MPRIS daemon in §6.1).

This shapes the design in three ways:

1. **Reads are authoritative.** Every status command re-fetches the XML. There is no "last known volume" drift. If the user picks up the IR remote and changes the source, `denon status` reflects it immediately.
2. **Writes are XML-symmetric.** `set_config` accepts XML payloads structurally similar to what `get_config` returns. This lets us round-trip with minimal transformation and makes the raw escape hatch (`denon raw set 12 '<MainZone>…</MainZone>'`) useful for debugging.
3. **Snapshots are model-truth dumps.** `denon snapshot` writes raw XML responses to a timestamped directory. These are reproducible captures of receiver state at a moment in time — invaluable for diffing firmware behavior (`denon diff <snap-a> <snap-b>`), filing bug reports, or replaying a scene by hand.

The cost is fragility: extraction is done by anchored `sed` expressions, not a real XML parser. This is an intentional tradeoff — see §7.2 for the limits.

### 3.2 Why JSON output

XML is forced on the input side (it's the device's wire format). JSON is chosen on the output side because **the downstream consumer is the shell**.

- Default human output is pretty-printed text for interactive use.
- `--json` is opt-in and produces clean, jq-pipeable JSON (`denon status --json | jq -r .source`).
- The two formats are deliberately separate. Pretty output can change cosmetically; JSON is treated as a structural contract.

The `data` family (§6.4) extends this: `data dump --json`, `data discover --json`, `data capabilities --json`, `data summary --json` all emit structured documents intended for tooling consumption.

### 3.3 Why terminal-native speed is the priority

Realistic invocation profile: the user types `denon vol -35` or a scene script fires `denon source heos && denon vol -28 && denon mode music` ten times an hour. Every command must feel **instant**.

Concrete consequences:

- **Bash, not Python**, for the primary control plane. Bash process startup is ~5 ms; Python is ~50 ms.
- **Sourceable single file.** `source denon.sh` from bash makes `denon` behave like a shell builtin. No `$PATH` lookup, no interpreter spawn.
- **TTL-bounded IP cache** at `~/.cache/denon_ip` when unprofiled, or `~/.cache/denon_ip.<profile>` when `DENON_PROFILE` is active (default 1 hour via `DENON_CACHE_TTL_SECONDS`). Discovery runs at most once per hour on the steady-state path.
- **Bounded timeouts everywhere.** `DENON_CURL_CONNECT_TIMEOUT=2`, `DENON_CURL_MAX_TIME=4`, `DENON_SSDP_TIMEOUT=2`. No command can hang on a dead receiver.
- **Lazy Python.** The HEOS helper is only invoked for queue/group/browse/search — commands the Telnet sideband cannot express. Basic transport (`heos play`, `heos pause`) uses Telnet codes (NS9A/B/C/D/E) and does not pay the Python startup cost.
- **The MPRIS bridge is its own process.** It does not slow down `denon` invocations. They share a discovery cache; they do not share an interpreter.

---

## 4. Logic Patterns (How to Stay Consistent)

These are the patterns the existing code follows. New features must mirror them.

### 4.1 Three-Plane Protocol Strategy

The codebase uses three protocols, picked by capability and cost in this strict order of preference:

| Protocol | Port | Purpose | When to use |
|---|---|---|---|
| **HTTPS XML config API** | 10443 | Durable, queryable state | Always preferred for read/write of `Power`, `Volume`, `Mute`, `Source`, identity. |
| **Telnet ASCII** | 23 | Ephemeral, fire-and-forget | Sleep timer, sound mode (`MSSTEREO`), Audyssey (`PSDYNVOL`), tone control (`PSBAS`/`PSTRE`), Quick Select (`QUICK1 MEMORY`), HEOS transport (`NS9A`/`B`/`C`/`D`/`E`). |
| **HEOS JSON-over-TCP** | 1255 (via Python helper) | Stateful HEOS queries | Queue, groups, browse, search, play-stream. Anything that requires a session or returns structured data. |

**Rule for new commands:** if the XML config API can express it, use the XML API. Fall back to Telnet only when no `type=N` endpoint exposes the field. Fall back to the HEOS helper only when neither does.

### 4.2 Set-then-Verify Sync

State-changing commands do **not** trust the AVR's immediate response. The pattern is:

1. Issue the change (`_denon_set_config` or `_denon_telnet`).
2. Poll the relevant read endpoint until the value matches expectation, or until a bounded attempt count is exhausted.
3. On success, print confirmation. On drift, emit a warning to stderr including the actual value.

The canonical implementation is `_denon_wait_for_source`: up to 20 polls at 250 ms intervals (5 s total ceiling). The same shape appears in `_denon_set_volume_db`. The new `_denon_fade_volume` extends this to multi-step writes: each individual step still goes through verified `_denon_set_volume_db`.

**All future write commands must use this pattern by default.** A "set and pray" command is a bug unless the caller explicitly passes `--no-verify`, which is reserved for batch operations that intentionally trade immediate readback confirmation for lower race exposure and latency. Unverified writes must mark pretty output with `(unverified)` and JSON output with `"verified": false`.

### 4.3 Discovery Fallback Cascade (revised)

`_denon_discover` walks a fixed, ordered cascade. Each tier is cheap and bounded; the cache makes the steady-state cost effectively zero:

1. `$DENON_IP` (if set) — probed, never blindly trusted.
2. The active cache path — `~/.cache/denon_ip` when unprofiled, or `~/.cache/denon_ip.<profile>` when `DENON_PROFILE` is active — probed for liveness, **only if mtime is within `DENON_CACHE_TTL_SECONDS` (default 3600s)**.
3. `$DENON_DEFAULT_IP` — probed for liveness.
4. **Avahi / mDNS** via `_denon_avahi_candidates` — fast, multicast-DNS, more reliable than SSDP on segmented networks. **[v1 omission: this tier did not exist when v1 was written.]**
5. SSDP multicast (M-SEARCH for `MediaRenderer:1`).
6. ARP / `ip neigh` / `/proc/net/arp` known-host scan.
7. `$DENON_SCAN_LAN=1` opt-in full `/24` sweep (off by default — slow and noisy).

Every candidate is gated through `_denon_is_receiver`, which fetches `type=3` and greps for the literal `Denon`. A stale ARP entry for a printer never causes a false positive.

The cache TTL is the architecture's answer to DHCP drift. Before it existed, a stale cache file from yesterday could mask a real DHCP renewal. With the TTL, the active cache path self-invalidates and the discovery cascade reruns. **Rule:** any future discovery-layer change must respect the TTL gate — never read the cache unconditionally.

### 4.4 Layered Configuration (new in v2)

There are now **four** configuration tiers, evaluated in this precedence (highest first):

1. **Environment variables** — `DENON_IP=...` on the command line wins.
2. **Active profile** — if `DENON_PROFILE=livingroom` is set, `~/.config/denon/profiles/livingroom` is loaded as an env overlay.
3. **Default config file** — `~/.config/denon/config` (or `$DENON_CONFIG`), loaded once at script entry.
4. **Built-in defaults** — the values inline in the script.

Both config and profiles use the same `KEY=VALUE` format with **whitelisted keys only** (`_denon_load_config` enforces this; unknown keys are silently dropped). Values are exported **only if the env var is not already set** — env wins over file, always.

This is the architecture's multi-AVR answer (compare v1 §5.1, which speculated about `denon @livingroom` ambient syntax — that's **[v1 superseded]**). The current design is:

```
DENON_PROFILE=livingroom denon status   # talks to the living-room AVR
DENON_PROFILE=den       denon status    # talks to the den AVR
```

Profiles store the per-receiver `DENON_IP` (and any other settings that differ per device). One sourced script handles arbitrarily many receivers. The discovery cache is profile-scoped when `DENON_PROFILE` is active and remains unscoped (`~/.cache/denon_ip`) when no profile is active.

**Rule for new config-touching features:** add the key to *both* whitelists in `_denon_load_config` and `_denon_profile_cmd` if it should be config-storable. Otherwise it remains env-only. Never read raw config keys without going through `_denon_load_config`.

### 4.5 Local Aliases vs. Device Truth

Source renames are stored in a tab-separated file at `${DENON_SOURCE_ALIASES:-~/.config/denon/source_aliases}` with the schema `zone<TAB>index<TAB>display_name`. The AVR's own source labels are never mutated.

This is a deliberate architectural separation: **the device owns its factory state; the user owns the presentation layer.** Wiping the alias file is a non-destructive reset.

Any future "preference" or "user-defined name" feature must follow this pattern: store it locally, layer it over the device read, never write it to the AVR.

### 4.6 HEOS Helper Boundary

The Bash script handles HEOS transport via Telnet (`NS9A`–`NS9E` for play/pause/stop/next/prev) — enough for 80% of HEOS use. Anything that needs the HEOS JSON protocol (queue manipulation, group management, content browsing, search, direct stream playback) shells out to `denon_heos_helper.py`.

The boundary is **capability**, not convenience. A new HEOS feature belongs in the Python helper only if:
- It requires reading structured data back (queue contents, group topology, browse results).
- It requires session state (HEOS `register_for_change_events`, paginated browse).
- It depends on a HEOS protocol field not exposed in the Telnet sideband.

Otherwise, prefer Telnet. Every Python call adds ~50 ms of interpreter startup.

**[v1 §5.3 superseded.]** The helper is committed locally. The drift between the local tree and the public GitHub mirror caused v1 to claim it was missing — that was true on the remote, false locally. See §7.11.

### 4.7 Output Discipline

- **stdout = data.** Pretty status, JSON, raw XML, snapshot paths.
- **stderr = diagnostics.** Errors, warnings, debug traces, "did you mean" hints.
- **`DENON_DEBUG=1`** routes through `_denon_debug` (stderr only).
- **`--json` is structural, not cosmetic.** Field names are a contract. Renaming a JSON key is a breaking change.
- **Global flags (new).** `--quiet`/`-q` suppresses stdout; `--silent` suppresses both stdout and stderr; `--no-verify` skips set-then-verify polling for write commands. These compose with commands before or after the subcommand. New commands must honor them — wire through the same flag-strip helper, don't re-implement.

### 4.8 Volume Encoding

Denon raw volume is `(dB + 80) × 10`, clamped to `[0, 980]`. Centralized in `_denon_raw_to_db` and `_denon_db_to_raw`. **Do not inline this math anywhere else.** If the encoding ever changes (different model, different firmware), it changes in exactly two places.

The safety ceiling `DENON_MAX_VOLUME_DB` (default `-10`) is checked in `_denon_apply_volume_limit`. The fade command (`vol --fade`) routes every intermediate step through `_denon_set_volume_db`, so the ceiling enforces correctly even mid-fade. Any new write path that touches volume must do the same.

### 4.9 Snapshot Format as Stable Contract (elevated in v2)

`denon snapshot` writes raw XML responses to a timestamped directory. `denon diff` compares two snapshot directories field-by-field. The diff command makes the snapshot directory layout itself a **stable contract**:

- File names within a snapshot (e.g., `power.xml`, `volume.xml`, `source.xml`) must remain consistent across versions, or all historical diffs break.
- New files may be added to snapshots; existing files must not be renamed or restructured without a versioned migration.
- A snapshot taken with v1.2.0 must diff cleanly against one taken with v1.3.0, except for genuinely changed receiver state.

This was implicit in v1 ("snapshots are model-truth dumps"). With `diff` shipping, it's explicit: **the snapshot layout is part of the public API**.

### 4.10 Event Reactor (`watch-event`) — Bounded Long-Running

`denon watch-event <condition> <command>` polls the AVR at a configurable interval (default 5s, condition like `source=tv` / `vol<-30` / `power=on`) and, when the condition is met, runs the user-supplied command via `bash -c`. With `--once`, the watcher exits after the first trigger; with `--timeout`, it exits unsatisfied after N seconds.

This is the script's first sanctioned long-running construct. It bends — but does not break — guardrail §5.6 (stateless, no persistent state):

- It holds **no persistent state**; the AVR is still the only state store.
- It performs the same reads any one-shot status call would perform; nothing new on the AVR side.
- It is invoked **by the user**, in the foreground (or backgrounded by the user), not as a system service.

**Rule:** any new long-running primitive in the script must meet those three properties. If it needs persistent state, it does not belong in `denon.sh` — it belongs in a separate daemon (see §6.1 for the existing one).

### 4.11 Test Mode via Nested-Function Promotion (new in v2; supersedes v1 §5.4)

**[v1 §5.4 superseded.]** v1 flagged "function-redefinition inside `denon()`" as technical debt that blocked unit testing. The current code resolves this **without flattening** by exploiting a Bash language feature: when a function containing nested function definitions is executed, the nested definitions are promoted to global scope.

The script's tail end:

```bash
if [[ -n "${DENON_UNIT_TEST:-}" ]]; then
  denon >/dev/null 2>&1 || true
fi
```

Sourcing the script with `DENON_UNIT_TEST=1` runs `denon` once with no args. The help branch fires (no network I/O). On the way out, every `_denon_*` helper is now defined at global scope and callable directly from pytest. The `tests/` directory uses this entry point.

This turns what looked like a debt into a deliberate test seam. **Rule:** new nested helpers must remain defined inside `denon()` (not split out to top level) so the promotion trick continues to work. The two intentional top-level exceptions are `_denon_lower` (called from the help-branch path before `denon()` runs) and `_denon_completion` / `_denon_is_sourced` (which must be callable in shell startup contexts where `denon()` has not yet been invoked).

The redefinition cost per call (a few hundred microseconds in Bash) is the price paid for the test seam. It is well below human perception and well below network latency, so it's invisible at the user level.

---

## 5. Guardrails (Non-Negotiables)

These are hard constraints. A change that violates one is, by definition, not in scope for this project — it's a different project.

1. **Single-file, sourceable from bash.** The script must work as both `./denon.sh status` and `source ./denon.sh && denon status` under bash. No multi-file Bash packaging. No build step for the script itself.
2. **Bash runtime, not POSIX `sh` or native zsh/fish.** Bash 4+ idioms (`[[ ]]`, `${var,,}`, arrays, dynamic file descriptors) are allowed and used. The project ships bash, zsh, and fish completion files, but completion support does not make `denon.sh` a zsh/fish runtime script.
3. **No heavy dependencies for the script.** Required: `bash`, `curl`, `awk`, `sed`, `grep`, `ip`, `nc`. Optional: `jq`, `shellcheck`, `avahi-utils` (for the mDNS tier of discovery), `python3` (for HEOS helper and MPRIS bridge). Adding any other required dependency to the script requires explicit justification in this document.
4. **Pipeable.** stdout is parseable. The default human output is line-oriented. `--json` produces a single JSON document. No prompts, no spinners, no curses TUIs on the primary commands. `dashboard --watch` is the sanctioned exception, and it must remain optional.
5. **Bounded timeouts on every network call.** No command can hang. All `curl` and `nc` calls go through `_denon_curl` or `_denon_telnet`/`_denon_telnet_query`, which apply timeouts from environment variables with safe defaults.
6. **Stateless script invocations.** No PID files. No long-lived sockets *inside `denon.sh`*. The script must be safe to invoke 100 times in a row from a scene script. `watch-event` is the bounded foreground exception (§4.10); the MPRIS daemon is the separate-process exception (§6.1); and `DENON_LOCK=1` is the narrow opt-in lock-file exception for serializing writes via `flock` on the active IP cache path.
7. **AVR-X1600H XML grammar is the reference.** The current `sed` extractors assume the structure this model emits. Supporting another model is allowed but must be additive — never break the X1600H path.
8. **Verify after every write.** No "set and pray" by default. See §4.2. Fade verifies per step, not just at the end. The documented opt-out is `--no-verify`, which still issues the write but skips readback polling and marks output as unverified.
9. **Trusted LAN only.** `curl -k` is used because the receiver presents a self-signed cert. Telnet has no auth. Do not market or extend this tool as suitable for hostile networks.
10. **Volume ceiling on by default.** `DENON_MAX_VOLUME_DB=-10` ships as the default. The user must opt out, never in. The ceiling applies to fades, to scene scripts, to raw `set` paths that touch volume — everywhere, no exceptions.
11. **stderr for warnings, exit codes for errors.** Every command returns a meaningful exit code. Scene scripts depend on `&&` chaining working correctly. `--quiet` suppresses stdout but **does not change exit codes**.
12. **No telemetry. No outbound network calls outside the LAN.** The tool reaches `$IP` (the receiver), `239.255.255.250` (SSDP multicast), `224.0.0.251` (mDNS multicast), and nothing else. Ever.
13. **Whitelisted config keys.** Anything stored in `~/.config/denon/config` or a profile must appear in the `_denon_load_config` whitelist. Arbitrary key=value pairs are silently ignored. This prevents profile files from exporting unrelated env vars into the user's shell.
14. **Sensitive-data disclosure on `data` commands.** `data dump`, `data discover`, and `data capabilities` may surface serial numbers, MAC addresses, account identifiers, and other receiver-resident PII. The help text says so. New `data` subcommands that touch new endpoints must continue to flag this — both in the help text and in any JSON output that contains such fields.
15. **The promotion trick is load-bearing.** All `_denon_*` helpers stay nested inside `denon()` so `DENON_UNIT_TEST=1` works. The two top-level exceptions (`_denon_lower`, `_denon_completion`, `_denon_is_sourced`) are listed in §4.11. Adding a third requires updating that section.

---

## 6. Sanctioned Companion Components

These are out of `denon.sh` proper but are part of the project's architecture. Each is opt-in.

### 6.1 MPRIS Bridge (`denon_mpris.py` → `denon-mpris`)

Long-running Python daemon, installed by `make install-mpris` as `~/.local/bin/denon-mpris`, managed by the user systemd unit `denon-mpris.service`. Bound to `graphical-session.target` — runs in the user's desktop session, not at boot.

**Purpose:** expose the AVR as an MPRIS2 D-Bus media player so the desktop environment's media keys, the lock-screen widget, and tools like `playerctl` can drive the AVR (play / pause / next / previous, current title/artist, volume) without going through the shell.

**Design constraints (these are guardrails for the daemon):**
- **Polling, not push.** The bridge polls the AVR on `DENON_MPRIS_POLL_INTERVAL` (configurable, default sensible). Reason: avoids depending on UPnP GENA event subscriptions, which are flaky across firmware revisions.
- **Self-reconnecting.** When the AVR goes to standby, the bridge must not crash or restart-storm. The unit file's `StartLimitIntervalSec=60` / `StartLimitBurst=5` is a *backstop*, not the primary recovery path — the daemon itself handles standby gracefully.
- **No state of its own.** D-Bus and the AVR are the two stores. The daemon is a translator.
- **Shares discovery with the script.** The daemon reads `~/.cache/denon_ip` and respects `DENON_IP`. It does not implement a parallel discovery cascade.
- **Honors the volume ceiling.** Setting volume via MPRIS goes through the same `DENON_MAX_VOLUME_DB` guard as the CLI.

The systemd unit lives at `~/.config/systemd/user/denon-mpris.service`. The user enables it once with `systemctl --user enable --now denon-mpris.service` (which `make install-mpris` does for them).

**This is the sanctioned exception to guardrail §5.6.** It exists because the desktop integration is genuinely valuable and cannot be provided by short-lived script invocations. Future long-running components must clear the same bar: short-lived shell calls genuinely can't do the job, *and* the component's state is held only in well-defined external systems (D-Bus here; the AVR everywhere).

### 6.2 HEOS Helper (`denon_heos_helper.py`)

Python sidecar invoked by `denon.sh` for HEOS protocol operations that can't be done over Telnet. Discoverable at `${DENON_HEOS_HELPER:-${script_dir}/denon_heos_helper.py}`. **Not** long-running — it's spawned per command and exits.

The interface contract: the Bash script passes structured arguments; the helper prints to stdout (text for human output, JSON for `--json` mode) and uses exit codes for errors. The script does not parse free-form Python error messages; the helper produces clean, parseable output.

### 6.3 Test Harness (`tests/` + `denon_automated_test.sh`)

Two complementary layers:

- `tests/` — **pytest unit tests** using the `DENON_UNIT_TEST=1` promotion trick (§4.11). Tests individual `_denon_*` helpers in isolation.
- `denon_automated_test.sh` — **integration tests** against a live receiver. Runs the script end-to-end. Has a `--destructive` flag for tests that change AVR state; must not be run while the receiver is in use.

Any new helper should ship with a pytest test. Any new top-level command should be covered by a non-destructive line in the integration script.

### 6.4 The `data` Family (introspection surface)

The `data` subcommands (`fields`, `dump`, `discover`, `capabilities`, `summary`) treat the AVR's read-only API as a *discoverable, inventoriable resource*:

- `data fields --all` — what fields the script knows about (regardless of presence).
- `data fields --available` — what fields the current AVR actually returns.
- `data dump --readable|--json|--raw` — pull all safe read-only endpoints, render.
- `data discover` — sweep `type=N` for `N` up to `DENON_DATA_DISCOVERY_MAX_TYPE` (default 30) to find endpoints the script doesn't know about.
- `data capabilities` — inventory Deviceinfo/AppCommand verbs from the AVR's advertised manifest; `--probe-safe` does opt-in live probes.
- `data summary` — concise diagnostics, JSON-formatted with `--json`.

This is the architectural surface for "what does this model expose?" — invaluable when adding support for a new firmware revision or a different Denon model.
The discovery sweep remains sequential and throttled after valid type responses, but it does not sleep after empty responses or failed type fetches.

### 6.5 Packaging (Makefile + `rpm/` + `VERSION`)

- `make install-mpris` — install daemon + user unit.
- `make uninstall-mpris` — clean removal.
- `make srpm` — build a source RPM for inspection or upload to COPR.
- `make tag` — create a signed git tag from `VERSION`, ready to push to trigger a Copr build.

`VERSION` is the single source of truth for release versioning. `DENON_CONTROLLER_VERSION` env var overrides it at runtime (useful for testing). The `version` / `--version` / `-V` command prints this.

The packaging story is **Fedora-first**. RPM via COPR is the supported distribution path. Other distros are not currently in scope — see §7.10.

---

## 7. Future-Proofing & Known Technical Debt

These are the places the current architecture will strain if pushed. Each entry is a future decision point — not a bug to fix today, but a known limit to design around.

### 7.1 ~~Per-profile IP cache~~

Completed on 2026-05-21. See §8 Decision Record: per-profile IP cache.

### 7.2 XML extraction fragility

The current pattern is `sed -n 's:.*<MainZone><Power>\([0-9]*\)</Power>.*:\1:p'`. This assumes:
- The element ordering Denon currently emits.
- No whitespace or newlines between adjacent tags.
- A specific model's XML grammar.

A firmware revision that re-orders elements, or another model that wraps `<MainZone>` differently, will silently produce empty extractions. Mitigation path, in order of cost:

- Centralize all extractors in one labeled block (`# XML accessors — AVR-X1600H grammar`) so model support is a single diff.
- Move from `sed` to `xmllint --xpath` gated behind `if command -v xmllint`, with `sed` as the fallback.
- Use `tests/fixtures/` captured-XML to assert known values — the test harness already supports this.

### 7.3 Multi-model support

The `data capabilities` family (§6.4) gives the script the ability to *introspect* a new model's surface. What's missing is the layer above: a way to load model-specific extractors based on the receiver identity returned by `type=3`. The natural shape is a `models/` directory of small Bash files, each defining the extractors and quirks for one model, loaded conditionally. Not needed until a second model is supported, but the entry point for that work is the identity probe.

### 7.4 Function-redefinition cost — accepted, not paid down

v1 flagged 80 nested helpers as debt; the current count is 242. The "promotion trick" (§4.11) means flattening is **off the table** — doing so would break the test seam. The cost is unmeasurable in practice (Bash parses these in microseconds) and the test-seam value is real. Keep the pattern.

### 7.5 No `set -e` / `set -o pipefail`

Errors inside pipelines can silently pass. Most commands handle this with explicit `|| return 1` and `[[ -n "$value" ]] || …` checks, but coverage is uneven. Retrofitting `set -euo pipefail` at the top of a 6,473-line script will surface latent bugs and is a non-trivial migration. New code should write as if those flags were on (explicit checks, no silent pipe failures), so the eventual flip is small.

### 7.6 Concurrent invocations

Two simultaneous `denon vol -30` calls race at the AVR. The AVR arbitrates (last write wins), but the verify step in the loser misleadingly reports drift. The MPRIS daemon plus an interactive shell plus a scene script can all hit the AVR at once — this is now a realistic three-way race, not a thought experiment.

Mitigations landed:
- `DENON_LOCK=1` opts write commands into `flock` serialization on the active IP cache path, using `DENON_LOCK_TIMEOUT` (default 3s) and exit code 75 on timeout. Reads remain lock-free.
- `--no-verify` lets batch operations issue writes without readback polling; pretty output is marked `(unverified)` and JSON output reports `"verified": false`.

Mitigations still pending:
- The MPRIS daemon should set `DENON_LOCK=1` in its environment before write operations so D-Bus volume changes serialize against CLI writes. The current daemon-side write point is `denon_mpris.py` `Volume.setter`; adding daemon-side debounce remains out of scope here.

If race-induced UI staleness remains noticeable after locking, the next step is MPRIS-side debounce: if the CLI just issued a volume change, skip the daemon's next poll.

### 7.7 Polling cost in scene scripts

A scene like "switch to HEOS, set volume, set sound mode" performs three verify loops in series — up to ~15 s worst case (usually <1 s actual). For batch operations, a **scene primitive** — `denon scene apply <file>` that issues all writes, then verifies the final state vector once — would compose cleanly with `spotify-dj`'s scene model. The `--no-verify` flag in §7.6 is a building block.

### 7.8 No native UPnP/HEOS event subscription

Both `watch-event` and the MPRIS daemon are polling-based. UPnP GENA on port 8080 and HEOS `register_for_change_events` would provide push semantics — lower latency, lower load.

The tradeoff: GENA event subscription requires a callback HTTP listener on the *client*, which means the script has to bind a port and the daemon has to handle session renewal. That's a non-trivial complexity bump for an MPRIS poll interval that's already low single-digit seconds. Defer until polling overhead is measurably a problem.

### 7.9 Snapshot portability across models

`denon snapshot` saves model-specific XML. It's not portable across receivers — restoring a snapshot from an X1600H to an X3800H would be ill-defined. With `denon diff` shipping, the snapshot directory layout is now a stable contract (§4.9). For a true "back up and restore" feature across receivers, a normalized JSON manifest extracted from the raw XML would sit alongside the dump. The raw XML stays as ground truth; `manifest.json` adds portable semantics.

### 7.10 Distribution beyond Fedora

The Makefile and `rpm/` directory target Fedora COPR. The script itself runs on any Linux. The MPRIS daemon depends on `dbus` Python bindings, which are packaged on every major distro but with different names (`python3-dbus` on Debian, `python-dbus` on Arch, etc.). A `make install-mpris-portable` that drops the systemd unit but uses `pip install --user dbus-python` would lower the friction for non-Fedora users. Not urgent; only matters when a non-Fedora user shows up.

### 7.11 Drift between local working tree and public mirror

This is the meta-issue that produced the v1→v2 reconciliation in the first place. The local tree is at v1.2.0-beta.3, ~6,500 lines, with the MPRIS daemon, test harness, RPM packaging, and `data` family. The public `github.com/tiffany98101/denon-avr-controller` mirror is materially older.

The drift is a project-management concern more than a code one, but it has architectural consequences: anyone reading the public repo gets a misleading picture of how the project is structured. **Recommended posture:** push to public on each tagged release (`make tag` → `git push --tags` → `git push`), not just when convenient. The COPR build pipeline already implicitly assumes this. Long drift periods like the current one make the public README and help text dishonest.

### 7.12 Integration envelope for sibling CLIs

`denon`, `lgtv`, and `spotify-dj` each invent their own JSON shape. A shared envelope — `{ "tool": "denon", "ts": "...", "command": "vol", "args": {...}, "result": {...} }` — would let scene scripts log uniformly and would make it trivial to replay sessions. Not a current requirement; mentioned as a coordination point the next time any of the three CLIs changes its JSON format.

### 7.13 The MPRIS daemon as a control-plane fork

`denon-mpris` is the first concurrent control-plane writer alongside the user's shell. Most of the time this is fine — both go through the same volume guard, both honor the same discovery cache. But the daemon's `DENON_MPRIS_POLL_INTERVAL` does introduce a fixed lag between an AVR state change and the daemon noticing it. If the user changes the source via IR remote at second `t`, MPRIS clients may show stale "Now Playing" data until `t + poll_interval`. Reducing the poll interval trades correctness for AVR load. The right long-term fix is event subscription (§7.8); the right short-term answer is honest user-facing documentation of the polling latency.

---

## 8. Decision Record

When making a change that touches any of the patterns or guardrails above, append an entry here. Format: date, summary, rationale, sections affected.

| Date | Change | Rationale | Sections |
|---|---|---|---|
| 2026-05-21 | v1 baseline committed (6dcc504) | Captured project-truth against public GitHub state | All (v1) |
| 2026-05-21 | v2 reconciliation | Local working tree had diverged: MPRIS daemon, layered config + profiles, Avahi discovery, cache TTL, `data` family, `watch-event`, fade volume, snapshot diff, pytest harness via promotion trick, RPM packaging. v2 captures actual reality. | All sections superseded; §4.4, §4.9, §4.10, §4.11, §6 new; v1 §5.1, §5.3, §5.4, §5.8 explicitly superseded |
| 2026-05-21 | Per-profile IP cache | `DENON_PROFILE=<name>` now scopes the discovery cache to `~/.cache/denon_ip.<name>` while unprofiled users continue to use `~/.cache/denon_ip`; the TTL gate, `setip`, `discover`, doctor, and data live target selection all use the active cache path. | §4.3, §4.4, §7.1 |
| 2026-05-21 | Write race mitigations | Added global `--no-verify` for batch writes and opt-in `DENON_LOCK=1` flock serialization for write commands; defaults remain unchanged, reads stay lock-free, and missing `flock` warns then proceeds unserialized. | §4.2, §4.7, §5.6, §5.8, §7.6 |

---

*End of document.*
