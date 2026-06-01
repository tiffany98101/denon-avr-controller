# Live Capability Analysis

Run analyzed: `local-live-runs/20260507-174301/`

The local run compared the bundled offline `references/deviceinfo_capabilities.xml` with live `Deviceinfo.xml` from the AVR, then ran `data capabilities --probe-safe` against the strict AppCommand allowlist.

## Summary

- Offline and live Deviceinfo capability inventories matched: 196 unique verb names, 291 advertised capability records.
- Safety classification was unchanged between offline and live inventories:
  - `known-safe`: 20 records
  - `unknown`: 204 records
  - `skipped`: 67 records
- All 20 allowlisted AppCommand probe attempts returned `malformed` with the receiver message `Could not handle the request`.
- No allowlisted AppCommand probe returned a useful payload.
- No allowlisted AppCommand probe returned an empty `<rx></rx>` in this run.
- Unknown verbs remained inventoried only and were not executed.
- Unsafe verbs stayed skipped, including firmware/update actions and all `Set*` mutation verbs.

## Useful Live Data

The useful live fields came from existing safe read-only surfaces, not from AppCommand payloads:

- `get_config` types 1, 5, 8, 9, 10, 11, and 12 exposed additional stable raw fields.
- Telnet read-only queries exposed current sound/tone/channel state.
- HEOS read-only queries exposed HEOS model/version/network and player volume level.
- UPnP descriptors exposed model, MAC, pending upgrade metadata, CommApi version, zone count, serial, HEOS/AIOS firmware, and UDN.

## Promoted Fields

The following fields are now promoted from raw/unhandled XML leaves into structured output:

- Receiver identity: `brand_code`, `model_type`
- Main Zone: `volume_scale`, `volume_limit_raw`
- Zone 2: `volume_scale`, `volume_limit_raw`
- System: `setup_lock`, `bt_headphones_single_used`, `speaker_preset`, `advanced_mode`, `ci_mode`, `menu_lock`, `gui_type`, `heos_sign_in`, `webui_type`, `product_type`

These are intentionally exposed as raw receiver codes where the meaning is not fully documented. That avoids inventing labels that might be wrong on other Denon models or firmware builds.

## Raw-Only Fields

These remain raw-only or discovery-only for now:

- AppCommand allowlisted probe responses, because the live receiver returned no useful AppCommand payloads.
- Web UI discovered assets, because they are implementation files and not stable receiver state.
- Unknown advertised commands, because they are not part of the live-probe allowlist.
- Unsafe advertised commands, because they look mutating, account-related, firmware-related, or reset/update-related.

## Safe-Probe Results

Allowlisted AppCommand verbs probed live:

`GetActiveSpeaker`, `GetAllZoneStereo`, `GetAudioInfo`, `GetAudyssey`, `GetAudyssyInfo`, `GetAutoStandby`, `GetChLevel`, `GetDialogLevel`, `GetDimmer`, `GetECO`, `GetECOMeter`, `GetInputSignal`, `GetNetworkInfo`, `GetSoundMode`, `GetStatus`, `GetSubwooferLevel`, `GetToneControl`, `GetVideoInfo`, `GetVideoSelect`, `GetZoneName`

Result for all: `malformed`, summary `Could not handle the request`.

## Recommended Next Probes

These advertised `Get*` names look read-only and may be worth future review, but they remain outside the live allowlist until their behavior is confirmed safely:

- `GetBTTX`
- `GetOptionBTTX`
- `GetRestorerMode`
- `GetHdmiSetup`
- `GetEQSetting`
- `GetEQAdjustChList`
- `GetEQParameter`
- `GetEQOtherFunc`
- `GetSourceRename`
- `GetDefSourceRename`
- `GetAutoRename`
- `GetHideSources`
- `GetInputSelect`
- `GetSetupLock`
- `GetSoundModeList`
- `GetQuickSelectName`
- `GetPresetList`

Do not add any `Set*`, update, firmware, reset, delete, account, login, pairing, factory, or write/configuration command to the allowlist.

## Firmware Conclusion

The installed AVR mainboard firmware version still has not been found on read-only receiver surfaces.

`UpgradeVersion` remains pending update metadata and is exposed as `pending_upgrade_version`; it is not installed firmware.

HEOS/AIOS firmware is separate from AVR mainboard firmware and must not be labeled as AVR mainboard firmware.
