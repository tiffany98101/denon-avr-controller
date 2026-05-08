# Denon AVR-X1600H Data Dump Audit Report

**Target:** 192.168.1.162  
**HEOS firmware:** 3.88.614  
**Date:** 2026-05-07  

## §1 Executive Summary

The `denon_release_candidate.sh` data dump pipeline successfully collects identity, power, source, volume/mute, zone-name, tone/Audyssey, sleep-timer, and now-playing fields via AppCommand GET and telnet. Four serializer bugs corrupt the captured data and inflate the discovered-endpoints list with JS noise.

## §2 Protocol Surface Coverage

| Surface | Status |
|---|---|
| AppCommand GET (`/ajax/globals/get_config?type=N`) | Partial — types 0-30 swept, named 3,4,6,7,12 |
| AppCommand POST (`/goform/AppCommand.xml`) | **Absent** |
| Form GET endpoints (`/goform/form*Xml*.xml`) | Partial — only `formNetAudio_StatusXml.xml` |
| HEOS CLI (TCP/1255) | Partial — players, now-playing, play-state, groups, browse |
| Telnet (TCP/23) | Partial — sleep, Audyssey/tone, sound mode, signal-debug |
| UPnP/SSDP descriptors | **Absent** — no HTTP GET of descriptor files |
| HTML/JS web UI assets | Partial — `/general/general.html` fetched; attribute pass missing |

## §3 Fields Confirmed Available

From `denondata.txt`, the following are successfully collected:

- Receiver identity: `name`, `ip`
- Main zone: `zone_name`, `power`, `source_index`, `source_name`, `volume_raw`, `volume_db`, `volume_max_db`, `muted`
- Zone 2: all same fields (no `volume_max_db`)
- Sources: `main_zone_sources`, `zone2_sources`
- Audio/surround: `sound_mode`
- Sleep: `main_zone_sleep`, `zone2_sleep`
- Tone/Audyssey: `dynamic_eq`, `dynamic_volume`, `cinema_eq`, `multeq`, `bass`, `treble`
- Network/HEOS: `heos_model`, `heos_version`, `network`
- Raw get_config: types 1–13 respond with data

## §4 Known Gaps

- AVR firmware version (not in type-3 XML; expected in UPnP `UpgradeVersion`)
- MAC address (expected in UPnP descriptor)
- Serial number (expected in UPnP descriptor or AppCommand POST)
- `CommApiVers` (expected in UPnP `Deviceinfo.xml`)
- AppCommand POST `Get*` verbs (zero coverage)
- `formMainZone_MainZoneXml.xml`, `formZone2_Zone2Xml.xml`, etc. (unchecked)
- HEOS `system/get_system_info`, `player/get_volume`, `player/get_mute`, `player/get_play_mode`

## §5 MultEQ Gap

The multeq telnet response uses `PSMULTEQ:AUDYSSEY` format; the parser strips `PSMULTEQ:` but the current dump shows `multeq: unknown` for this unit, indicating the query may not be returning data on this firmware. Needs live probe.

## §12 Serializer Bugs

### §12.B Four Confirmed Serializer Bugs

**Bug B-1 — HTML asset scraper misses attribute-embedded paths**

`_denon_data_discover_web_endpoints_from_text` splits on `"'()<>` and whitespace then checks case patterns. It never extracts `src=`, `href=` attribute values from HTML tags. Assets like `<script src="/js/app.js">` are never discovered. The visible effect: only paths embedded as bare string literals in JS are found; HTML-embedded paths are silently dropped.

**Bug B-2 — URL-extraction regex matches JS code fragments as paths**

The token-splitter and case match `/*` and `*.html|*.js|*.css` without requiring the path to be clean. Tokens like `,d=b.css`, `;c.html`, `this,b,c.html`, `:f.css`, `a.style.display||f.css`, `,v.statusCode`, `&&f.css` pass the filter because they end in `.css` or `.html`. These are then fetched (returning "not found") and appear in the discovered-endpoints list as noise. Evidence: 20+ junk entries in `denondata.txt` discovered_endpoints section.

Fix: Tighten the acceptance regex to require:
- leading `/` 
- followed only by `[A-Za-z0-9_\-./]+`
- reject any token containing: `,`, `;`, `=`, `?`, `&`, `|`, `:`, `(`, `)`, `{`, `}`, or whitespace

**Bug B-3 — Multi-line response bodies split into sibling JSON entries**

When a fetched URL body contains newlines (e.g., jquery.js comment block), `data_discovered_endpoint_records` grows one entry per **line** of the body because the shell variable stores the record as tab-separated fields with `\n` as a record separator, but the multi-line body inserts extra `\n` that become record separators. Effect: one URL fetch generates dozens of sibling entries in `discovered_endpoints` JSON array. Evidence: jquery.js generates ~20 entries in `denondata.txt` JSON.

Fix: Each fetched URL = one entry. The body field must be reduced to a single-line summary (first 160 chars, whitespace-collapsed) before appending to `data_discovered_endpoint_records`.

**Bug B-4 — XML leaf flattener clobbers repeated sibling elements**

`_denon_data_xml_leaf_paths` uses a stack-based path builder. When multiple siblings share the same tag name (e.g., `<Source><Name>A</Name></Source><Source><Name>B</Name></Source>`), each emits the same dotted path (e.g., `SourceList.Zone.Source.Name`). The shell reads them into `data_get_config_leaf_records` correctly, but `_denon_data_print_get_config_json` uses the **last** value because it iterates the leaf records and overwrites the same JSON key. Effect: `type_7` JSON fields shows only `"SourceList.Zone.Source.Name": "Source"` (the last source name) instead of all 9 source names. Fix: Emit JSON arrays for repeated leaf paths.
