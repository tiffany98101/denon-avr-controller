# Coverage Matrix — Denon AVR-X1600H Data Inventory

**Target:** 192.168.1.162 · HEOS firmware 3.88.614  
**Branch:** feature/receiver-data-inventory  
**Phase 1 baseline** — updated post-Phase 5

---

## 1. AppCommand GET (`/ajax/globals/get_config?type=N`)

**Base URL:** `https://192.168.1.162:10443/ajax/globals/get_config?type=N`

### What the current tool queries
- Types explicitly named: 3 (identity), 4 (power), 6 (zone names), 7 (sources), 12 (volume/mute)
- Discovery sweep: types 0–30 (controlled by `DENON_DATA_DISCOVERY_MAX_TYPE`)
- Responses with data found at types: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13

### What is documented but unqueried (baseline)
- Types above 30 (the `GlobalsServerInterface.js` shows `CONFIG_*` constants up to ~14 in the JS; types 14-30 likely return empty)
- No structured parsing of types 1, 2, 5, 8–13 beyond leaf extraction

### Status: **Partial**

| Type | Name | Queried | Parsed |
|------|------|---------|--------|
| 1 | Brand | yes (sweep) | leaf only |
| 2 | Language | yes (sweep) | leaf only |
| 3 | FriendlyName / Identity | yes (named) | structured |
| 4 | Power (all zones) | yes (named) | structured |
| 5 | ModelType | yes (sweep) | leaf only |
| 6 | Zone names | yes (named) | structured |
| 7 | SourceList | yes (named) | structured |
| 8 | SetupLock | yes (sweep) | leaf only |
| 9 | BtHeadphonesSingleUsed | yes (sweep) | leaf only |
| 10 | SpeakerPreset | yes (sweep) | leaf only |
| 11 | System (AdvancedMode, CIMode, ...) | yes (sweep) | leaf only |
| 12 | Volume/Mute (all zones) | yes (named) | structured |
| 13 | String ID table | yes (sweep) | empty (no leaf values) |

---

## 2. AppCommand POST (`/goform/AppCommand.xml`)

**Base URL:** `http://192.168.1.162/goform/AppCommand.xml` (POST with XML body)

### What the current tool queries
- **Nothing.** AppCommand POST is entirely absent from the tool.

### What is documented to exist (denonavr library + community docs)
The POST surface uses `<cmd id="1">GetAllZonePowerStatus</cmd>` etc. Known read-only `Get*` verbs from the denonavr library and community sources:

- `GetAllZonePowerStatus`
- `GetAllZoneVolume`
- `GetAllZoneSource`
- `GetNetAudioStatus`
- `GetTunerStatus`
- `GetPresetStatus`
- `GetSourceStatus`
- `GetSurroundModeStatus`
- `GetFriendlyName`
- `GetSerialNumber` (if supported)
- `GetSoftwareVersion`
- `GetModelName`
- `GetToneControl`

### Status: **Absent** (pre-Phase 5) → **Partial** (post-Phase 5, added as first-class surface)

---

## 3. Form GET Endpoints (`/goform/form*Xml*.xml`)

**Base URL:** `http://192.168.1.162/goform/`

### What the current tool queries
- `/goform/formNetAudio_StatusXml.xml` — for Now Playing (title, artist, album)

### What is documented to exist but unqueried (baseline)
Known form endpoints on Denon AVR-X series:
- `/goform/formMainZone_MainZoneXml.xml` — main zone comprehensive status
- `/goform/formMainZone_MainZoneXmlStatus.xml` — main zone status
- `/goform/formZone2_Zone2Xml.xml` — Zone 2 comprehensive status
- `/goform/formZone2_Zone2XmlStatus.xml` — Zone 2 status
- `/goform/formTuner_TunerXml.xml` — tuner status
- `/goform/formNetAudio_StatusXml.xml` — already covered (now playing)

### Status: **Partial**

---

## 4. HEOS CLI (TCP/1255)

### What the current tool queries (read-only)
Via `denon_heos_helper.py`:
- `player/get_players` — model, version, network, pid
- `player/get_now_playing_media?pid=...` — title, artist, album, type
- `player/get_play_state?pid=...` — play state
- `player/get_queue?pid=...&range=0,99` — queue contents
- `player/get_play_mode?pid=...` — repeat/shuffle
- `player/check_update?pid=...` — firmware update check
- `group/get_groups` — group list
- `group/get_group_info?gid=...` — group info
- `browse/get_music_sources` — music source list
- `browse/browse?sid=...` — browse container
- `browse/search?sid=...&search=...` — search

### What is documented but unqueried (baseline)
Safe read-only verbs not yet used:
- `system/heart_beat` — connectivity check
- `system/get_system_info` — firmware, network, hardware info
- `system/check_account` — account state (should return signed-out without triggering sign-in)
- `system/get_music_sources` — alias for browse/get_music_sources
- `system/get_now_playing_media` — system-level now playing
- `player/get_volume?pid=...` — volume via HEOS (cross-check with type-12)
- `player/get_mute?pid=...` — mute via HEOS (cross-check)
- `group/get_volume?gid=...` — group volume
- `group/get_mute?gid=...` — group mute
- `event/register_for_change_events?enable=off` — disable events before probing

### Status: **Partial**

---

## 5. Telnet (TCP/23)

### What the current tool queries
| Command | Field |
|---------|-------|
| `SLP?` | Main zone sleep timer |
| `Z2SLP?` | Zone 2 sleep timer |
| `PSDYNEQ ?` | Dynamic EQ on/off |
| `PSDYNVOL ?` | Dynamic Volume level |
| `PSCINEMA EQ. ?` | Cinema EQ on/off |
| `PSMULTEQ ?` | MultEQ mode |
| `PSBAS ?` | Bass tone |
| `PSTRE ?` | Treble tone |
| `SI?` | Current source input (signal-debug) |
| `MS?` | Sound mode + OPINF lines (signal-debug) |
| `OPINFINS ?` | Input signal info (signal-debug) |
| `OPINFASP ?` | Aspect ratio info (signal-debug) |

### What is documented but unqueried (baseline)
Read-only `?` queries from the Denon AVR Control Protocol:
| Command | Field |
|---------|-------|
| `PW?` | Main power |
| `MV?` | Main volume |
| `MU?` | Main mute |
| `ZM?` | Main zone power |
| `Z2?` | Zone 2 power |
| `Z2MU?` | Zone 2 mute |
| `Z2MV?` | Zone 2 volume |
| `Z2SLP?` | Already covered |
| `Z3SLP?` | Zone 3 sleep |
| `TFAN?` | Tuner frequency |
| `TFANNAME?` | Tuner station name |
| `NSFRN?` | Network audio friendly name |
| `NSET?` | Network audio track info |
| `NSE?` | On-screen display lines |
| `SSSOD?` | Source delete status |
| `SSINFAISFSV?` | AIS firmware sub-version |
| `SSINFAI?` | AI version |
| `MNMEN?` | Menu status |
| `MNZST?` | Zone status |
| `PSDIL?` | Dialog Level |
| `PSSWR?` | Subwoofer |
| `PSSWL?` | Subwoofer level |
| `PSLOM?` | Loudness Management |
| `PSCES?` | Center spread |
| `PSDSDECO?` | DSD decode |
| `PSAFD?` | AFD mode |
| `PSEFF?` | Effect |
| `PSRSP?` | Room size |
| `PSLFC?` | Low frequency containment |
| `PSCF?` | Center freq |
| `VSASP?` | Video aspect |
| `VSMONI?` | Monitor out |
| `VSSC?` | Video scaling |
| `VSSCH?` | HDMI scaling |
| `CV?` | Channel volume |
| `SPPR?` | Speaker preset |

### Status: **Partial**

---

## 6. UPnP / SSDP Descriptors (port 8080 and 60006)

### What the current tool queries
- SSDP M-SEARCH (UDP) — only used to discover the AVR IP, not to fetch descriptors

### What is documented to exist but unqueried (baseline)
| URL | Expected content |
|-----|-----------------|
| `http://192.168.1.162:8080/goform/Deviceinfo.xml` | `UpgradeVersion` (AVR firmware), `CommApiVers`, serial |
| `http://192.168.1.162:8080/description.xml` | UPnP root device description, MAC, model |
| `http://192.168.1.162:60006/upnp/desc/aios_device/aios_device.xml` | AIOS (HEOS board) device description |

### Status: **Absent** (pre-Phase 5) → **Partial** (post-Phase 5, added as first-class surface)

---

## 7. HTML/JS Web UI Assets

### What the current tool queries
- `/general/general.html` — fetched; text extracted for firmware/version labels
- JS files discovered via text token split — bodies stored and secondary endpoints extracted

### What is documented to exist but unqueried (baseline)
- `<script src="...">`, `<link href="...">`, `<img src="...">`, `<a href="...">` attributes in HTML — NOT parsed by the current tool (Bug B-1)
- `/general/` subdirectory assets (CSS, images, additional JS)
- `/ajax/globals/get_config` type constants in `GlobalsServerInterface.js` — partially useful

### Status: **Partial** (Bug B-1 suppresses attribute-embedded path discovery)

---

## Summary Table

| Surface | Pre-Phase 5 | Post-Phase 5 |
|---------|-------------|--------------|
| AppCommand GET (type=N sweep) | Partial | Partial (unchanged) |
| AppCommand POST (Get* verbs) | Absent | Partial |
| Form GET endpoints | Partial | Partial (more forms added) |
| HEOS CLI | Partial | Partial (more verbs) |
| Telnet | Partial | Partial (more verbs) |
| UPnP/SSDP descriptors | Absent | Partial |
| HTML/JS web UI | Partial | Partial (attribute pass fixed) |
