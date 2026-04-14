#!/usr/bin/env bash
set -u

SCRIPT="./denon_release_candidate.sh"
DESTRUCTIVE=0
KEEP_ARTIFACTS=0
SNAPSHOT_DIR=""
FAILURES=0

usage() {
  cat <<'EOF'
Usage:
  denon_automated_test.sh [--script PATH] [--destructive] [--snapshot-dir DIR] [--keep-artifacts]

Notes:
  - Default mode is read-only and safe.
  - --destructive adds reversible AVR state-change checks.
  - For discovery-free testing, export DENON_IP before running.
  - Optional source test knobs:
      DENON_TEST_SOURCE_A=heos
      DENON_TEST_SOURCE_B=tv
      DENON_TEST_ZONE2_A=19
      DENON_TEST_ZONE2_B=10
EOF
}

log() { printf '[test] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) SCRIPT="$2"; shift 2 ;;
    --destructive) DESTRUCTIVE=1; shift ;;
    --snapshot-dir) SNAPSHOT_DIR="$2"; shift 2 ;;
    --keep-artifacts) KEEP_ARTIFACTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -f "$SCRIPT" ]] || { echo "Script not found: $SCRIPT" >&2; exit 1; }

TMPROOT="${SNAPSHOT_DIR:-$(mktemp -d)}"
OUT="$TMPROOT/stdout.txt"
ERR="$TMPROOT/stderr.txt"

cleanup() {
  if [[ "$KEEP_ARTIFACTS" != "1" && -z "${SNAPSHOT_DIR:-}" ]]; then
    rm -rf "$TMPROOT"
  fi
}
trap cleanup EXIT

run_cmd() {
  local label="$1"
  shift
  if "$@" >"$OUT" 2>"$ERR"; then
    pass "$label"
    sed 's/^/  | /' "$OUT" || true
    return 0
  else
    fail "$label"
    sed 's/^/  | /' "$OUT" || true
    sed 's/^/  ! /' "$ERR" >&2 || true
    return 1
  fi
}

run_expect_output() {
  local label="$1"
  shift
  if "$@" >"$OUT" 2>"$ERR" && [[ -s "$OUT" ]]; then
    pass "$label"
    sed 's/^/  | /' "$OUT" || true
    return 0
  fi
  fail "$label"
  sed 's/^/  | /' "$OUT" || true
  sed 's/^/  ! /' "$ERR" >&2 || true
  return 1
}

SOURCE_A="${DENON_TEST_SOURCE_A:-heos}"
SOURCE_B="${DENON_TEST_SOURCE_B:-tv}"
ZONE2_A="${DENON_TEST_ZONE2_A:-19}"
ZONE2_B="${DENON_TEST_ZONE2_B:-10}"

log "Syntax checks"
run_cmd "bash -n $SCRIPT" bash -n "$SCRIPT"
if command -v zsh >/dev/null 2>&1; then
  run_cmd "zsh -n $SCRIPT" zsh -n "$SCRIPT"
else
  warn "zsh not installed; skipping zsh -n"
fi

log "Direct execution read-only checks"
run_expect_output "help" "$SCRIPT" help
run_expect_output "doctor" "$SCRIPT" doctor
run_expect_output "discover" "$SCRIPT" discover
run_expect_output "status" "$SCRIPT" status
run_expect_output "status --json" "$SCRIPT" status --json
run_expect_output "info --json" "$SCRIPT" info --json
run_expect_output "sources" "$SCRIPT" sources
run_expect_output "zone2 sources" "$SCRIPT" zone2 sources
run_expect_output "zone2 status" "$SCRIPT" zone2 status
run_expect_output "raw get 3" "$SCRIPT" raw get 3
run_expect_output "raw get 4" "$SCRIPT" raw get 4
run_expect_output "raw get 7" "$SCRIPT" raw get 7
run_expect_output "raw get 12" "$SCRIPT" raw get 12
run_expect_output "snapshot" "$SCRIPT" snapshot "$TMPROOT/snapshot"

for f in ip.txt metadata.txt type_3.xml type_4.xml type_7.xml type_12.xml; do
  if [[ -f "$TMPROOT/snapshot/$f" ]]; then
    pass "snapshot contains $f"
  else
    fail "snapshot missing $f"
  fi
done

log "Shell sourcing checks"
run_expect_output "bash source + status" bash -lc "source '$SCRIPT'; type denon >/dev/null && denon status"
if command -v zsh >/dev/null 2>&1; then
  run_expect_output "zsh source + status" zsh -lc "autoload -Uz compinit; compinit; source '$SCRIPT'; whence denon >/dev/null && denon status"
else
  warn "zsh not installed; skipping zsh source test"
fi

if [[ "$DESTRUCTIVE" == "1" ]]; then
  log "Reversible state-change checks"

  INITIAL_ZONE2_POWER="$("$SCRIPT" zone2 status 2>/dev/null | sed -n 's/^Zone 2 | Power: \([^|]*\) |.*/\1/p' | head -n 1)"
  if [[ -n "${INITIAL_ZONE2_POWER:-}" ]]; then
    log "Initial Zone 2 power: $INITIAL_ZONE2_POWER"
  else
    warn "Could not determine initial Zone 2 power state"
  fi

  run_expect_output "mute" "$SCRIPT" mute
  run_expect_output "unmute" "$SCRIPT" unmute
  run_expect_output "volume up 1" "$SCRIPT" up 1
  run_expect_output "volume down 1" "$SCRIPT" down 1

  run_expect_output "source switch A ($SOURCE_A)" "$SCRIPT" source "$SOURCE_A"
  run_expect_output "source switch B ($SOURCE_B)" "$SCRIPT" source "$SOURCE_B"

  run_expect_output "zone2 on" "$SCRIPT" zone2 on
  run_expect_output "zone2 source A ($ZONE2_A)" "$SCRIPT" zone2 source "$ZONE2_A"
  run_expect_output "zone2 source B ($ZONE2_B)" "$SCRIPT" zone2 source "$ZONE2_B"
  run_expect_output "zone2 off" "$SCRIPT" zone2 off

  run_expect_output "sound mode stereo" "$SCRIPT" mode stereo
  run_expect_output "sound mode movie" "$SCRIPT" mode movie

  "$SCRIPT" track >"$OUT" 2>"$ERR" || true
  if grep -qE '^(Title:|Track info unavailable)' "$OUT"; then
    pass "track endpoint"
    sed 's/^/  | /' "$OUT" || true
  else
    fail "track endpoint"
    sed 's/^/  | /' "$OUT" || true
    sed 's/^/  ! /' "$ERR" >&2 || true
  fi

  run_expect_output "play" "$SCRIPT" play
  run_expect_output "pause" "$SCRIPT" pause
  run_expect_output "next" "$SCRIPT" next
  run_expect_output "prev" "$SCRIPT" prev

  if [[ "${INITIAL_ZONE2_POWER:-}" == "OFF" ]]; then
    run_expect_output "restore zone2 off" "$SCRIPT" zone2 off
  elif [[ "${INITIAL_ZONE2_POWER:-}" == "ON" ]]; then
    run_expect_output "restore zone2 on" "$SCRIPT" zone2 on
  fi
else
  log "Skipping destructive tests. Re-run with --destructive to exercise AVR control paths."
fi

if [[ "$FAILURES" -eq 0 ]]; then
  log "All selected tests passed"
  exit 0
fi

warn "$FAILURES test(s) failed"
exit 1
