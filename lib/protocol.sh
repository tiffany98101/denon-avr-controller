# shellcheck shell=bash
# lib/protocol.sh — Denon protocol command tables and zone mapping.
# Phase 2 adds the event parse table here.

# zone_prefix <zone> — protocol prefix for a zone ("" for main).
zone_prefix() {
  case "$1" in
    1|"") printf '' ;;
    2)    printf 'Z2' ;;
    3)    printf 'Z3' ;;
    *)    echo "denon: unsupported zone '$1'" >&2; return 1 ;;
  esac
}

# zone_cmd <zone> <verb> [value] — build the protocol command for a zone-aware
# verb. Main zone uses the classic prefixes (MV/MU/SI/ZM); other zones use the
# ZN combined prefix.
zone_cmd() {
  local zone="$1" verb="$2" value="${3:-}" zp
  zp=$(zone_prefix "$zone") || return 1
  case "$verb" in
    power)
      case "$value" in
        on)     [[ -z "$zp" ]] && printf 'ZMON'  || printf '%sON' "$zp" ;;
        off)    [[ -z "$zp" ]] && printf 'ZMOFF' || printf '%sOFF' "$zp" ;;
        query)  [[ -z "$zp" ]] && printf 'ZM?'   || printf '%s?' "$zp" ;;
        *) return 1 ;;
      esac
      ;;
    vol)
      case "$value" in
        up)    [[ -z "$zp" ]] && printf 'MVUP'   || printf '%sUP' "$zp" ;;
        down)  [[ -z "$zp" ]] && printf 'MVDOWN' || printf '%sDOWN' "$zp" ;;
        query) [[ -z "$zp" ]] && printf 'MV?'    || printf '%s?' "$zp" ;;
        *)
          [[ "$value" =~ ^[0-9]+$ ]] || return 1
          [[ -z "$zp" ]] && printf 'MV%02d' "$value" || printf '%s%02d' "$zp" "$value"
          ;;
      esac
      ;;
    mute)
      case "$value" in
        on)    printf '%sMUON' "$zp" ;;   # main: MUON, zone2: Z2MUON
        off)   printf '%sMUOFF' "$zp" ;;
        query) printf '%sMU?' "$zp" ;;
        *) return 1 ;;
      esac
      ;;
    input)
      [[ -n "$value" ]] || return 1
      [[ -z "$zp" ]] && printf 'SI%s' "$value" || printf '%s%s' "$zp" "$value"
      ;;
    *)
      echo "denon: unknown zone verb '$verb'" >&2
      return 1
      ;;
  esac
}

# protocol_valid_cmd <string> — sanity-check a raw passthrough command.
# Uppercase protocol charset; rejects control chars and shell surprises.
protocol_valid_cmd() {
  [[ "$1" =~ ^[A-Z0-9][A-Z0-9\ ?:./+%-]*$ ]]
}

# protocol_http_query_source <command> — which StatusLite document answers a
# given telnet query when only HTTP is available: "main", "zone2", or "" when
# the query has no HTTP equivalent.
protocol_http_query_source() {
  case "$1" in
    PW\?|MV\?|MU\?|SI\?|ZM\?) printf 'main' ;;
    Z2\?|Z2MU\?)              printf 'zone2' ;;
    *)                        printf '' ;;
  esac
}

# protocol_http_synthesize <command> <statuslite-xml> — synthesize the telnet
# reply line for a query from StatusLite XML. Mirrors what the AVR would have
# said on telnet so callers parse one format.
protocol_http_synthesize() {
  local cmd="$1" xml="$2" val mute
  case "$cmd" in
    PW\?)
      val=$(printf '%s' "$xml" | sed -n 's:.*<Power><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$val" ]] && printf 'PW%s\n' "$val"
      ;;
    ZM\?)
      val=$(printf '%s' "$xml" | sed -n 's:.*<ZonePower><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$val" ]] && printf 'ZM%s\n' "$val"
      ;;
    MV\?)
      val=$(printf '%s' "$xml" | sed -n 's:.*<MasterVolume><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$val" ]] && printf 'MV%s\n' "${val#-}"
      ;;
    MU\?)
      mute=$(printf '%s' "$xml" | sed -n 's:.*<Mute><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$mute" ]] && printf 'MU%s\n' "${mute^^}"
      ;;
    SI\?)
      val=$(printf '%s' "$xml" | sed -n 's:.*<InputFuncSelect><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$val" ]] && printf 'SI%s\n' "$val"
      ;;
    Z2\?)
      val=$(printf '%s' "$xml" | sed -n 's:.*<Power><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$val" ]] && printf 'Z2%s\n' "$val"
      val=$(printf '%s' "$xml" | sed -n 's:.*<MasterVolume><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$val" ]] && printf 'Z2%s\n' "${val#-}"
      ;;
    Z2MU\?)
      mute=$(printf '%s' "$xml" | sed -n 's:.*<Mute><value>\([^<]*\)</value>.*:\1:p')
      [[ -n "$mute" ]] && printf 'Z2MU%s\n' "${mute^^}"
      ;;
  esac
}
