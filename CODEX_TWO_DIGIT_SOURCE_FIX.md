# Two-Digit Dashboard Source Fix

## Root Cause

The source hotkey parser and source command dispatch were already able to build
and send two-digit source numbers. The failure was in the interactive wait loop:
after a slow dashboard refresh, the loop flushed an expired numeric prefix
before polling the terminal for already-buffered input.

That meant a user typing `10` could have `1` dispatched first if collection or
rendering took longer than the 750 ms multi-digit timeout before the next poll.
The queued `0` was then read after the buffer had been reset.

## Files Changed

- `denon.sh`
  - Changed the shared dashboard sleep/poll loop to poll pending keyboard input
    before expiring a numeric source prefix. This shared path is used by both
    `denon dashboard` and `denon dashboard-ultra`.
- `denon_dashboard_alt.py`
  - Applied the same read-before-flush ordering to the Python dashboard wait
    loop so all source-picker surfaces behave consistently.
- `tests/test_parsers.py`
  - Added a regression test proving a pending second digit is read before a
    stale first digit is flushed in the shell dashboard path.
- `tests/test_dashboard_alt.py`
  - Added the analogous regression test for the Python dashboard wait loop.

## Tests Run

- Focused red/green regression:
  - Before the fix, both new tests failed by dispatching source `1` before
    reading the queued second digit.
  - After the fix:
    `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q tests/test_parsers.py -k 'slow_refresh_polls_pending_second_digit or multidigit_source_hotkeys or number_hotkeys or single_ambiguous_digit' tests/test_dashboard_alt.py -k 'wait_loop_reads_pending_second_digit or multidigit_source_hotkeys or number_hotkeys or single_ambiguous_digit'`
    passed: `13 passed, 227 deselected`.
- `bash -n denon.sh`: passed.
- `python -m py_compile denon_dashboard_alt.py`: passed.
- `./test/run`: passed, `11` Bats tests.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q`: attempted, but collection
  entered pre-existing generated `rpmbuild-review-*` trees and failed with
  pytest import-file mismatch errors before running the real repo tests.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 pytest -q tests`: passed,
  `351 passed, 5 skipped`.

## Remaining Caveats

- The bare repository-wide pytest command is currently polluted by generated
  `rpmbuild-review-*` directories. The real checked-in Python tests pass when
  scoped to `tests/`, and the generated artifact trees were otherwise left
  untouched per the task constraints.
