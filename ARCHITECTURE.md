# ARCHITECTURE.md — `denon-avr-controller`

> **Status:** Living document. Reflects the codebase as of `denon_release_candidate.sh` HEAD (~3,091 lines, single-file Bash).
> **Audience:** Maintainer (you) and any future contributor or AI agent proposing changes. Every PR must be evaluated against this document. If a change conflicts with the rules here, *this document must be updated first* — never silently violated.

---

## 1. What this project is (and what it is not)

`denon-avr-controller` is an **operator's CLI** for a Denon AVR sitting on a trusted home LAN. It wraps the receiver's three native control surfaces — the HTTPS XML config API, the legacy Telnet ASCII protocol, and the HEOS JSON-over-TCP protocol — behind a single sourced Bash function called `denon`.

It is **not**:
- A daemon, service, or long-running process.
- A home-automation hub (no event bus, no MQTT, no Home Assistant integration layer).
- A general-purpose AVR library. It is tuned to a **Denon AVR-X1600H** and the XML grammar that specific model emits.
- A hardened remote-management tool. It assumes a trusted LAN and uses `curl -k` against self-signed certificates.

It is a **terminal-native primitive** — designed to compose into shell pipelines and personal scene scripts (e.g., `spotify-dj`, `lgtv` integration), not to be a polished consumer app.

---

## 2. Design Philosophy

### 2.1 Why XML snapshotting

The Denon receiver exposes its full state machine through `https://<ip>:10443/ajax/globals/get_config?type=N`, where each `type` (3 = identity, 4 = power, 7 = sources, 12 = volume, etc.) returns a self-contained XML document. **The receiver is its own state store.** This project never duplicates AVR state into a local cache, a database, or a long-lived process.

This shapes the design in three ways:

1. **Reads are authoritative.** Every status command re-fetches the XML. There is no "last known volume" drift. If the user picks up the IR remote and changes the source, `denon status` reflects it immediately because the next read goes straight to the device.
2. **Writes are XML-symmetric.** `set_config` accepts XML payloads structurally similar to what `get_config` returns (`<MainZone><Volume>485</Volume></MainZone>`). This lets us round-trip with minimal transformation and makes the raw escape hatch (`denon raw set 12 '<MainZone>…</MainZone>'`) genuinely useful for debugging.
3. **Snapshots are model-truth dumps.** `denon snapshot` writes the raw XML responses to a timestamped directory. These are reproducible captures of receiver state at a moment in time — invaluable for diffing firmware behavior, filing bug reports, or replaying a scene by hand.

The cost is fragility: extraction is done by anchored `sed` expressions, not a real XML parser. This is an intentional tradeoff — see §5.2 for the limits of this approach.

### 2.2 Why JSON output

XML is forced on the input side (it's the device's wire format). JSON is chosen on the output side because **the downstream consumer is the shell**.

- Default human output is pretty-printed text for interactive use.
- `--json` is opt-in and produces clean, jq-pipeable JSON for automation (`denon status --json | jq -r .source`).
- The two formats are deliberately separate. The pretty form can change cosmetically without breaking scripts; the JSON form is treated as a structural contract.

This is the same divide that exists in `ip`, `kubectl`, `gh`, etc. The convention is well-established and downstream callers (your `spotify-dj` scene script in particular) depend on it.

### 2.3 Why terminal-native speed is the priority

The realistic invocation profile is: the user types `denon vol -35` or a scene script fires `denon source heos && denon vol -28 && denon mode music` ten times an hour. Every command must feel **instant**.

Concrete consequences:

- **Bash, not Python**, for the primary control plane. Bash process startup is ~5 ms; Python is ~50 ms. For a sourced function (no fork/exec at all) the difference is even larger.
- **Sourceable single file.** `source denon_release_candidate.sh` makes `denon` behave like a shell builtin. No `$PATH` lookup, no interpreter spawn.
- **IP caching at `~/.cache/denon_ip`.** Discovery runs once. Every subsequent call reads the cache and probes the cached IP with a 2-second connect timeout.
- **Bounded timeouts everywhere.** `DENON_CURL_CONNECT_TIMEOUT=2`, `DENON_CURL_MAX_TIME=4`, `DENON_SSDP_TIMEOUT=2`. No command can hang on a dead receiver.
- **Lazy Python.** The optional HEOS helper (`denon_heos_helper.py`) is only invoked for queue/group/browse/search — the commands the Telnet sideband cannot express. Basic transport (`heos play`, `heos pause`) uses Telnet codes (NS9A/B/C/D/E) and does not pay the Python startup cost.

---

## 3. Logic Patterns (How to Stay Consistent)

These are the patterns the existing code follows. New features must mirror them.

### 3.1 Two-Plane Protocol Strategy

The codebase uses three protocols, picked by capability and cost in this strict order of preference:

| Protocol | Port | Purpose | When to use |
|---|---|---|---|
| **HTTPS XML config API** | 10443 | Durable, queryable state | Always preferred for read/write of `Power`, `Volume`, `Mute`, `Source`, identity. |
| **Telnet ASCII** | 23 | Ephemeral, fire-and-forget | Sleep timer, sound mode (`MSSTEREO`), Audyssey (`PSDYNVOL`), tone control (`PSBAS`/`PSTRE`), Quick Select (`QUICK1 MEMORY`), HEOS transport (`NS9A`/`B`/`C`/`D`/`E`). |
| **HEOS JSON-over-TCP** | 1255 (via Python helper) | Stateful HEOS queries | Queue, groups, browse, search, play-stream. Anything that requires a session or returns structured data. |

**Rule for new commands:** if the XML config API can express it, use the XML API. Fall back to Telnet only when no `type=N` endpoint exposes the field. Fall back to the HEOS helper only when neither does.

### 3.2 Set-then-Verify Sync

State-changing commands do **not** trust the AVR's immediate response. The pattern is:

1. Issue the change (`_denon_set_config` or `_denon_telnet`).
2. Poll the relevant read endpoint until the value matches expectation, or until a bounded attempt count is exhausted.
3. On success, print confirmation. On drift, emit a warning to stderr including the actual value.

The canonical implementation is `_denon_wait_for_source`: up to 20 polls at 250 ms intervals (5 s total ceiling). The same shape appears in `_denon_set_volume_db`, which calls `_denon_main_volume_raw` after the write and warns on mismatch.

This handles the AVR's ~100-500 ms eventual-consistency window without blocking longer than necessary on the happy path. **All future write commands must use this pattern.** A "set and pray" command is a bug.

### 3.3 Discovery Fallback Cascade

`_denon_discover` walks a fixed, ordered cascade. Each tier is cheap and bounded; the cache makes the steady-state cost effectively zero:

1. `$DENON_IP` (if set) — probed, never blindly trusted.
2. `~/.cache/denon_ip` — probed for liveness.
3. `$DENON_DEFAULT_IP` — probed for liveness.
4. SSDP multicast (M-SEARCH for `MediaRenderer:1`).
5. ARP / `ip neigh` / `/proc/net/arp` known-host scan.
6. `$DENON_SCAN_LAN=1` opt-in full `/24` sweep (off by default — it's slow and noisy).

Every candidate is gated through `_denon_is_receiver`, which fetches `type=3` and greps for the literal `Denon`. This means a stale ARP entry for a printer never causes a false positive.

**Rule:** never bypass `_denon_discover`. If you need a specific receiver in a multi-AVR future, that requirement goes through the discovery layer (§5.1), not around it.

### 3.4 Local Aliases vs. Device Truth

Source renames are stored in a tab-separated file at `${DENON_SOURCE_ALIASES:-~/.config/denon/source_aliases}` with the schema `zone<TAB>index<TAB>display_name`. The AVR's own source labels are never mutated.

This is a deliberate architectural separation: **the device owns its factory state; the user owns the presentation layer.** Wiping the alias file is a non-destructive reset. Sharing the script across machines preserves device defaults.

Any future "preference" or "user-defined name" feature should follow this pattern: store it locally, layer it over the device read, never write it to the AVR.

### 3.5 HEOS Helper Boundary

The Bash script handles HEOS transport via Telnet (`NS9A`–`NS9E` for play/pause/stop/next/prev) — this is enough for 80% of HEOS use. Anything that needs the HEOS JSON protocol (queue manipulation, group management, content browsing, search, direct stream playback) shells out to `denon_heos_helper.py`.

The boundary is **capability**, not convenience. A new HEOS feature belongs in the Python helper only if:
- It requires reading structured data back (queue contents, group topology, browse results).
- It requires session state (HEOS `register_for_change_events`, paginated browse).
- It depends on a HEOS protocol field not exposed in the Telnet sideband.

Otherwise, prefer Telnet. Every Python call adds ~50 ms of interpreter startup to a command that would otherwise be sub-10 ms.

### 3.6 Output Discipline

- **stdout = data.** Pretty status, JSON, raw XML, snapshot paths.
- **stderr = diagnostics.** Errors, warnings, debug traces, "did you mean" hints.
- **`DENON_DEBUG=1`** routes through `_denon_debug`, which writes to stderr only.
- **`--json` is structural, not cosmetic.** Field names are a contract. Renaming a JSON key is a breaking change and requires a version bump in mind.

### 3.7 Volume Encoding

The Denon raw volume is `(dB + 80) × 10`, clamped to `[0, 980]`. The conversion is centralized in `_denon_raw_to_db` and `_denon_db_to_raw`. **Do not inline this math anywhere else.** If the encoding ever changes (different model, different firmware), it changes in exactly two places.

A safety ceiling lives in `DENON_MAX_VOLUME_DB` (default `-10`). The user must explicitly set this to `off`/`none`/`disabled` to exceed it. This is a deliberate guardrail (§4) — do not weaken it.

---

## 4. Guardrails (Non-Negotiables)

These are hard constraints. A change that violates one is, by definition, not in scope for this project — it's a different project.

1. **Single-file, sourceable.** The script must work as both `./denon_release_candidate.sh status` and `source ./denon_release_candidate.sh && denon status`. No multi-file Bash packaging. No build step. The Python HEOS helper is the sole exception, and it stays optional.
2. **Bash + Zsh, not POSIX `sh`.** Bash 4+ idioms (`[[ ]]`, `${var,,}`, arrays) are allowed and used. Zsh sourcing must keep working — `$ZSH_VERSION` branches exist for a reason (see `_denon_heos_helper`'s `funcfiletrace` use). New code must not break either shell.
3. **No heavy dependencies.** The required set is `bash`, `curl`, `awk`, `sed`, `grep`, `ip`, `nc`. `jq` and `shellcheck` are optional. `python3` is optional (only for advanced HEOS). Adding any other required dependency requires explicit justification in this document.
4. **Pipeable.** stdout is parseable. The default human output is line-oriented. `--json` produces a single JSON document. No prompts, no spinners, no curses TUIs on the primary commands. (The `dashboard --watch` mode is the sanctioned exception, and it must remain optional.)
5. **Bounded timeouts on every network call.** No command can hang. All `curl` and `nc` calls go through `_denon_curl` or `_denon_telnet`/`_denon_telnet_query`, which apply timeouts from environment variables with safe defaults.
6. **Stateless except for IP cache and aliases.** No PID files. No lock files (yet — see §5.6). No long-lived sockets. The script must be safe to invoke 100 times in a row from a scene script.
7. **AVR-X1600H XML grammar is the reference.** The current `sed` extractors assume the structure this model emits. Supporting another model is allowed but must be additive — never break the X1600H path.
8. **Verify after every write.** No "set and pray." See §3.2.
9. **Trusted LAN only.** `curl -k` is used because the receiver presents a self-signed cert. Telnet has no auth. Do not market or extend this tool as suitable for hostile networks. The README's safety section is part of the contract.
10. **Volume ceiling on by default.** `DENON_MAX_VOLUME_DB=-10` ships as the default. The user must opt out, never in.
11. **stderr for warnings, exit codes for errors.** Every command returns a meaningful exit code. Scene scripts depend on `&&` chaining working correctly.
12. **No telemetry. No network calls outside the LAN.** The tool reaches `$IP` (the receiver), `239.255.255.250` (SSDP multicast), and nothing else. Ever.

---

## 5. Future-Proofing & Known Technical Debt

These are the places the current architecture will strain if pushed. Each entry is a future decision point — not a bug to fix today, but a known limit to design around.

### 5.1 Multi-AVR support

The current design assumes one receiver. `$IP`, `$BASE`, `~/.cache/denon_ip` are all singletons. To support multiple receivers (a Denon in the living room *and* one in the den, or eventually a Marantz on the same protocol), the right shape is:

- A receiver registry at `~/.config/denon/receivers` (one record per device: friendly name, IP, model, last-seen UUID from SSDP USN).
- A `--host=<name|ip>` flag or a `denon @livingroom status` ambient prefix.
- Discovery returns a *list* with stable identifiers, not the first match.
- The cache becomes a map keyed by friendly name.

Designing this *now* in the discovery layer is cheap; retrofitting it after fifteen commands have hard-coded `$IP` is expensive.

### 5.2 XML extraction fragility

The current pattern is `sed -n 's:.*<MainZone><Power>\([0-9]*\)</Power>.*:\1:p'`. This assumes:
- The element ordering Denon currently emits.
- No whitespace or newlines between adjacent tags.
- A specific model's XML grammar.

A firmware revision that re-orders elements, or another model that wraps `<MainZone>` differently, will silently produce empty extractions. The mitigation path, in order of cost:

- Centralize all extractors in one section labeled `# XML accessors (AVR-X1600H grammar)` so future model support is a single diff.
- Move from `sed` to `xmllint --xpath` (still no heavy dependency — `libxml2-utils` is ubiquitous) gated behind an `if command -v xmllint` check, with `sed` as the fallback.
- Add a snapshot-diff regression test: capture known-good XML in `tests/fixtures/`, run extractors against them, assert known values.

### 5.3 The missing HEOS helper

`denon_heos_helper.py` is referenced by `_denon_heos_helper` but is **not currently committed to the repository.** Every HEOS queue/group/browse/search/play-stream command fails on a fresh clone with `Error: HEOS helper not found`. This is the single largest gap between documented capability and shipped artifact. It must be either:
- Committed, with its own dependency declaration (likely just `python3 ≥ 3.8`, no external libs since the HEOS protocol is plain socket I/O); or
- The advertised commands must be removed from the help text until the helper ships.

Until then, treat the HEOS docs in the README as aspirational.

### 5.4 Function-redefinition cost

Every helper (`_denon_curl`, `_denon_get_config`, `_denon_set_config`, and ~80 others) is defined **inside** the `denon()` function. Every call to `denon` redefines them all. This is fast (Bash parses these in microseconds) but has three real costs:

- Helpers cannot be unit-tested in isolation — there's no way to source one without invoking the whole CLI.
- Static analysis (`shellcheck`) has to chase nested scope and produces noisier output.
- The mental model "what's a private helper vs. a public command?" is blurred.

The clean refactor is to move all `_denon_*` helpers to top level, define `denon()` as a dispatcher only, and rely on the `_denon_` prefix for the de-facto private namespace. This is a mechanical change with low risk and high payoff. Schedule it before the script crosses 4,000 lines.

### 5.5 No `set -e` / `set -o pipefail`

Errors inside pipelines can silently pass. Most commands handle this with explicit `|| return 1` and `[[ -n "$value" ]] || …` checks, but coverage is uneven. Retrofitting `set -euo pipefail` at the top of an already-working ~3,000-line script will almost certainly surface latent bugs and is a non-trivial migration. New code should write as if those flags were on (explicit checks, no silent pipe failures), so the eventual flip is small.

### 5.6 Concurrent invocations

Two simultaneous `denon vol -30` calls race at the AVR. The AVR is its own arbiter (last write wins), but the set-then-verify step in the loser will misleadingly report drift. For scripted automation this is rare; for interactive shells it's basically a non-issue. If it ever bites:
- `flock` on `~/.cache/denon_ip` would serialize, at the cost of latency.
- A `--no-verify` flag for batch operations would let scene scripts opt out of the polling cost.

### 5.7 Polling cost in scene scripts

A scene like "switch to HEOS, set volume, set sound mode" performs three verify loops in series — up to ~15 s worst case. In practice it completes in under a second, but the worst-case bound is visible. The right scaling fix is a **batched scene primitive** — `denon scene apply <file>` that issues all writes, then verifies the final state vector once. This composes cleanly with `spotify-dj`'s existing scene model.

### 5.8 No event subscription

Both the Denon UPnP layer (port 8080, GENA events) and HEOS (`system/register_for_change_events`) support push notifications. The current CLI is poll-only. For a future where `spotify-dj`, `lgtv`, and `denon` need to react to each other (e.g., "TV turned on → switch AVR to Xbox source"), a small daemon — `denon listen` — that emits JSONL events to stdout would slot in cleanly without breaking any existing command.

This is the natural integration seam for the wider home-lab. Note that the day it exists, several guardrails (statelessness, no long-running process) gain explicit exceptions; the daemon is opt-in and isolated.

### 5.9 Snapshot portability

`denon snapshot` saves model-specific XML. It's not portable across receivers. For a "back up my receiver settings" use case to work across model upgrades, a normalized JSON manifest (key fields extracted into a stable schema) should accompany the raw XML dump. Keep the raw XML — it's the ground truth — but emit a `manifest.json` alongside it.

### 5.10 Integration envelope for sibling CLIs

`denon`, `lgtv`, and `spotify-dj` each invent their own JSON shape. A shared envelope — `{ "tool": "denon", "ts": "...", "command": "vol", "args": {...}, "result": {...} }` — would let scene scripts log uniformly and would make it trivial to replay sessions. This is not a current requirement; it's a coordination point to keep in mind the next time any of the three CLIs gets a JSON-format change.

---

## 6. Decision Record

When making a change that touches any of the patterns or guardrails above, append an entry here. Format: date, summary, rationale, sections affected.

| Date | Change | Rationale | Sections |
|---|---|---|---|
| (initial) | Architecture document established | Baseline capture before scaling work | All |

---

*End of document.*
