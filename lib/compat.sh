# shellcheck shell=bash
# lib/compat.sh — bridge between the legacy `denon` surface and the v2
# architecture: global flag handling (--avr) and dispatch of v2-only
# subcommands. Called from inside denon() after its init, so the legacy
# nested helpers (_denon_discover, ...) are in scope as fallbacks.

# denon_v2_global_flags <args...> — strip v2 global flags, leaving the rest in
# DENON_V2_ARGS. --avr NAME selects a config device and pins DENON_IP so every
# legacy code path targets it too.
denon_v2_global_flags() {
  DENON_V2_ARGS=()
  local avr=""
  while (( $# )); do
    case "$1" in
      --avr)
        if (( $# < 2 )); then
          echo "denon: --avr requires a device name" >&2
          return 64
        fi
        avr="$2"
        shift 2
        ;;
      --avr=*)
        avr="${1#--avr=}"
        shift
        ;;
      *)
        DENON_V2_ARGS+=("$1")
        shift
        ;;
    esac
  done
  if [[ -n "$avr" ]]; then
    config_load "$avr" || return 1
    if [[ -n "$DENON_CFG_HOST" ]]; then
      export DENON_IP="$DENON_CFG_HOST"
    else
      echo "denon: device '$avr' has no host configured" >&2
      return 1
    fi
  fi
  return 0
}

# denon_v2_target_host — host for v2 commands: DENON_IP override, then the
# loaded config device, then legacy discovery.
denon_v2_target_host() {
  local host="${DENON_IP:-${DENON_CFG_HOST:-}}"
  if [[ -z "$host" ]] && declare -F _denon_discover >/dev/null 2>&1; then
    host=$(_denon_discover) || host=""
  fi
  if [[ -z "$host" ]]; then
    echo "denon: no receiver configured (set DENON_IP, run 'denon setip <ip>', or configure a device)" >&2
    return 4
  fi
  printf '%s' "$host"
}

# denon_v2_handles <cmd> [args...] — true when v2 dispatch owns this command.
denon_v2_handles() {
  local cmd="${1,,}"
  case "$cmd" in
    raw)
      # `raw get/set` keep their legacy HTTPS get_config semantics;
      # anything else is the v2 protocol passthrough.
      case "${2:-}" in
        get|set|dump|types|help|-h|--help|"") return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

denon_v2_dispatch() {
  local cmd="${1,,}"
  shift
  case "$cmd" in
    raw) denon_v2_raw "$@" ;;
    *)
      echo "denon: internal error: v2 dispatch for unknown command '$cmd'" >&2
      return 70
      ;;
  esac
}

# denon raw <CMD...> [--http] — protocol passthrough escape hatch.
denon_v2_raw() {
  local http=0 a
  local -a words=()
  for a in "$@"; do
    case "$a" in
      --http) http=1 ;;
      *) words+=("$a") ;;
    esac
  done
  if (( ${#words[@]} == 0 )); then
    echo "Usage: denon raw <COMMAND> [--http]   (or: denon raw {get|set} ... for config XML)" >&2
    return 64
  fi
  local cmd="${words[*]}"
  cmd=${cmd^^}
  if ! protocol_valid_cmd "$cmd"; then
    echo "denon: invalid protocol command: '$cmd'" >&2
    return 64
  fi
  local host
  host=$(denon_v2_target_host) || return $?
  local -a opts=()
  (( http )) && opts+=(--http)
  avr_send "${opts[@]}" --timeout "${DENON_SEND_TIMEOUT:-1}" -- "$host" "$cmd"
}
