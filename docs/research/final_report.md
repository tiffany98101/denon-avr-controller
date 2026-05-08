# Receiver Data Inventory Research Summary

This is a sanitized historical summary of the receiver data inventory work. Raw
local probe outputs and receiver-specific identifiers were intentionally removed
from the public repository.

## Scope

- Target class: Denon AVR-X series receiver.
- Example LAN address used in this document: `192.168.1.100`.
- Local receiver identifiers, serial numbers, MAC addresses, UDN values, HEOS
  player IDs, and live playback metadata are redacted.
- All live probes referenced here were intended to be read-only.

## Outcomes

- Mapped the data surfaces used by the Bash CLI:
  - `get_config` XML
  - AppCommand capability XML
  - safe telnet query commands
  - HEOS read-only status calls
  - UPnP descriptors
  - web UI discovery paths
- Added offline Deviceinfo/AppCommand capability inventory.
- Added strict safe-probe classification so unknown or unsafe advertised verbs
  are inventoried but not executed.
- Promoted useful read-only receiver fields into structured diagnostics.
- Added `data summary` and `dashboard --diagnostics` as user-facing views.
- Preserved concise normal `status` and normal `dashboard` output.

## Current Firmware Conclusion

The installed AVR mainboard firmware version was not found on tested read-only
surfaces.

`UpgradeVersion` is treated as pending update metadata and is exposed as
`pending_upgrade_version`; it is not labeled as installed firmware.

HEOS/AIOS firmware is separate from AVR mainboard firmware and must not be
presented as the AVR mainboard firmware.

## Safety Model

Capability discovery is split into inventory and live probing:

- Offline inventory parses XML only and executes nothing.
- Live AppCommand probing requires an explicit `--probe-safe` flag.
- Live probing is restricted to an exact allowlist of read-only `Get*` verbs.
- Unknown verbs are listed for review but not executed.
- Mutating or sensitive names remain skipped, including `Set*`, `Put*`,
  `Update*`, `Upgrade*`, `Factory*`, `Reset*`, `Reboot*`, `Delete*`, `Pair*`,
  `Register*`, `Login*`, `Account*`, firmware update actions, and write or
  configuration mutation actions.

## Research Artifacts

Kept sanitized references:

- `docs/research/coverage_matrix.md`
- `docs/research/probe_plan.template.json`
- `references/deviceinfo_capabilities.xml`
- `references/*.json`
- `docs/live-capability-analysis.md`

Removed raw local artifacts:

- Raw receiver dumps
- Raw probe logs
- Before/after receiver state snapshots
- Unsanitized local playback metadata

## Notes For Future Work

- Keep raw live outputs under ignored local directories such as
  `local-live-runs/`.
- Promote only small sanitized fixtures into `tests/fixtures/`.
- Use placeholders for private identifiers:
  - `192.168.1.100`
  - `00:00:00:00:00:00`
  - `SERIAL_PLACEHOLDER`
  - `uuid:00000000-0000-0000-0000-000000000000`
  - `HEOS_PID_PLACEHOLDER`
