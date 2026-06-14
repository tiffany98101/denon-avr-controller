# shellcheck shell=bash
# lib/transport.sh — avr_send: the single function every protocol command goes
# through, implementing the routing decision tree (ARCHITECTURE.md §4).
#
#   avr_send [options] <device-or-host> <command>
#     --expect PREFIX   wait for a reply line starting with PREFIX
#     --timeout S       reply window (default 1s; Denon answers within 200ms)
#     --http            skip telnet, go straight to the HTTP route
#     --quiet           suppress reply lines on stdout
#
# Exit codes (consumed by scripts and spotify-dj — keep stable):
#   0  sent; expected reply seen (or fire-and-forget sent)
#   2  sent; no reply within timeout
#   3  telnet busy AND HTTP failed
#   4  host unreachable
#   5  unsupported command for this model (capabilities gate)
#
# Test/ops overrides: DENON_TELNET_PORT (default 23),
# DENON_HTTP_PORTS (default "8080 80").

# Route 1 (monitor) plugs in here in phase 2: monitord-owned connection via
# cmd.fifo. Until then _avr_monitor_send is undefined and the route is skipped.

_avr_resolve_host() {
  local target="$1"
  if declare -F config_load >/dev/null 2>&1; then
    if config_load "$target" 2>/dev/null && [[ -n "$DENON_CFG_HOST" ]]; then
      printf '%s' "$DENON_CFG_HOST"
      return 0
    fi
  fi
  printf '%s' "$target"
}

_avr_urlencode() {
  local s="$1"
  s=${s//%/%25}
  s=${s// /%20}
  s=${s//\?/%3F}
  s=${s//+/%2B}
  s=${s//&/%26}
  s=${s//#/%23}
  printf '%s' "$s"
}

# One-shot telnet exchange over ncat. Prints reply lines (LF-terminated).
# Returns: 0 reply-ok/sent, 2 expect-timeout, 7 refused, 8 unreachable.
#
# stdin must stay open for the reply window: closing it FINs the socket and
# the AVR (and ncat -l on the fake) drops replies still in flight. The -i
# idle timeout covers the real AVR, which never closes its end.
_avr_telnet_oneshot() {
  local host="$1" port="$2" cmd="$3" expect="$4" timeout="$5"
  local err out rc line found=1
  err=$(mktemp)
  out=$( { printf '%s\r' "$cmd"; sleep "$timeout"; } \
        | ncat -w 2 -i "$timeout" "$host" "$port" 2>"$err" )
  rc=$?
  if (( rc != 0 )) && ! grep -qi 'idle timeout' "$err"; then
    if grep -qi 'refused' "$err"; then
      rm -f "$err"
      return 7
    fi
    rm -f "$err"
    return 8
  fi
  rm -f "$err"
  [[ -z "$expect" ]] && found=0
  while IFS= read -r -d $'\r' line; do
    line=${line#$'\n'}
    [[ -n "$line" ]] || continue
    printf '%s\n' "$line"
    [[ -n "$expect" && "$line" == "$expect"* ]] && found=0
  done <<<"$out"$'\r'
  if (( found != 0 )); then
    return 2
  fi
  return 0
}

# HTTP route: fire the command at formiPhoneAppDirect.xml; answer queries from
# the StatusLite documents. Returns 0 sent/answered, 2 sent-but-unobservable,
# 8 http unreachable.
_avr_http_oneshot() {
  local host="$1" cmd="$2" expect="$3" quiet="$4"
  local ports="${DENON_HTTP_PORTS:-8080 80}" port base="" code lite_src xml reply
  for port in $ports; do
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
      "http://$host:$port/goform/formiPhoneAppDirect.xml?$(_avr_urlencode "$cmd")" 2>/dev/null)
    if [[ "$code" == 2* ]]; then
      base="http://$host:$port"
      break
    fi
  done
  [[ -n "$base" ]] || return 8

  lite_src=$(protocol_http_query_source "$cmd")
  if [[ -z "$lite_src" ]]; then
    # Fire-and-forget over HTTP; queries we cannot answer report exit 2.
    [[ "$cmd" == *\? ]] && return 2
    return 0
  fi
  case "$lite_src" in
    main)  xml=$(curl -s -m 3 "$base/goform/formMainZone_MainZoneXmlStatusLite.xml" 2>/dev/null) ;;
    zone2) xml=$(curl -s -m 3 "$base/goform/formZone2_Zone2XmlStatusLite.xml" 2>/dev/null) ;;
  esac
  [[ -n "$xml" ]] || return 2
  reply=$(protocol_http_synthesize "$cmd" "$xml")
  [[ -n "$reply" ]] || return 2
  (( quiet )) || printf '%s\n' "$reply"
  if [[ -n "$expect" && "$reply" != "$expect"* ]]; then
    return 2
  fi
  return 0
}

avr_send() {
  local expect="" timeout="" force_http=0 quiet=0
  local -a pos=()
  while (( $# )); do
    case "$1" in
      --expect)  expect="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --http)    force_http=1; shift ;;
      --quiet)   quiet=1; shift ;;
      --)        shift; pos+=("$@"); break ;;
      *)         pos+=("$1"); shift ;;
    esac
  done
  if (( ${#pos[@]} != 2 )); then
    echo "usage: avr_send [--expect PREFIX] [--timeout S] [--http] [--quiet] <device-or-host> <command>" >&2
    return 64
  fi
  local target="${pos[0]}" cmd="${pos[1]}" host rc telnet_rc
  timeout="${timeout:-${DENON_SEND_TIMEOUT:-1}}"
  host=$(_avr_resolve_host "$target")
  if [[ -z "$host" ]]; then
    echo "denon: no host for device '$target'" >&2
    return 4
  fi

  # Capabilities gate (populated in phase 4); absent map = permissive.
  if declare -F capabilities_allows >/dev/null 2>&1; then
    if ! capabilities_allows "$cmd"; then
      echo "denon: command '$cmd' not supported by ${DENON_CFG_MODEL:-this model}" >&2
      return 5
    fi
  fi

  # Route 1: monitord-owned connection (phase 2).
  if (( ! force_http )) && declare -F _avr_monitor_send >/dev/null 2>&1; then
    if _avr_monitor_send "$target" "$host" "$cmd" "$expect" "$timeout" "$quiet"; then
      return 0
    else
      rc=$?
      # 9 = monitor not running/stale: fall through to direct routes.
      (( rc != 9 )) && return "$rc"
    fi
  fi

  # Route 2: direct one-shot telnet.
  if (( ! force_http )); then
    local out
    out=$(_avr_telnet_oneshot "$host" "${DENON_TELNET_PORT:-23}" "$cmd" "$expect" "$timeout")
    telnet_rc=$?
    if (( telnet_rc == 0 || telnet_rc == 2 )); then
      [[ -n "$out" ]] && (( ! quiet )) && printf '%s\n' "$out"
      return "$telnet_rc"
    fi
  else
    telnet_rc=7
  fi

  # Route 3: HTTP fallback (telnet refused/unreachable or --http).
  _avr_http_oneshot "$host" "$cmd" "$expect" "$quiet"
  rc=$?
  (( rc == 0 || rc == 2 )) && return "$rc"

  # Route 4: nothing answered.
  if (( telnet_rc == 7 )); then
    echo "denon: telnet busy and HTTP failed for $host" >&2
    return 3
  fi
  echo "denon: host $host unreachable" >&2
  return 4
}
