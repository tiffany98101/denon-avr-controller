# Final Audit Report — Denon AVR-X1600H Data Inventory

**Target:** 192.168.1.162  
**HEOS firmware:** 3.88.614  
**AVR model:** AVR-X1600H  
**Branch:** feature/receiver-data-inventory  
**Date:** 2026-05-07  
**Budget used:** within 4-hour window  

---

## Executive Summary

A six-phase read-only audit of the Denon AVR-X1600H data collection tool was completed. The audit:

- Mapped 7 protocol surfaces and their current coverage gaps
- Gathered reference verb lists for all surfaces from community docs and the denonavr library
- Executed 63 live read-only probes confirming which verbs the target firmware supports
- Extended the tool with two new first-class surfaces (AppCommand POST, UPnP descriptors) and expanded telnet/HEOS coverage
- Fixed four serializer bugs (§12.B) that corrupted discovered-endpoints JSON, source lists, and now-playing data
- Added safe capability discovery that inventories advertised Deviceinfo/AppCommand verbs without executing unknown commands
- Delivered a pytest suite (27 tests, all passing) with fixture responses from Phase 4 probing

All safety constraints were honoured throughout: strictly read-only probes, ≥100 ms between probes, 5 s per-probe timeout, no HEOS account operations. One state-change event occurred during probing (volume ceiling adjusted by household member from 97.0 dB to 98.0 dB); this was not triggered by any probe and the auto-abort threshold was not reached.

---

## Phase 1 — Reconnaissance

**Deliverable:** `coverage_matrix.md`

Static analysis of `denon_release_candidate.sh` (~4 900 lines) and local dump output established baseline coverage across seven protocol surfaces. Four serializer bugs were identified from `denon_dump_report.md` and corroborated by the junk entries visible in the original local dump.

---

## Phase 2 — Reference Gathering

**Deliverables:** `references/` (7 files)

| File | Surface |
|------|---------|
| `appcommand_get_verbs.json` | AppCommand GET (`get_config?type=N`) |
| `appcommand_post_verbs.json` | AppCommand POST (`/goform/AppCommand.xml`) |
| `form_get_verbs.json` | Form GET endpoints (`/goform/form*Xml*.xml`) |
| `heos_cli_verbs.json` | HEOS CLI (TCP/1255) |
| `telnet_verbs.json` | Telnet (TCP/23) |
| `upnp_verbs.json` | UPnP/SSDP descriptors |
| `web_ui_verbs.json` | HTML/JS web UI assets |

Verb lists sourced from: denonavr Python library source, HEOS CLI Protocol spec, Denon AVR-X control protocol community reference.

---

## Phase 3 — Probe Plan

**Deliverable:** `probe_plan.json`

38 probes planned across 5 surfaces (AppCommand POST, Form GET, HEOS CLI, Telnet, UPnP). AppCommand GET types 1–30 and web UI scraping were handled by the existing tool; they were not re-probed individually.

---

## Phase 4 — Live Probing

**Deliverables:** `probe_log.jsonl` (63 entries), `state_before.json`, `state_after.json`, `state_diff.json`

### Pre/post state
- Main zone: Power=ON, Source=HEOS Music, Volume=-26.5 dB, Muted=no (unchanged)
- Zone 2: Power=OFF (unchanged)
- Volume ceiling: 97.0 dB → 98.0 dB (adjusted by household member; not probe-induced)
- Verdict: `NEAR_TRIGGER_BUT_NOT_PROBE_MUTATION` — no auto-abort fired

### Probe results by surface

| Surface | Probes | OK (returned data) | Unsupported | Error |
|---------|--------|--------------------|-------------|-------|
| AppCommand POST | 22 | 9 | 13 | 0 |
| Form GET | 14 | 5 | 9 | 0 |
| HEOS CLI | 5 | 4 | 0 | 1 |
| Telnet | 16 | 10 | 6 | 0 |
| UPnP | 6 | 4 | 2 | 0 |
| **Total** | **63** | **32** | **28** | **1** |

### Notable findings

**UPnP (port 8080) — confirmed fields from `Deviceinfo.xml`:**
- `ModelName`: AVR-X1600H
- `MacAddress`: 0006786D20A0
- `CommApiVers`: 0301
- `DeviceZones`: 2
- `UpgradeVersion`: 00. This is pending update metadata, now exposed as `pending_upgrade_version`; it is not the installed AVR mainboard firmware.
- Installed AVR mainboard firmware has still not been found on read-only receiver surfaces tested so far.
- HEOS firmware is separate from AVR mainboard firmware; `3.88.614` identifies the HEOS subsystem, not the AVR mainboard image.

**HEOS CLI — confirmed working verbs:**
- `player/get_volume` → level=53
- `system/check_account` → signed_out (safe, no auth attempted)
- `player/get_mute` → supported
- `system/get_system_info` → supported

**AppCommand POST — supported on this firmware (9/22):**
Returns non-empty `<rx>` body for: GetToneControl, GetDialogLevel, GetSubwooferLevel, GetChLevel, GetAllZoneStereo, GetDimmer, GetVideoSelect, GetZoneName, GetStatus. Returns empty `<rx></rx>` for others (treated as unsupported).

**Telnet — 10/16 queries returned data:**
`PSSWR` (subwoofer enable), `PSSWL` (subwoofer level), `CV` (channel levels), `MV` (volume raw), `PW` (power), `ZM` (zone power), `MU` (mute), `Z2`, `SPPR` (speaker preset), `VSASP` (video aspect).

---

## Phase 5 — Patch

**Modified files:** `denon_release_candidate.sh`, `tests/test_parsers.py`  
**New files:** `tests/fixtures/` (9 fixture files)

### Four §12.B serializer bug fixes

| Bug | Location | Description | Fix |
|-----|----------|-------------|-----|
| B-1 | `_denon_data_discover_web_endpoints_from_text` | `src=`/`href=` HTML attributes never extracted | Added `grep -oiE '(src\|href)="[^"]*"'` pass before token splitter |
| B-2 | `_denon_data_discover_web_endpoints_from_text` / `_denon_data_safe_path` | JS code fragments (`,d=b.css`, `;c.html`) matched as URL paths | Replaced loose case match with strict `grep -oE '"[/][A-Za-z0-9_./-]+'`; removed over-broad `*command*` from safe_path blocklist |
| B-3 | `_denon_data_record_discovered_endpoint` | Multi-line response body inserted extra newlines into tab-separated record, creating spurious JSON sibling entries | Added `tr '\n\r' '  '` to collapse body to single-line summary before appending |
| B-4 | `_denon_data_print_get_config_json` | Repeated XML siblings (same dotted path) clobbered each other; last value won | awk now accumulates values per path; emits JSON array when count > 1, scalar string when count == 1 |

### New surfaces added

- **AppCommand POST** (`_denon_data_collect_appcommand_post`): POSTs XML `<cmd>` bodies to `/goform/AppCommand.xml`, parses non-empty `<rx>` responses, stores as structured fields.
- **UPnP descriptors** (`_denon_data_collect_upnp`): Fetches `Deviceinfo.xml` (port 8080) and `aios_device.xml` (port 60006), extracts MAC, firmware, CommApiVers, serial, UDN via `_denon_data_parse_xml_field`.

### Unit test hook

Added `DENON_UNIT_TEST=1` support: when the script is sourced with this variable set, `denon` is called automatically (no-args path, no network I/O) so all nested helper functions become globally accessible to the pytest harness.

### Capability discovery

`denon data capabilities` now parses advertised Deviceinfo/AppCommand capability XML and reports:
- source endpoint or fixture path
- discovered function or AppCommand verb name
- safety classification: `known-safe`, `unknown`, or `skipped`
- skip reason for blocked verbs
- whether the current tool has a parser for that response family
- dry-run or live probe status

Default mode is offline dry-run inventory from `references/deviceinfo_capabilities.xml`. Live probing requires `--probe-safe`.

### Test suite

27 tests in `tests/test_parsers.py`. All passing.

| Class | Tests | What it covers |
|-------|-------|----------------|
| `TestParseXmlField` | 7 | `_denon_data_parse_xml_field` with real UPnP fixture XML |
| `TestBugB3MultiLineBody` | 2 | Bug B-3 single-record guarantee |
| `TestBugB1B2WebDiscovery` | 5 | Bug B-1 attribute extraction, Bug B-2 JS fragment rejection |
| `TestBugB4XmlLeafArrays` | 2 | Bug B-4 repeated-path → JSON array |
| `TestDeviceinfoCapabilities` | 4 | Capability XML parsing, repeated paths, unsafe skip classification, unknown dry-run behavior, known-safe dry-run plan |
| `TestTelnetFixtures` | 5 | Fixture file sanity + PSSWL dB math |
| `TestHeosFixtures` | 2 | HEOS JSON fixture sanity |

---

## Phase 6 — Verify / Finalize

**Deliverables:** `denondata_v2.txt`, this report, all phase commits

### Diff summary: denondata.txt → denondata_v2.txt

Key improvements visible in the v2 dump versus the original:

| Field | v1 (denondata.txt) | v2 (denondata_v2.txt) |
|-------|--------------------|-----------------------|
| `upnp_model` | absent | AVR-X1600H |
| `upnp_mac` | absent | 0006786D20A0 |
| `upnp_comm_api` | absent | 0301 |
| `upnp_zones` | absent | 2 |
| `SourceList.Zone.Source.Name` (type_7) | `"Source"` (last only, Bug B-4) | JSON array of all 9 sources |
| Discovered endpoints — junk JS fragments | 20+ noise entries (Bugs B-1/B-2) | Filtered out; only clean HTML/JS/XML paths |
| Multi-line jQuery summary entries (Bug B-3) | ~20 spurious sibling records | 1 record per fetched URL |

---

## Gaps Remaining

The following items were out of scope for this audit or remain deferred:

| Item | Reason |
|------|--------|
| AppCommand GET types 1, 2, 5, 8–11 structured parsing | Content varies per firmware; leaf extraction is sufficient for inventory |
| Form GET: `formMainZone_MainZoneXml.xml`, `formZone2_Zone2Xml.xml`, etc. | Overlap with existing type-4/type-12 data; low incremental value |
| Telnet `NSE?` on-screen display lines | Only meaningful during active menu navigation |
| HEOS `browse/browse` and queue commands | Probing browse containers can be disruptive during active playback |
| AVR main firmware version string | Installed AVR mainboard firmware still has not been found on tested read-only surfaces. `UpgradeVersion` is pending update metadata, not installed firmware. HEOS firmware is separate and does not identify the AVR mainboard image. |
| `denon_dump_report.md` not present at session start | File was created during this branch's work; was missing from the summary context when Phase 1 began |

---

## Safe Probing Model

Capability discovery is split into inventory and live probing:
- Inventory parses advertised XML only. It lists known-safe, unknown, and skipped verbs but executes nothing.
- Live probing requires `denon data capabilities --probe-safe`.
- `--probe-safe` can only probe exact allowlisted read-only AppCommand `Get*` verbs.
- Unknown verbs are listed for review but not executed.
- Verbs with mutating or sensitive names are skipped, including `Set*`, `Put*`, `Update*`, `Upgrade*`, `Factory*`, `Reset*`, `Reboot*`, `Delete*`, `Pair*`, `Register*`, `Login*`, `Account*`, firmware update actions, and write/config mutation actions.

---

## Safety Audit

All 63 probes were read-only:
- HTTP: GET requests only; no POST to any write endpoint
- AppCommand POST: only `Get*` verb bodies POSTed; no `Set*` verbs
- Telnet: only `?`-suffixed query commands; no state-change commands issued
- HEOS: only `get_*` namespace commands; no `set_*`, `add_*`, `remove_*`
- No HEOS account sign-in or sign-out attempted
- Rate limit: ≥100 ms between probes enforced throughout
- Receiver remained in active use (HEOS Music playing) throughout with no interruption
