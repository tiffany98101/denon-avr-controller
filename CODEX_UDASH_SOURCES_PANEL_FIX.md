# Dashboard Ultra Sources Panel Fix

## Root Cause

The adaptive dashboard-ultra planner built each panel body while a row was still
being assembled. `Sources (Main)` could be formatted as two columns using a
wide provisional width, then later rendered in a narrower final column after
more panels joined the row. The card renderer then truncated those preformatted
two-column lines, leaving orphaned fragments such as `5...` or `6...` without
the source names.

## Changed Files

- `denon.sh`
  - `_denon_udash_compose_sources_body` now chooses two columns only when full
    source entries fit in the available column width and row budget.
  - Limited source panels now drop whole entries and show `+N more` instead of
    truncating individual entries into unreadable fragments.
  - `_denon_udash_render_plan_row` rebuilds the `Sources (Main)` body using the
    final rendered panel width and row body budget.
- `tests/test_dashboard_ultra.py`
  - Added a regression test for a large adaptive grid where `Sources (Main)`
    shares a row with other panels and must keep all visible source entries
    intelligible.

## Validation

- `bash -n denon.sh` passed.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q tests/test_dashboard_ultra.py`
  passed: `15 passed`.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q tests/test_dashboard_alignment.py tests/test_parsers.py tests/test_dashboard_alt.py`
  passed: `248 passed`.
- `./test/run` passed: `11` TAP checks.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q tests` passed:
  `354 passed, 5 skipped`.

## Remaining Risks

- No live AVR/dashboard terminal session was run in this pass; validation used
  the existing shell render fixtures and automated dashboard tests.
- Very short source-panel rows intentionally show whole leading entries plus a
  `+N more` line when the panel cannot display every source.
