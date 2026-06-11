#!/usr/bin/env bash
# denon.sh — Denon AVR controller
# Version: 1.2.0-beta.9
DENON_CONTROLLER_NAME="${DENON_CONTROLLER_NAME:-denon-avr-controller}"
DENON_CONTROLLER_VERSION="${DENON_CONTROLLER_VERSION:-1.2.0-beta.9}"
# Source this from bash, or run it directly:
#   source ~/denon.sh
#
# Direct use:
#   ./denon.sh status
#
# For testing without discovery:
#   export DENON_IP=192.0.2.10

_denon_source_v2_libs() {
  local script_dir lib_dir file
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P) || script_dir=""
  for lib_dir in "$script_dir/lib" "/usr/share/denon/lib"; do
    [[ -d "$lib_dir" ]] || continue
    for file in config.sh protocol.sh transport.sh compat.sh; do
      # shellcheck source=/dev/null
      [[ -r "$lib_dir/$file" ]] && source "$lib_dir/$file"
    done
    return 0
  done
}

_denon_source_v2_libs

_denon_lower() {
  printf '%s' "${1,,}"
}

denon() {
  # ── Discovery ────────────────────────────────────────────────────────────

  _denon_find_first_receiver() {
    while read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if _denon_is_receiver "$candidate"; then
        printf '%s' "$candidate"
        return 0
      fi
    done
    return 1
  }

  _denon_known_hosts() {
    {
      if command -v arp >/dev/null 2>&1; then
        arp -n 2>/dev/null | awk '/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1}'
      fi
      if command -v ip >/dev/null 2>&1; then
        ip -4 neigh show 2>/dev/null | awk '/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1}'
      fi
      if [[ -r /proc/net/arp ]]; then
        awk 'NR > 1 {print $1}' /proc/net/arp
      fi
    } | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !seen[$0]++'
  }

  _denon_lan_hosts() {
    command -v ip >/dev/null 2>&1 || return 0

    ip -4 route show scope link 2>/dev/null |
      awk '
        $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
          split($1, cidr, "/")
          split(cidr[1], octets, ".")
          mask=cidr[2] + 0
          if (mask < 24 || mask > 30) next
          size=2 ^ (32 - mask)
          prefix=octets[1] "." octets[2] "." octets[3] "."
          start=int(octets[4] / size) * size + 1
          end=start + size - 3
          if (mask == 24) { start=1; end=254 }
          for (i=start; i<=end; i++) print prefix i
          exit
        }
      '
  }

  _denon_ssdp_candidates() {
    command -v nc >/dev/null 2>&1 || return 0

    local mx="${DENON_SSDP_MX:-1}"
    local timeout="${DENON_SSDP_TIMEOUT:-2}"
    local ssdp_msg
    ssdp_msg=$'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: '"$mx"$'\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n'

    _denon_debug "ssdp search to 239.255.255.250:1900"

    (
      printf '%s' "$ssdp_msg" |
        nc -u -w "$timeout" 239.255.255.250 1900 2>/dev/null
    ) |
      sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:.*\/\/\([0-9][0-9.]*\).*/\1/p' |
      awk '!seen[$0]++'
  }

  _denon_avahi_candidates() {
    command -v avahi-browse >/dev/null 2>&1 || return 0

    local svc type _iface proto name service _domain _hostname address _port txt
    local -a batch

    for svc in _heos-audio._tcp _airplay._tcp; do
      _denon_debug "avahi: browsing $svc"
      batch=()
      while IFS=';' read -r type _iface proto name service _domain _hostname address _port txt; do
        [[ "$type" == "=" ]]    || continue
        [[ "$proto" == "IPv4" ]] || continue
        [[ -n "$address" ]]     || continue
        if [[ "$svc" == "_airplay._tcp" ]]; then
          printf '%s' "$txt" | grep -qi 'manufacturer=Denon' || continue
        fi
        batch+=("$address")
      done < <(avahi-browse -rtp "$svc" 2>/dev/null)

      (( ${#batch[@]} == 0 )) && continue

      if (( ${#batch[@]} > 1 )); then
        printf 'Warning: Multiple Denon receivers found via Avahi (%s): %s — set DENON_IP to pin one\n' \
          "$svc" "${batch[*]}" >&2
      fi
      printf '%s\n' "${batch[@]}"
      return 0
    done
  }

  _denon_ip_cache_path() {
    local profile="${DENON_PROFILE:-}"
    if [[ -n "$profile" ]]; then
      _denon_validate_stored_name "profile" "$profile" || return 1
      printf '%s/.cache/denon_ip.%s' "$HOME" "$profile"
      return 0
    fi
    printf '%s/.cache/denon_ip' "$HOME"
  }

  _denon_no_verify_enabled() {
    [[ "${DENON_NO_VERIFY_ACTIVE:-0}" == "1" ]]
  }

  _denon_args_have_json() {
    local arg
    for arg in "$@"; do
      [[ "$(_denon_lower "$arg")" == "--json" || "$(_denon_lower "$arg")" == "json" ]] && return 0
    done
    return 1
  }

  _denon_unverified_suffix() {
    _denon_no_verify_enabled && printf ' (unverified)'
  }

  _denon_verified_json_bool() {
    if _denon_no_verify_enabled; then
      printf 'false'
    else
      printf 'true'
    fi
  }

  _denon_write_command_requires_lock() {
    local cmd="$1"
    shift || true
    local sub="${1:-}"

    case "$cmd" in
      raw) [[ "$(_denon_lower "$sub")" == "set" ]] ;;
      source|on|off|xbox|xfinity|bluray|tv|phono|mute|unmute|toggle|movie|game|night|music|mode|dyn-eq|dyn-vol|cinema-eq|multeq|bass|treble|play|pause|stop|next|prev|previous|preset)
        return 0
        ;;
      heos)
        [[ -z "$sub" ]] && return 0
        case "$(_denon_lower "$sub")" in
          play|pause|stop|next|prev|previous|repeat|shuffle|play-stream) return 0 ;;
          *) return 1 ;;
        esac
        ;;
      vol)
        [[ -n "$sub" ]]
        ;;
      up|down)
        return 0
        ;;
      sleep|qs|quick|quick-select)
        [[ -n "$sub" ]]
        ;;
      zone2)
        case "$(_denon_lower "$sub")" in
          source|on|off|mute|unmute|vol|volume|up|down) return 0 ;;
          sleep) [[ -n "${2:-}" ]] ;;
          *) return 1 ;;
        esac
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_close_fd() {
    local fd="$1"
    [[ "$fd" =~ ^[0-9]+$ ]] || return 1
    exec {fd}>&-
  }

  _denon_acquire_write_lock() {
    [[ "${DENON_LOCK:-0}" == "1" ]] || return 0

    if ! command -v flock >/dev/null 2>&1; then
      echo "Warning: DENON_LOCK=1 requested but flock is not available; proceeding without serialization" >&2
      return 0
    fi

    local lock_path lock_timeout
    lock_path=$(_denon_ip_cache_path) || return 1
    lock_timeout="${DENON_LOCK_TIMEOUT:-3}"
    mkdir -p "$(dirname "$lock_path")" || return 1

    exec {denon_write_lock_fd}>>"$lock_path"
    if ! flock -w "$lock_timeout" "$denon_write_lock_fd"; then
      echo "Error: timed out waiting ${lock_timeout}s for Denon write lock: $lock_path" >&2
      _denon_close_fd "$denon_write_lock_fd" || true
      return 75
    fi
    DENON_WRITE_LOCK_FD="$denon_write_lock_fd"
  }

  _denon_release_write_lock() {
    if [[ -n "${DENON_WRITE_LOCK_FD:-}" ]]; then
      flock -u "$DENON_WRITE_LOCK_FD" 2>/dev/null || true
      _denon_close_fd "$DENON_WRITE_LOCK_FD" || true
      DENON_WRITE_LOCK_FD=""
    fi
  }

  _denon_discover() {
    local cache
    local default_ip="${DENON_DEFAULT_IP:-}"
    local ip=""
    cache=$(_denon_ip_cache_path) || return 1

    if [[ -n "${DENON_IP:-}" ]]; then
      if _denon_is_receiver "$DENON_IP"; then
        printf '%s' "$DENON_IP"
        return 0
      fi
      echo "Warning: DENON_IP=$DENON_IP did not respond as a Denon receiver" >&2
    fi

    if [[ -f "$cache" ]]; then
      local cached_ip cache_ttl cache_mtime cache_age
      cache_ttl="${DENON_CACHE_TTL_SECONDS:-3600}"
      cache_mtime=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0)
      cache_age=$(( $(date +%s) - cache_mtime ))
      if (( cache_age <= cache_ttl )); then
        cached_ip=$(<"$cache")
        if ! _denon_is_ipv4 "$cached_ip"; then
          _denon_debug "ignoring invalid cached receiver IP: $cached_ip"
        elif _denon_is_receiver "$cached_ip"; then
          printf '%s' "$cached_ip"
          return 0
        fi
      fi
    fi

    if [[ -n "$default_ip" ]]; then
      if _denon_is_receiver "$default_ip"; then
        mkdir -p "$(dirname "$cache")"
        printf '%s' "$default_ip" >"$cache"
        printf '%s' "$default_ip"
        return 0
      fi
    fi

    ip=$(_denon_avahi_candidates | _denon_find_first_receiver)
    if [[ -n "$ip" ]]; then
      _denon_debug "avahi discovery: $ip"
      mkdir -p "$(dirname "$cache")"
      printf '%s' "$ip" >"$cache"
      printf '%s' "$ip"
      return 0
    fi

    ip=$(_denon_ssdp_candidates | _denon_find_first_receiver)
    if [[ -n "$ip" ]]; then
      mkdir -p "$(dirname "$cache")"
      printf '%s' "$ip" >"$cache"
      printf '%s' "$ip"
      return 0
    fi

    ip=$(_denon_known_hosts | _denon_find_first_receiver)
    if [[ -n "$ip" ]]; then
      mkdir -p "$(dirname "$cache")"
      printf '%s' "$ip" >"$cache"
      printf '%s' "$ip"
      return 0
    fi

    if [[ "${DENON_SCAN_LAN:-0}" == "1" ]]; then
      ip=$(_denon_lan_hosts | _denon_find_first_receiver)
      if [[ -n "$ip" ]]; then
        mkdir -p "$(dirname "$cache")"
        printf '%s' "$ip" >"$cache"
        printf '%s' "$ip"
        return 0
      fi
    fi

    return 1
  }

  _denon_is_receiver() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    _denon_curl -G "https://$candidate:10443/ajax/globals/get_config" \
      --data-urlencode "type=3" 2>/dev/null | grep -q "Denon"
  }

  _denon_is_ipv4() {
    printf '%s' "$1" | awk -F . '
      NF != 4 { exit 1 }
      {
        for (i=1; i<=4; i++) {
          if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
        }
      }
    '
  }

  _denon_is_unsigned_integer() {
    printf '%s' "$1" | awk '/^[0-9]+$/ { found=1 } END { exit found ? 0 : 1 }'
  }

  _denon_is_heos_pid() {
    [[ -n "${1:-}" && "$1" =~ ^-?[0-9]+$ ]]
  }

  _denon_is_number() {
    printf '%s' "$1" | awk '/^-?[0-9]+([.][0-9]+)?$/ { found=1 } END { exit found ? 0 : 1 }'
  }

  _denon_validate_volume_raw() {
    local raw="$1"
    local label="${2:-volume}"

    if ! _denon_is_unsigned_integer "$raw"; then
      echo "Error: ${label} raw volume must be numeric" >&2
      return 1
    fi
    if awk -v raw="$raw" 'BEGIN { exit !(raw > 980) }'; then
      echo "Error: ${label} raw volume is above the supported Denon range" >&2
      return 1
    fi
  }

  _denon_is_signed_step() {
    printf '%s' "$1" | awk '/^[+-][0-9]+([.][0-9]+)?$/ { found=1 } END { exit found ? 0 : 1 }'
  }

  _denon_usage() {
    cat <<'EOF'
Denon AVR controller

Usage:
  denon <command> [arguments]
  denon.sh <command> [arguments]

Receiver status:
  denon info                 Show receiver name, IP, main zone, Zone 2, and sources
  denon info --json          Print detailed receiver information as JSON
  denon data fields --all    Show all data fields known to this tool and where they come from
  denon data fields --available
                             Query the AVR and show known fields that currently have values
  denon data dump --readable Query all safe read-only sources and print a grouped report
  denon data dump --all      Same as data dump --readable
  denon data dump --json     Query all safe read-only sources and print structured JSON
  denon data dump --raw [--full]
                             Query all safe read-only sources and print labeled raw responses
  denon data discover [--json]
                             Discover read-only web/AJAX endpoints exposed by the AVR UI
  denon data capabilities [--json] [--source file] [--probe-safe]
                             Inventory advertised Deviceinfo/AppCommand verbs; live probing is opt-in
  denon data summary [--json]
                             Show concise receiver diagnostics from safe read-only surfaces
  denon status               Show main zone power, source, volume, and mute state
  denon status --json        Print main zone status as JSON
  denon signal-debug         Show raw input/signal diagnostics without guessing a decoder
  denon rawstatus            Print raw XML returned by the AVR
  denon raw get <type>       Fetch a raw get_config type, for example 3, 4, 7, 12
  denon raw set <type> '<xml>'
                             Send a raw set_config payload
  denon raw dump [type ...]   Fetch raw get_config XML for common or supplied types
  denon raw types             List common get_config type numbers
  denon snapshot [dir]       Save core XML responses to a timestamped directory
  denon diff <snap-a> <snap-b>
                             Compare two snapshot directories
  denon doctor               Check dependencies, route, cache, and receiver reachability
  denon dashboard [--diagnostics] [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]
                             Show a one-shot or live receiver dashboard
                             Watch keys: ↑/↓=Volume, ←/→=Prev/Next, Space=Play/Pause, M=Mute, #=Source From List, Z=Zone, Q=Quit
  denon dashboard-alt [--compare-providers|--json] [--provider auto|direct|shell] [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]
                             Show the experimental Python dashboard preview; denon dashboard remains the stable default
                             Examples: denon dashboard-alt --provider auto
                                       denon dashboard-alt --provider direct --json
                                       denon dashboard-alt --compare-providers
  denon dashboard-ultra [--watch] [--interval seconds] [--tv] [--ascii|--unicode] [--color auto|always|never]
                             Show the ultrawide multi-panel dashboard (alternate to denon dashboard;
                             5-panel layout at 200+ columns, reduced at 120-199, stacked below 120)

Sources:
  denon sources              List main zone sources and mark the active one
  denon sources 2            List Zone 2 sources
  denon source <id|name>     Switch main zone source by index or name

Source display names:
  denon rename-source <id|name> "<new name>"
                             Set a local display name for a source
  denon source-names         List local custom source names
  denon clear-source-name <id|name>
                             Remove a local source display name

Sleep and Quick Select:
  denon sleep                Show main-zone sleep timer
  denon sleep 30             Set main-zone sleep timer to 30 minutes
  denon sleep off            Clear main-zone sleep timer
  denon qs 1                 Recall Quick Select 1
  denon qs save 1            Store current settings to Quick Select 1

Power and mute:
  denon on                   Turn main zone on
  denon off                  Turn main zone off
  denon mute                 Mute main zone
  denon unmute               Unmute main zone
  denon toggle [mute|power]  Flip mute or power (default: mute)

Volume:
  denon vol                  Show current main zone volume
  denon vol -35              Set absolute volume to -35 dB
  denon vol +2               Raise volume by 2 dB
  denon vol --fade -40       Gradually fade to -40 dB over 10 seconds
  denon vol --fade -40 --duration 30
                             Fade to -40 dB over 30 seconds
  denon up [dB]              Raise volume, default 1 dB
  denon down [dB]            Lower volume, default 1 dB

Quick source shortcuts:
  denon xfinity
  denon bluray
  denon xbox
  denon tv
  denon phono
  denon heos

Presets:
  denon movie
  denon game
  denon night
  denon music

Sound mode and media:
  denon mode <mode>          stereo, direct, pure, movie, music, game, auto
  denon dyn-eq <on|off>
  denon dyn-vol <off|light|medium|heavy>
  denon cinema-eq <on|off>
  denon multeq <reference|bypass-lr|flat|manual|off>
  denon bass <up|down|value>
  denon treble <up|down|value>
  denon play
  denon pause
  denon stop
  denon next
  denon prev
  denon track
  denon now

HEOS:
  denon heos                 Switch main zone to HEOS Music
  denon heos now
  denon heos play|pause|stop|next|prev
  denon heos queue [play <item>|remove <item>|move <from> <to>|clear|save <name>]
  denon heos groups
  denon heos group info [gid]
  denon heos group set <pid,pid,...>
  denon heos group volume [gid] <level>
  denon heos group mute [gid] <on|off>
  denon heos browse sources
  denon heos browse <sid|source-name> [cid]
  denon heos search <sid|source-name> "<query>" [criteria]
  denon heos play-stream <sid> <cid> <mid> [name]
  denon heos repeat <off|all|one>
  denon heos shuffle <on|off>
  denon heos update

Zone 2:
  denon zone2 status
  denon zone2 sources
  denon zone2 source <id|name>
  denon zone2 rename-source <id|name> "<new name>"
  denon zone2 clear-source-name <id|name>
  denon zone2 on
  denon zone2 off
  denon zone2 mute
  denon zone2 unmute
  denon zone2 vol <raw>
  denon zone2 volume <raw>
  denon zone2 up [dB]
  denon zone2 down [dB]
  denon zone2 sleep [minutes|off]

Discovery and setup:
  denon discover
  denon setip <ip>

Shell integration:
  denon completion install
  denon completion bash|zsh|fish

Configuration:
  DENON_IP
  DENON_DEFAULT_IP
  DENON_SCAN_LAN=1
  DENON_MAX_VOLUME_DB
  DENON_VOLUME_STEP_DB
  DENON_SOURCE_ALIASES
  DENON_CURL_CONNECT_TIMEOUT
  DENON_CURL_MAX_TIME
  DENON_CURL_INSECURE=1
  DENON_CURL_CACERT
  DENON_CURL_PINNEDPUBKEY
  DENON_CACHE_TTL_SECONDS
  DENON_LOCK=1
  DENON_LOCK_TIMEOUT=3
  DENON_SSDP_TIMEOUT
  DENON_SSDP_MX
  DENON_HEOS_PID
  DENON_HEOS_GID
  DENON_HEOS_HELPER
  DENON_DASHBOARD_ALT_HELPER
  DENON_HEOS_TIMEOUT
  DENON_DATA_DISCOVERY_MAX_TYPE=30
  DENON_DEBUG=1

Notes:
  Commands are case-insensitive.
  Source display names are local aliases; they do not rename sources inside the receiver.
  "data fields --all" lists fields/endpoints known to this tool, not hidden firmware internals.
  Live data/dump modes use GET/query-only network paths and may expose serial numbers, MAC addresses,
  network identifiers, account-related fields, or other receiver-provided sensitive data.
  Examples: denon data fields --all | denon data fields --available | denon data summary | denon data dump --readable | denon data dump --json | denon data dump --raw | denon data capabilities --json
  The runtime script requires bash and can be run directly or via the installed denon wrapper.
  Shell completions are available for bash, zsh, and fish.
  Pass --quiet or -q before or after any command to suppress stdout output.
  Pass --silent before or after any command to suppress both stdout and stderr.
  Pass --no-verify before or after any write command to skip set-then-verify polling.
EOF
  }

  # ── Internal helpers ──────────────────────────────────────────────────────

  _denon_debug() {
    [[ "${DENON_DEBUG:-0}" == "1" ]] || return 0
    printf '[denon] %s\n' "$*" >&2
  }

  _denon_iso_now() {
    date '+%Y-%m-%dT%H:%M:%S%z'
  }

  _denon_curl_tls_args() {
    DENON_CURL_TLS_ARGS=()

    if [[ -n "${DENON_CURL_PINNEDPUBKEY+x}" && -z "${DENON_CURL_PINNEDPUBKEY}" ]]; then
      echo "Error: DENON_CURL_PINNEDPUBKEY is set but empty" >&2
      return 1
    fi
    if [[ -n "${DENON_CURL_CACERT+x}" && -z "${DENON_CURL_CACERT}" ]]; then
      echo "Error: DENON_CURL_CACERT is set but empty" >&2
      return 1
    fi

    if [[ "${DENON_CURL_INSECURE:-}" == "1" ]]; then
      DENON_CURL_TLS_ARGS+=("-k")
    elif [[ -n "${DENON_CURL_CACERT:-}" ]]; then
      DENON_CURL_TLS_ARGS+=("--cacert" "$DENON_CURL_CACERT")
    elif [[ "${DENON_CURL_INSECURE:-}" == "0" ]]; then
      :
    else
      DENON_CURL_TLS_ARGS+=("-k")
    fi

    if [[ -n "${DENON_CURL_PINNEDPUBKEY:-}" ]]; then
      DENON_CURL_TLS_ARGS+=("--pinnedpubkey" "$DENON_CURL_PINNEDPUBKEY")
    fi
  }

  _denon_curl_tls_mode() {
    if [[ "${DENON_CURL_INSECURE:-}" == "1" ]]; then
      printf '%s' 'insecure compatibility mode (-k)'
    elif [[ -n "${DENON_CURL_CACERT:-}" ]]; then
      printf '%s' 'custom CA certificate'
    elif [[ "${DENON_CURL_INSECURE:-}" == "0" ]]; then
      printf '%s' 'system trust'
    else
      printf '%s' 'insecure compatibility mode (-k)'
    fi
  }

  _denon_curl_insecure_mode_active() {
    [[ "${DENON_CURL_INSECURE:-}" == "1" || ( -z "${DENON_CURL_INSECURE+x}" && -z "${DENON_CURL_CACERT:-}" ) ]]
  }

  _denon_curl() {
    local connect_timeout="${DENON_CURL_CONNECT_TIMEOUT:-2}"
    local max_time="${DENON_CURL_MAX_TIME:-4}"
    local -a tls_args
    _denon_curl_tls_args || return 1
    tls_args=("${DENON_CURL_TLS_ARGS[@]}")
    _denon_debug "curl $*"
    curl -sS "${tls_args[@]}" --connect-timeout "$connect_timeout" --max-time "$max_time" "$@"
  }

  _denon_get_config() {
    local type="$1"
    _denon_curl -G "$BASE/ajax/globals/get_config" --data-urlencode "type=$type"
  }

  _denon_set_config() {
    local type="$1"
    local data="$2"
    local http_code
    _denon_debug "set_config type=$type data=$data"
    http_code=$(_denon_curl -G -o /dev/null -w '%{http_code}' "$BASE/ajax/globals/set_config" \
      --data-urlencode "type=$type" \
      --data-urlencode "data=$data") || return 1
    case "$http_code" in
      2??) return 0 ;;
      *)
        _denon_debug "set_config HTTP status $http_code"
        return 1
        ;;
    esac
  }

  _denon_get_power_xml() { _denon_get_config 4; }
  _denon_get_source_xml() { _denon_get_config 7; }
  _denon_get_vol_xml() { _denon_get_config 12; }
  _denon_get_identity_xml() { _denon_get_config 3; }

  _denon_get_receiver_name() {
    local xml name
    xml=$(_denon_get_identity_xml) || return 1
    name=$(printf '%s' "$xml" | sed -n 's:.*<FriendlyName>\([^<]*\)</FriendlyName>.*:\1:p' | head -1)
    printf '%s' "${name:-Unknown}"
  }

  _denon_json_escape() {
    LC_ALL=C awk '
      BEGIN {
        ORS=""
        backslash=sprintf("%c", 92)
        quote=sprintf("%c", 34)
        tab=sprintf("%c", 9)
        carriage_return=sprintf("%c", 13)
      }
      {
        if (NR > 1) {
          printf "\\n"
        }
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "")
        gsub(/[[:cntrl:]]/, "")
        printf "%s", $0
      }
    '
  }

  _denon_script_path() {
    local candidate trace
    if [[ -n "${DENON_SCRIPT_PATH:-}" ]]; then
      printf '%s\n' "$DENON_SCRIPT_PATH"
      return 0
    fi
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      # shellcheck disable=SC2154 # zsh populates funcfiletrace when sourced.
      for trace in "${funcfiletrace[@]}"; do
        candidate="${trace%%:*}"
        if [[ -n "$candidate" && -r "$candidate" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
    fi
    candidate="${BASH_SOURCE[0]:-$0}"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    return 1
  }

  _denon_helper_path() {
    local explicit_path="$1"
    local helper_name="$2"
    local script_path script_dir candidate

    if [[ -n "$explicit_path" ]]; then
      printf '%s\n' "$explicit_path"
      return 0
    fi

    script_path=$(_denon_script_path) || script_path="$PWD/denon.sh"
    script_dir=$(cd "$(dirname "$script_path")" 2>/dev/null && pwd)
    candidate="${script_dir:-$PWD}/$helper_name"
    if [[ -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi

    printf '/usr/libexec/denon-avr-controller/%s\n' "$helper_name"
  }

  _denon_trim() {
    local value="$1"
    value=${value//$'\r'/}
    printf '%s' "$value" | awk '{$1=$1; print}'
  }

  _denon_validate_stored_name() {
    local kind="$1"
    local name="$2"

    if [[ "$name" == */* ]]; then
      echo "Error: $kind name must not contain '/': $name" >&2
      return 1
    fi
    if [[ "$name" == .* ]]; then
      echo "Error: $kind name must not start with '.': $name" >&2
      return 1
    fi
    return 0
  }

  _denon_clean_source_name() {
    local value
    value=$(_denon_trim "$1")
    printf '%s' "$value" | sed 's/[[:space:]]*([0-9][0-9]*)[[:space:]]*$//'
  }

  _denon_raw_to_db() {
    awk -v raw="$1" 'BEGIN { printf "%.1f", raw / 10 - 80 }'
  }

  _denon_db_to_raw() {
    awk -v db="$1" 'BEGIN { printf "%.0f", (db + 80) * 10 }'
  }

  _denon_extract_main_power() {
    printf '%s' "$1" | sed -n 's:.*<MainZone><Power>\([0-9]*\)</Power>.*:\1:p'
  }

  _denon_extract_zone2_power() {
    printf '%s' "$1" | sed -n 's:.*<Zone2><Power>\([0-9]*\)</Power>.*:\1:p'
  }

  _denon_extract_main_volume_raw() {
    printf '%s' "$1" | sed -n 's:.*<MainZone><Volume>\([0-9]*\)</Volume>.*:\1:p'
  }

  _denon_extract_zone2_volume_raw() {
    printf '%s' "$1" | sed -n 's:.*<Zone2><Volume>\([0-9]*\)</Volume>.*:\1:p'
  }

  _denon_extract_main_mute() {
    printf '%s' "$1" | sed -n 's:.*<MainZone>.*<Mute>\([^<]*\)</Mute>.*</MainZone>.*:\1:p'
  }

  _denon_extract_zone2_mute() {
    printf '%s' "$1" | sed -n 's:.*<Zone2>.*<Mute>\([^<]*\)</Mute>.*</Zone2>.*:\1:p'
  }

  _denon_xml_split_tags() {
    awk '{ gsub(/></, ">\n<"); print }'
  }

  _denon_main_volume_raw() {
    _denon_extract_main_volume_raw "$(_denon_get_vol_xml)"
  }

  _denon_source_rows_from_xml() {
    local zone="${1:-1}"
    local xml="$2"

    printf '%s' "$xml" |
      _denon_xml_split_tags |
      awk -v zone="$zone" '
        $0 ~ "<Zone zone=\"" zone "\" " { in_zone=1; next }
        in_zone && /<\/Zone>/ { in_zone=0 }
        in_zone && /<Source index="/ {
          idx=$0
          sub(/^.*<Source index="/, "", idx)
          sub(/".*$/, "", idx)
          next
        }
        in_zone && /<Name>/ {
          name=$0
          sub(/^.*<Name>/, "", name)
          sub(/<\/Name>.*$/, "", name)
          printf "%s\t%s\n", idx, name
        }
      '
  }

  _denon_source_rows() {
    local zone="${1:-1}"
    _denon_source_rows_from_xml "$zone" "$(_denon_get_source_xml)"
  }

  _denon_alias_file() {
    printf '%s\n' "${DENON_SOURCE_ALIASES:-$HOME/.config/denon/source_aliases}"
  }

  _denon_source_rows_with_aliases_from_xml() {
    local zone="${1:-1}"
    local xml="$2"
    local alias_file
    alias_file=$(_denon_alias_file)
    [[ -r "$alias_file" ]] || alias_file="/dev/null"

    _denon_source_rows_from_xml "$zone" "$xml" |
      awk -F '\t' -v zone="$zone" -v alias_file="$alias_file" '
        BEGIN {
          while ((getline line < alias_file) > 0) {
            split(line, parts, "\t")
            if (parts[1] == zone) aliases[parts[2]] = parts[3]
          }
          close(alias_file)
        }
        {
          display=($1 in aliases ? aliases[$1] : $2)
          printf "%s\t%s\t%s\n", $1, $2, display
        }
      '
  }

  _denon_source_rows_with_aliases() {
    local zone="${1:-1}"
    _denon_source_rows_with_aliases_from_xml "$zone" "$(_denon_get_source_xml)"
  }

  _denon_alias_for_source() {
    local zone="$1"
    local source_idx="$2"
    local alias_file
    alias_file=$(_denon_alias_file)
    [[ -r "$alias_file" ]] || return 1
    awk -F '\t' -v zone="$zone" -v idx="$source_idx" \
      '$1 == zone && $2 == idx { print $3; found=1; exit } END { exit found ? 0 : 1 }' "$alias_file"
  }

  _denon_current_source_idx() {
    local zone="${1:-1}"
    _denon_get_source_xml | sed -n "s:.*<Zone zone=\"$zone\" index=\"\\([0-9]\\+\\)\".*:\\1:p"
  }

  _denon_source_name_by_idx() {
    local zone="${1:-1}"
    local source_idx="$2"
    [[ -n "$source_idx" ]] || return 1
    _denon_source_rows_from_xml "$zone" "$(_denon_get_source_xml)" |
      awk -F '\t' -v idx="$source_idx" '$1 == idx { print $2; found=1; exit } END { exit found ? 0 : 1 }'
  }

  _denon_resolve_source_index() {
    local query="$1"
    local zone="${2:-1}"

    if _denon_is_unsigned_integer "$query"; then
      _denon_source_rows "$zone" | awk -F '\t' -v wanted="$query" '$1 == wanted { print $1; found=1; exit } END { exit found ? 0 : 1 }'
      return $?
    fi

    _denon_source_rows_with_aliases "$zone" |
      awk -F '\t' -v wanted="$query" '
        function norm(value) {
          value=tolower(value)
          gsub(/[^a-z0-9]/, "", value)
          return value
        }
        BEGIN { wanted=norm(wanted) }
        norm($2) == wanted || norm($3) == wanted { print $1; found=1; exit }
        index(norm($2), wanted) || index(norm($3), wanted) { print $1; found=1; exit }
        END { exit found ? 0 : 1 }
      '
  }

  _denon_mktemp_near() {
    local target="$1"
    local dir
    dir=$(dirname "$target")
    mkdir -p "$dir" || return 1
    mktemp "$dir/.denon.tmp.XXXXXX"
  }

  _denon_set_source_alias() {
    local zone="$1"
    local query="$2"
    local new_name="$3"
    local source_idx alias_file tmp_file

    if [[ -z "$query" || -z "$new_name" ]]; then
      echo "Usage: denon rename-source <id|name> <new name>" >&2
      return 1
    fi

    source_idx=$(_denon_resolve_source_index "$query" "$zone") || {
      echo "Error: unknown source '$query' for zone $zone" >&2
      _denon_sources "$zone" >&2
      return 1
    }

    alias_file=$(_denon_alias_file)
    tmp_file=$(_denon_mktemp_near "$alias_file") || {
      echo "Error: could not create temporary file near $alias_file" >&2
      return 1
    }

    if [[ -f "$alias_file" ]]; then
      awk -F '\t' -v zone="$zone" -v idx="$source_idx" '$1 != zone || $2 != idx' "$alias_file" >"$tmp_file"
    else
      : >"$tmp_file"
    fi
    printf '%s\t%s\t%s\n' "$zone" "$source_idx" "$new_name" >>"$tmp_file"
    mv "$tmp_file" "$alias_file"

    echo "Renamed zone $zone source $source_idx to: $new_name"
  }

  _denon_clear_source_alias() {
    local zone="$1"
    local query="$2"
    local source_idx alias_file tmp_file

    if [[ -z "$query" ]]; then
      echo "Usage: denon clear-source-name <id|name>" >&2
      return 1
    fi

    source_idx=$(_denon_resolve_source_index "$query" "$zone") || {
      echo "Error: unknown source '$query' for zone $zone" >&2
      _denon_sources "$zone" >&2
      return 1
    }

    alias_file=$(_denon_alias_file)
    [[ -f "$alias_file" ]] || {
      echo "No custom source name set for zone $zone source $source_idx"
      return 0
    }

    tmp_file=$(_denon_mktemp_near "$alias_file") || {
      echo "Error: could not create temporary file near $alias_file" >&2
      return 1
    }
    awk -F '\t' -v zone="$zone" -v idx="$source_idx" '$1 != zone || $2 != idx' "$alias_file" >"$tmp_file"
    mv "$tmp_file" "$alias_file"

    echo "Cleared custom name for zone $zone source $source_idx"
  }

  _denon_source_aliases() {
    local alias_file
    alias_file=$(_denon_alias_file)
    echo "Custom source names file: $alias_file"

    if [[ ! -s "$alias_file" ]]; then
      echo "No custom source names set"
      return 0
    fi

    awk -F '\t' '
      {
        zone=($1 == "1" ? "Main Zone" : "Zone " $1)
        printf "%s source %s: %s\n", zone, $2, $3
      }
    ' "$alias_file"
  }

  _denon_set_source_index() {
    local zone="$1"
    local source_idx="$2"
    _denon_set_config 7 "<Source zone=\"${zone}\" index=\"${source_idx}\"></Source>"
  }

  _denon_wait_for_source() {
    local zone="$1"
    local wanted="$2"
    local attempts="${3:-20}"
    local i current

    for ((i=0; i<attempts; i++)); do
      current=$(_denon_current_source_idx "$zone")
      [[ "$current" == "$wanted" ]] && return 0
      sleep 0.25
    done
    return 1
  }

  _denon_set_source() {
    local query="$1"
    local zone="${2:-1}"
    shift 2 2>/dev/null || true
    local source_idx current_idx source_name
    local json=0
    _denon_args_have_json "$@" && json=1

    if [[ -z "$query" ]]; then
      echo "Error: source requires an index or name, for example: denon source xbox" >&2
      return 1
    fi

    source_idx=$(_denon_resolve_source_index "$query" "$zone") || {
      echo "Error: unknown source '$query' for zone $zone" >&2
      _denon_sources "$zone" >&2
      return 1
    }

    current_idx=$(_denon_current_source_idx "$zone")
    if [[ "$current_idx" == "$source_idx" ]]; then
      if [[ "$zone" == "1" ]]; then
        _denon_status_pretty
      else
        _denon_zone_status_pretty "$zone"
      fi
      return 0
    fi

    if ! _denon_set_source_index "$zone" "$source_idx"; then
      echo "Warning: source change request timed out; verifying receiver state..." >&2
    fi

    if ! _denon_no_verify_enabled; then
      if ! _denon_wait_for_source "$zone" "$source_idx" 20; then
        echo "Error: source change to zone $zone source $source_idx was not confirmed" >&2
        return 1
      fi
    fi

    source_name=$(_denon_alias_for_source "$zone" "$source_idx" || _denon_source_name_by_idx "$zone" "$source_idx" || printf '%s' "$source_idx")
    if (( json )); then
      printf '{"zone":%s,"sourceIndex":%s,"sourceName":"%s","verified":%s}\n' \
        "$zone" "$source_idx" "$(printf '%s' "${source_name:-Unknown}" | _denon_json_escape)" "$(_denon_verified_json_bool)"
      return 0
    fi
    if _denon_no_verify_enabled; then
      if [[ "$zone" == "1" ]]; then
        printf 'Source set to %s (%s)%s\n' "${source_name:-Unknown}" "$source_idx" "$(_denon_unverified_suffix)"
      else
        printf 'Zone %s source: %s (%s)%s\n' "$zone" "${source_name:-Unknown}" "$source_idx" "$(_denon_unverified_suffix)"
      fi
      return 0
    fi
    if [[ "$zone" == "1" ]]; then
      _denon_status_pretty
    else
      printf 'Zone %s source: %s (%s)\n' "$zone" "${source_name:-Unknown}" "$source_idx"
    fi
  }

  _denon_apply_volume_limit() {
    local db="$1"
    local limit="${DENON_MAX_VOLUME_DB:--10}"

    case "$(_denon_lower "$limit")" in
      ""|off|none|disabled) return 0 ;;
    esac

    if ! _denon_is_number "$limit"; then
      echo "Error: DENON_MAX_VOLUME_DB must be numeric, off, none, or disabled" >&2
      return 1
    fi

    if awk -v db="$db" -v limit="$limit" 'BEGIN { exit !(db > limit) }'; then
      echo "Error: refusing to set volume above DENON_MAX_VOLUME_DB=$limit dB" >&2
      echo "Tip: set DENON_MAX_VOLUME_DB=off to disable this guard for one command." >&2
      return 1
    fi
  }

  _denon_set_volume_db() {
    local db="$1"
    shift || true
    local raw verified_raw
    local json=0
    _denon_args_have_json "$@" && json=1

    if ! _denon_is_number "$db"; then
      echo "Error: volume must be a dB value, for example: denon vol -35 or denon vol -35.5" >&2
      return 1
    fi

    _denon_apply_volume_limit "$db" || return 1

    raw=$(_denon_db_to_raw "$db")
    if (( raw < 0 )); then
      echo "Error: volume is below the supported Denon range" >&2
      return 1
    fi
    if (( raw > 980 )); then
      echo "Error: volume is above the supported Denon range" >&2
      return 1
    fi

    _denon_set_config 12 "<MainZone><Volume>${raw}</Volume></MainZone>" || {
      echo "Error: failed to send volume change" >&2
      return 1
    }

    if ! _denon_no_verify_enabled; then
      verified_raw=$(_denon_main_volume_raw)
      if [[ "$verified_raw" != "$raw" ]]; then
        echo "Warning: requested volume ${db} dB, but receiver now reports raw=${verified_raw:-unknown}" >&2
      fi
    fi

    if (( json )); then
      printf '{"volumeDb":%s,"verified":%s}\n' "$db" "$(_denon_verified_json_bool)"
      return 0
    fi

    printf 'Volume set to %s dB%s\n' "$db" "$(_denon_unverified_suffix)"
  }

  _denon_set_zone2_volume_raw() {
    local raw="$1"
    local db

    _denon_validate_volume_raw "$raw" "Zone 2" || return 1

    # Type 12 XML reports Zone 2 volume as the same 0.1 dB raw offset used by
    # Main Zone, so the same hearing-safety dB cap applies after conversion.
    db=$(_denon_raw_to_db "$raw")
    _denon_apply_volume_limit "$db" || return 1

    _denon_set_config 12 "<Zone2><Volume>${raw}</Volume></Zone2>" || return 1
  }

  _denon_fade_volume() {
    local target="" duration=10 arg json=0
    while [[ $# -gt 0 ]]; do
      arg="$1"
      case "$arg" in
        --json|json) json=1; shift ;;
        --duration|-d) duration="$2"; shift 2 ;;
        *) [[ -z "$target" ]] && target="$1"; shift ;;
      esac
    done

    if ! _denon_is_number "$target"; then
      echo "Usage: denon vol --fade <targetdB> [--duration seconds]" >&2
      return 1
    fi
    if ! _denon_is_number "$duration" || ! awk -v d="$duration" 'BEGIN { exit (d > 0) ? 0 : 1 }'; then
      echo "Error: duration must be a positive number" >&2
      return 1
    fi

    local raw current_db
    raw=$(_denon_main_volume_raw)
    if [[ -z "$raw" ]]; then
      echo "Error: could not read current volume" >&2
      return 1
    fi
    current_db=$(_denon_raw_to_db "$raw")

    if awk -v c="$current_db" -v t="$target" 'BEGIN { exit (c == t) ? 0 : 1 }'; then
      echo "Volume already at ${target} dB"
      return 0
    fi

    local step_interval="0.5"
    local num_steps
    num_steps=$(awk -v d="$duration" -v i="$step_interval" \
      'BEGIN { n=int(d/i+0.5); print (n<1 ? 1 : n) }')

    local i step_db
    for (( i = 1; i <= num_steps; i++ )); do
      step_db=$(awk -v c="$current_db" -v t="$target" -v i="$i" -v n="$num_steps" \
        'BEGIN { printf "%.1f", c + (t - c) * i / n }')
      _denon_set_volume_db "$step_db" >/dev/null || return 1
      if [[ -t 1 ]]; then
        printf '\rFading to %s dB: %s dB  ' "$target" "$step_db"
      fi
      (( i < num_steps )) && sleep "$step_interval"
    done
    [[ -t 1 ]] && printf '\n'
    if (( json )); then
      printf '{"volumeDb":%s,"verified":%s}\n' "$target" "$(_denon_verified_json_bool)"
    else
      printf 'Volume faded to %s dB%s\n' "$target" "$(_denon_unverified_suffix)"
    fi
  }

  _denon_change_volume() {
    local delta="$1"
    shift || true
    local raw current_db target_db

    if ! _denon_is_number "$delta"; then
      echo "Error: volume step must be numeric, for example: denon up 2" >&2
      return 1
    fi

    raw=$(_denon_main_volume_raw)
    if [[ -z "$raw" ]]; then
      echo "Error: could not read current volume" >&2
      return 1
    fi

    current_db=$(_denon_raw_to_db "$raw")
    target_db=$(awk -v current="$current_db" -v delta="$delta" 'BEGIN { printf "%.1f", current + delta }')
    _denon_set_volume_db "$target_db" "$@"
  }

  _denon_zone2_change_volume() {
    local delta="$1"
    local vol_xml raw current_db target_db new_raw

    if ! _denon_is_number "$delta"; then
      echo "Error: volume step must be numeric, for example: denon zone2 up 2" >&2
      return 1
    fi

    vol_xml=$(_denon_get_vol_xml) || return 1
    raw=$(_denon_extract_zone2_volume_raw "$vol_xml")
    if [[ -z "$raw" ]]; then
      echo "Error: could not read Zone 2 volume" >&2
      return 1
    fi

    current_db=$(_denon_raw_to_db "$raw")
    target_db=$(awk -v current="$current_db" -v delta="$delta" 'BEGIN { printf "%.1f", current + delta }')
    _denon_apply_volume_limit "$target_db" || return 1
    new_raw=$(_denon_db_to_raw "$target_db")
    _denon_validate_volume_raw "$new_raw" "Zone 2" || return 1
    _denon_set_zone2_volume_raw "$new_raw" || return 1
    _denon_zone_status_pretty 2
  }

  _denon_telnet() {
    local command="$1"
    if [[ -z "${DENON_UNIT_TEST:-}" ]] && declare -F avr_send >/dev/null 2>&1; then
      avr_send --quiet --timeout "${DENON_SEND_TIMEOUT:-1}" -- "$IP" "$command"
      return $?
    fi
    if command -v nc >/dev/null 2>&1; then
      _denon_debug "telnet $IP:23 $command"
      printf '%s\r' "$command" | nc -w 2 "$IP" 23 >/dev/null
      return $?
    fi
    echo "Error: nc is required for this command" >&2
    return 1
  }

  _denon_nc_supports_q() {
    if [[ "${denon_nc_supports_q_cached:-}" == "1" ]]; then
      return 0
    fi
    if [[ "${denon_nc_supports_q_cached:-}" == "0" ]]; then
      return 1
    fi
    command -v nc >/dev/null 2>&1 || {
      denon_nc_supports_q_cached=0
      return 1
    }

    local help
    help=$(nc -h 2>&1 </dev/null || true)
    if [[ "$help" == *"-q "* || "$help" == *"[-q"* || "$help" == *" -q"* ]]; then
      denon_nc_supports_q_cached=1
      return 0
    fi
    denon_nc_supports_q_cached=0
    return 1
  }

  _denon_telnet_query() {
    local command="$1"
    if [[ -z "${DENON_UNIT_TEST:-}" ]] && declare -F avr_send >/dev/null 2>&1; then
      local expect="$command"
      expect="${expect%\?}"
      expect="${expect%"${expect##*[![:space:]]}"}"
      avr_send --expect "$expect" --timeout "${DENON_SEND_TIMEOUT:-1}" -- "$IP" "$command"
      return $?
    fi
    command -v nc >/dev/null 2>&1 || {
      echo "Error: nc is required for this command" >&2
      return 1
    }
    _denon_debug "telnet query $IP:23 $command"
    if _denon_nc_supports_q; then
      printf '%s\r' "$command" | nc -w 2 -q 1 "$IP" 23 2>/dev/null
    else
      {
        printf '%s\r' "$command"
        sleep 0.15
      } | nc -w 2 "$IP" 23 2>/dev/null
    fi
  }

  _denon_query_main_mute_raw() {
    local text line

    text=$(_denon_telnet_query "MU?" 2>/dev/null) || return 1
    text=${text//$'\r'/$'\n'}
    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      case "$line" in
        MUON|MUOFF)
          printf '%s' "$line"
          return 0
          ;;
      esac
    done <<<"$text"
    return 1
  }

  _denon_query_zone2_mute_raw() {
    local text line

    text=$(_denon_telnet_query "Z2MU?" 2>/dev/null) || return 1
    text=${text//$'\r'/$'\n'}
    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      case "$line" in
        Z2MUON|Z2MUOFF)
          printf '%s' "$line"
          return 0
          ;;
      esac
    done <<<"$text"
    return 1
  }

  _denon_pad_sleep_minutes() {
    local minutes="$1"
    if ! _denon_is_unsigned_integer "$minutes" || (( minutes < 1 || minutes > 120 )); then
      echo "Error: sleep timer must be off or 1-120 minutes" >&2
      return 1
    fi
    printf '%03d' "$minutes"
  }

  _denon_sleep_timer() {
    local zone="${1:-1}"
    local value="${2:-}"
    local prefix="" label="Main zone" code response line minutes

    case "$zone" in
      1) prefix=""; label="Main zone" ;;
      2) prefix="Z2"; label="Zone 2" ;;
      3) prefix="Z3"; label="Zone 3" ;;
      *) echo "Error: unsupported zone $zone" >&2; return 1 ;;
    esac

    if [[ -z "$value" ]]; then
      response=$(_denon_telnet_query "${prefix}SLP?")
      line=$(printf '%s\n' "$response" | tr '\r' '\n' | sed -n "/^${prefix}SLP/{p; q;}")
      case "$line" in
        "${prefix}SLPOFF") echo "$label sleep timer: off" ;;
        "${prefix}SLP"[0-9][0-9][0-9])
          minutes=${line#"${prefix}SLP"}
          minutes=$((10#$minutes))
          echo "$label sleep timer: $minutes min"
          ;;
        *) echo "$label sleep timer: unknown" >&2; return 1 ;;
      esac
      return 0
    fi

    case "$(_denon_lower "$value")" in
      off|clear|0)
        code="${prefix}SLPOFF"
        ;;
      *)
        minutes=$(_denon_pad_sleep_minutes "$value") || return 1
        code="${prefix}SLP${minutes}"
        ;;
    esac
    _denon_telnet "$code" || return 1
    _denon_sleep_timer "$zone"
  }

  _denon_quick_select() {
    local action="$1"
    local id="$2"

    if [[ "$action" == "save" || "$action" == "store" || "$action" == "memory" ]]; then
      if [[ -z "$id" || ! "$id" =~ ^[1-5]$ ]]; then
        echo "Usage: denon qs save <1-5>" >&2
        return 1
      fi
      _denon_telnet "QUICK${id} MEMORY" && echo "Stored Quick Select $id"
      return
    fi

    id="$action"
    if [[ -z "$id" || ! "$id" =~ ^[1-5]$ ]]; then
      echo "Usage: denon qs <1-5> | denon qs save <1-5>" >&2
      return 1
    fi
    _denon_telnet "QUICK${id}" && echo "Recalled Quick Select $id"
  }

  _denon_toggle() {
    local what="${1:-mute}"
    case "$(_denon_lower "$what")" in
      mute)
        local xml mute
        xml=$(_denon_get_vol_xml) || return 1
        mute=$(_denon_extract_main_mute "$xml")
        if [[ "$mute" == "1" ]]; then
          _denon_set_config 12 '<MainZone><Mute>2</Mute></MainZone>' || return 1
          echo "Unmuted"
        else
          _denon_set_config 12 '<MainZone><Mute>1</Mute></MainZone>' || return 1
          echo "Muted"
        fi
        ;;
      power)
        local xml power
        xml=$(_denon_get_power_xml) || return 1
        power=$(_denon_extract_main_power "$xml")
        if [[ "$power" == "1" ]]; then
          _denon_set_config 4 '<MainZone><Power>3</Power></MainZone>' || return 1
          echo "Power off"
        else
          _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>' || return 1
          echo "Power on"
        fi
        ;;
      *)
        echo "Usage: denon toggle [mute|power]" >&2
        return 1
        ;;
    esac
  }
  _denon_sound_mode() {
    local mode code json=0
    mode=$(_denon_lower "$1")
    shift || true
    _denon_args_have_json "$@" && json=1
    case "$mode" in
      stereo) code="MSSTEREO" ;;
      direct) code="MSDIRECT" ;;
      pure|puredirect|pure-direct) code="MSPURE DIRECT" ;;
      movie) code="MSMOVIE" ;;
      music) code="MSMUSIC" ;;
      game) code="MSGAME" ;;
      auto) code="MSAUTO" ;;
      *) echo "Error: mode must be one of stereo, direct, pure, movie, music, game, auto" >&2; return 1 ;;
    esac
    _denon_telnet "$code" || return 1
    if (( json )); then
      printf '{"mode":"%s","verified":%s}\n' "$(printf '%s' "$mode" | _denon_json_escape)" "$(_denon_verified_json_bool)"
    else
      printf 'Sound mode set to %s%s\n' "$mode" "$(_denon_unverified_suffix)"
    fi
  }

  _denon_on_off() {
    case "$(_denon_lower "$1")" in
      on) echo "ON" ;;
      off) echo "OFF" ;;
      *) return 1 ;;
    esac
  }

  _denon_audyssey_toggle() {
    local name="$1"
    local value="$2"
    local prefix="$3"
    local state response line parsed
    if [[ -z "$value" ]]; then
      response=$(_denon_telnet_query "${prefix} ?")
      line=$(printf '%s\n' "$response" | tr '\r' '\n' | sed -n "/^${prefix}/{p; q;}")
      parsed=${line#"${prefix} "}
      echo "$name: ${parsed:-unknown}"
      [[ -n "$line" ]]
      return
    fi
    state=$(_denon_on_off "$value") || {
      echo "Error: $name must be on or off" >&2
      return 1
    }
    _denon_telnet "${prefix} ${state}" && echo "$name set to $(_denon_lower "$state")"
  }

  _denon_cinema_eq() {
    local value="$1" state response line
    if [[ -z "$value" ]]; then
      response=$(_denon_telnet_query "PSCINEMA EQ. ?")
      line=$(printf '%s\n' "$response" | tr '\r' '\n' | sed -n '/^PSCINEMA EQ[.]/ {p; q;}')
      local parsed="${line#PSCINEMA EQ.}"
      echo "Cinema EQ: ${parsed:-unknown}"
      [[ -n "$line" ]]
      return
    fi
    state=$(_denon_on_off "$value") || {
      echo "Error: cinema-eq must be on or off" >&2
      return 1
    }
    _denon_telnet "PSCINEMA EQ.${state}" && echo "Cinema EQ set to $(_denon_lower "$state")"
  }

  _denon_dynamic_volume() {
    local value="$1" code response line
    if [[ -z "$value" ]]; then
      response=$(_denon_telnet_query "PSDYNVOL ?")
      line=$(printf '%s\n' "$response" | tr '\r' '\n' | sed -n '/^PSDYNVOL/ {p; q;}')
      local raw_code="${line#PSDYNVOL }" friendly
      case "$raw_code" in
        OFF) friendly="off" ;; LIT) friendly="light" ;;
        MED) friendly="medium" ;; HEV) friendly="heavy" ;;
        *) friendly="${raw_code:-unknown}" ;;
      esac
      echo "Dynamic Volume: $friendly"
      [[ -n "$line" ]]
      return
    fi
    case "$(_denon_lower "$value")" in
      off) code="OFF" ;;
      light|low|lit) code="LIT" ;;
      medium|med) code="MED" ;;
      heavy|high|hev) code="HEV" ;;
      *) echo "Error: dyn-vol must be off, light, medium, or heavy" >&2; return 1 ;;
    esac
    _denon_telnet "PSDYNVOL ${code}" && echo "Dynamic Volume set to $(_denon_lower "$value")"
  }

  _denon_multeq() {
    local value="$1" code response line
    if [[ -z "$value" ]]; then
      response=$(_denon_telnet_query "PSMULTEQ ?")
      line=$(printf '%s\n' "$response" | tr '\r' '\n' | sed -n '/^PSMULTEQ:/ {p; q;}')
      local raw_code="${line#PSMULTEQ:}" friendly
      case "$raw_code" in
        AUDYSSEY) friendly="reference" ;; BYP.LR) friendly="bypass-lr" ;;
        FLAT) friendly="flat" ;; MANUAL) friendly="manual" ;; OFF) friendly="off" ;;
        *) friendly="${raw_code:-unknown}" ;;
      esac
      echo "MultEQ: $friendly"
      [[ -n "$line" ]]
      return
    fi
    case "$(_denon_lower "$value")" in
      reference|audyssey|ref) code="AUDYSSEY" ;;
      bypass-lr|bypasslr|byp.lr|lr) code="BYP.LR" ;;
      flat) code="FLAT" ;;
      manual) code="MANUAL" ;;
      off) code="OFF" ;;
      *) echo "Error: multeq must be reference, bypass-lr, flat, manual, or off" >&2; return 1 ;;
    esac
    _denon_telnet "PSMULTEQ:${code}" && echo "MultEQ set to $(_denon_lower "$value")"
  }

  _denon_tone_value_code() {
    local value="$1"
    if ! _denon_is_number "$value"; then
      return 1
    fi
    awk -v value="$value" 'BEGIN {
      if (value < -6 || value > 6) exit 1
      printf "%02d", value + 50
    }'
  }

  _denon_tone_control() {
    local which="$1"
    local value="$2"
    local command response line code label
    case "$which" in
      bass) command="PSBAS"; label="Bass" ;;
      treble) command="PSTRE"; label="Treble" ;;
      *) return 1 ;;
    esac
    if [[ -z "$value" ]]; then
      response=$(_denon_telnet_query "${command} ?")
      line=$(printf '%s\n' "$response" | tr '\r' '\n' | sed -n "/^${command}/ {p; q;}")
      local raw_val="${line#"${command} "}"
      local db_val
      if [[ "$raw_val" =~ ^[0-9]+$ ]]; then
        db_val=$(awk -v v="$raw_val" 'BEGIN { printf "%+.0f", v - 50 }')
        echo "$label: ${db_val} dB"
      else
        echo "$label: ${raw_val:-unknown}"
      fi
      [[ -n "$line" ]]
      return
    fi
    case "$(_denon_lower "$value")" in
      up|down)
        _denon_telnet "${command} $(_denon_lower "$value" | tr '[:lower:]' '[:upper:]')" && echo "$label $(_denon_lower "$value")"
        ;;
      *)
        code=$(_denon_tone_value_code "$value") || {
          echo "Error: $which must be up, down, or a value from -6 to 6" >&2
          return 1
        }
        _denon_telnet "${command} ${code}" && echo "$label set to ${value} dB"
        ;;
    esac
  }

  _denon_heos_control() {
    local action="$1" helper_action
    case "$action" in
      play|pause|stop|next) helper_action="$action" ;;
      prev|previous) helper_action="prev" ;;
      *) return 1 ;;
    esac
    _denon_heos_helper "$helper_action" && echo "Sent $helper_action"
  }

  _denon_heos_helper() {
    local helper
    helper=$(_denon_helper_path "${DENON_HEOS_HELPER:-}" "denon_heos_helper.py")
    if [[ ! -r "$helper" ]]; then
      echo "Error: HEOS helper not found: $helper" >&2
      return 1
    fi
    command -v python3 >/dev/null 2>&1 || {
      echo "Error: python3 is required for HEOS queue, group, browse, and play-mode commands" >&2
      return 1
    }
    python3 "$helper" "$IP" "$@"
  }

  _denon_dashboard_alt() {
    local helper script_path
    script_path=$(_denon_script_path) || script_path="$PWD/denon.sh"
    helper=$(_denon_helper_path "${DENON_DASHBOARD_ALT_HELPER:-}" "denon_dashboard_alt.py")
    if [[ ! -r "$helper" ]]; then
      echo "Error: alternative dashboard helper not found: $helper" >&2
      return 1
    fi
    command -v python3 >/dev/null 2>&1 || {
      echo "Error: python3 is required for dashboard-alt" >&2
      return 1
    }
    python3 "$helper" --script "$script_path" "$@"
  }

  _denon_track() {
    local xml title artist album
    xml=$(_denon_curl -L -A 'Mozilla/5.0' "http://$IP/goform/formNetAudio_StatusXml.xml" 2>/dev/null)
    if ! printf '%s' "$xml" | grep -q '<'; then
      xml=$(_denon_curl -L -A 'Mozilla/5.0' "http://$IP:8080/goform/formNetAudio_StatusXml.xml" 2>/dev/null)
    fi
    title=$(printf '%s' "$xml" | sed -n 's:.*<Song>\([^<]*\)</Song>.*:\1:p; s:.*<szLine1>\([^<]*\)</szLine1>.*:\1:p' | sed -n '1p')
    artist=$(printf '%s' "$xml" | sed -n 's:.*<Artist>\([^<]*\)</Artist>.*:\1:p; s:.*<szLine2>\([^<]*\)</szLine2>.*:\1:p' | sed -n '1p')
    album=$(printf '%s' "$xml" | sed -n 's:.*<Album>\([^<]*\)</Album>.*:\1:p; s:.*<szLine3>\([^<]*\)</szLine3>.*:\1:p' | sed -n '1p')

    if [[ -z "$title" && -z "$artist" && -z "$album" ]]; then
      echo "Track info unavailable from this receiver endpoint"
      return 1
    fi
    echo "Title: ${title:-Unknown}"
    echo "Artist: ${artist:-Unknown}"
    echo "Album: ${album:-Unknown}"
  }

  _denon_power_name() {
    case "$1" in
      1) echo "ON" ;;
      2) echo "STANDBY" ;;
      3) echo "OFF" ;;
      "") echo "Unknown" ;;
      *) echo "UNKNOWN($1)" ;;
    esac
  }

  _denon_bool_name() {
    _denon_normalize_mute "$1"
  }

  _denon_display_unknown() {
    local value

    value=$(_denon_trim "${1:-}")
    case "$(_denon_lower "$value")" in
      ""|unknown|null|none|n/a|na|"-") echo "Unknown" ;;
      *) printf '%s\n' "$value" ;;
    esac
  }

  _denon_display_network_label() {
    local value

    value=$(_denon_display_unknown "$1")
    case "$(_denon_lower "$value")" in
      wi-fi|wifi|wireless|wlan) echo "Wi-Fi" ;;
      wired|ethernet|lan) echo "Ethernet" ;;
      *) printf '%s\n' "$value" ;;
    esac
  }

  _denon_display_zone_label() {
    local value

    value=$(_denon_display_unknown "$1")
    case "$(_denon_lower "$value")" in
      mainzone|"main zone") echo "Main Zone" ;;
      zone2|"zone 2"|z2) echo "Zone 2" ;;
      zone3|"zone 3"|z3) echo "Zone 3" ;;
      *) printf '%s\n' "$value" ;;
    esac
  }

  _denon_display_empty_message() {
    local key
    key=$(_denon_lower "${1:-}")

    case "$key" in
      no-recent-events|recent-events|events) echo "No Recent Events" ;;
      no-state-changes|state-changes) echo "No State Changes Yet" ;;
      no-sources|sources) echo "No Sources Found" ;;
      no-metadata|metadata|now-playing) echo "No Metadata For Current Source" ;;
      unavailable|now-playing-unavailable) echo "Now Playing Unavailable" ;;
      *) echo "Unknown" ;;
    esac
  }

  _denon_display_data_value() {
    local field_key="$1"
    local value="$2"

    case "$field_key" in
      muted) _denon_mute_display_name "$value" ;;
      network) _denon_display_network_label "$value" ;;
      zone_name|main_zone|zone2) _denon_display_zone_label "$value" ;;
      *) _denon_display_unknown "$value" ;;
    esac
  }

  _denon_display_section_label() {
    case "$1" in
      "Audio / surround") echo "Audio / Surround" ;;
      "Sleep timer") echo "Sleep Timer" ;;
      "Web UI information") echo "Web UI Information" ;;
      "Discovered read-only endpoints") echo "Discovered Read-Only Endpoints" ;;
      *) printf '%s\n' "$1" ;;
    esac
  }

  _denon_normalize_mute() {
    local value

    value=$(_denon_trim "${1:-}")
    case "$(_denon_lower "$value")" in
      1|on|yes|true|muon|z2muon) echo "yes" ;;
      0|2|off|no|false|muoff|z2muoff) echo "no" ;;
      *) echo "Unknown" ;;
    esac
  }

  _denon_mute_display_name() {
    case "$(_denon_normalize_mute "$1")" in
      yes) echo "Yes" ;;
      no) echo "No" ;;
      *) echo "Unknown" ;;
    esac
  }

  _denon_mute_json_value() {
    case "$(_denon_normalize_mute "$1")" in
      yes) echo "true" ;;
      no) echo "false" ;;
      *) echo "null" ;;
    esac
  }

  _denon_resolve_main_mute() {
    local raw="$1" telnet_mute
    if [[ "$(_denon_normalize_mute "$raw")" != "Unknown" ]]; then
      printf '%s' "$raw"
      return 0
    fi
    telnet_mute=$(_denon_query_main_mute_raw 2>/dev/null || printf '')
    if [[ "$(_denon_normalize_mute "$telnet_mute")" != "Unknown" ]]; then
      printf '%s' "$telnet_mute"
    else
      printf 'Unknown'
    fi
  }

  _denon_resolve_zone2_mute() {
    local raw="$1" telnet_mute
    if [[ "$(_denon_normalize_mute "$raw")" != "Unknown" ]]; then
      printf '%s' "$raw"
      return 0
    fi
    telnet_mute=$(_denon_query_zone2_mute_raw 2>/dev/null || printf '')
    if [[ "$(_denon_normalize_mute "$telnet_mute")" != "Unknown" ]]; then
      printf '%s' "$telnet_mute"
    else
      printf 'Unknown'
    fi
  }

  _denon_zone_status_pretty() {
    local zone="${1:-2}"
    local power_xml source_xml vol_xml
    local power_code power source_idx source_name raw_vol mute muted db

    power_xml="$(_denon_get_power_xml)" || return 1
    source_xml="$(_denon_get_source_xml)" || return 1
    vol_xml="$(_denon_get_vol_xml)" || return 1

    if [[ "$zone" == "2" ]]; then
      power_code=$(_denon_extract_zone2_power "$power_xml")
      raw_vol=$(_denon_extract_zone2_volume_raw "$vol_xml")
      mute=$(_denon_extract_zone2_mute "$vol_xml")
    else
      echo "Error: pretty status is only implemented for Zone 2 here" >&2
      return 1
    fi

    source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="'"$zone"'" index="\([0-9]\+\)".*:\1:p')
    source_name=$(_denon_alias_for_source "$zone" "$source_idx" || _denon_source_name_by_idx "$zone" "$source_idx" || printf 'Unknown')

    power=$(_denon_power_name "$power_code")
    muted=$(_denon_mute_display_name "$mute")
    db=$([[ -n "$raw_vol" ]] && _denon_raw_to_db "$raw_vol" || echo "Unknown")

    printf 'Zone %s | Power: %s | Source: %s | Volume: %s | Muted: %s\n' \
      "$zone" "$power" "${source_name:-Unknown}" "$db" "$muted"
  }

  _denon_info() {
    local format
    format=$(_denon_lower "$1")
    local identity_xml power_xml source_xml vol_xml
    local friendly_name power_code zone2_power_code power zone2_power
    local main_source_idx zone2_source_idx main_source_name zone2_source_name
    local raw_vol raw_zone2_vol mute zone2_mute muted zone2_muted
    local pretty_db json_db zone2_pretty_db friendly_json main_source_json zone2_source_json

    identity_xml="$(_denon_get_identity_xml)" || return 1
    power_xml="$(_denon_get_power_xml)" || return 1
    source_xml="$(_denon_get_source_xml)" || return 1
    vol_xml="$(_denon_get_vol_xml)" || return 1

    friendly_name=$(printf '%s' "$identity_xml" | sed -n 's:.*<FriendlyName>\([^<]*\)</FriendlyName>.*:\1:p')
    power_code=$(_denon_extract_main_power "$power_xml")
    zone2_power_code=$(_denon_extract_zone2_power "$power_xml")
    main_source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="1" index="\([0-9]\+\)".*:\1:p')
    zone2_source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="2" index="\([0-9]\+\)".*:\1:p')
    raw_vol=$(_denon_extract_main_volume_raw "$vol_xml")
    raw_zone2_vol=$(_denon_extract_zone2_volume_raw "$vol_xml")
    mute=$(_denon_resolve_main_mute "$(_denon_extract_main_mute "$vol_xml")")
    zone2_mute=$(_denon_resolve_zone2_mute "$(_denon_extract_zone2_mute "$vol_xml")")

    main_source_name=$(_denon_alias_for_source "1" "$main_source_idx" || _denon_source_name_by_idx "1" "$main_source_idx")
    zone2_source_name=$(_denon_alias_for_source "2" "$zone2_source_idx" || _denon_source_name_by_idx "2" "$zone2_source_idx")

    power=$(_denon_power_name "$power_code")
    zone2_power=$(_denon_power_name "$zone2_power_code")
    muted=$(_denon_mute_display_name "$mute")
    zone2_muted=$(_denon_mute_display_name "$zone2_mute")

    if [[ -n "$raw_vol" ]]; then
      pretty_db=$(_denon_raw_to_db "$raw_vol")
      json_db="$pretty_db"
    else
      pretty_db="Unknown"
      json_db="null"
    fi
    if [[ -n "$raw_zone2_vol" ]]; then
      zone2_pretty_db="$(_denon_raw_to_db "$raw_zone2_vol") dB"
    else
      zone2_pretty_db="Unknown"
    fi

    if [[ "$format" == "--json" || "$format" == "json" ]]; then
      friendly_json=$(printf '%s' "${friendly_name:-Unknown}" | _denon_json_escape)
      main_source_json=$(printf '%s' "${main_source_name:-Unknown}" | _denon_json_escape)
      zone2_source_json=$(printf '%s' "${zone2_source_name:-Unknown}" | _denon_json_escape)
      printf '{"receiver":"%s","ip":"%s","mainZone":{"power":"%s","sourceIndex":%s,"sourceName":"%s","volumeDb":%s,"muted":%s},"zone2":{"power":"%s","sourceIndex":%s,"sourceName":"%s","volumeRaw":%s,"muted":%s}}\n' \
        "$friendly_json" "$IP" "$power" "${main_source_idx:-null}" "$main_source_json" "$json_db" "$(_denon_mute_json_value "$mute")" \
        "$zone2_power" "${zone2_source_idx:-null}" "$zone2_source_json" "${raw_zone2_vol:-null}" "$(_denon_mute_json_value "$zone2_mute")"
      return 0
    fi

    echo "Receiver: ${friendly_name:-Unknown}"
    echo "IP: $IP"
    echo "Main Zone Power: $power"
    echo "Main Zone Source: ${main_source_name:-Unknown} ($(_denon_display_unknown "$main_source_idx"))"
    echo "Main Zone Volume: $pretty_db dB"
    echo "Main Zone Muted: $muted"
    echo "Zone 2 Power: $zone2_power"
    echo "Zone 2 Source: ${zone2_source_name:-Unknown} ($(_denon_display_unknown "$zone2_source_idx"))"
    echo "Zone 2 Volume: $zone2_pretty_db"
    echo "Zone 2 Muted: $zone2_muted"
    echo
    _denon_sources "1"
    echo
    _denon_sources "2"
  }

  _denon_status_pretty() {
    local power_xml source_xml vol_xml
    local power_code power source_idx source_name raw_vol mute db mute_str

    power_xml="$(_denon_get_power_xml)" || return 1
    source_xml="$(_denon_get_source_xml)" || return 1
    vol_xml="$(_denon_get_vol_xml)" || return 1

    power_code=$(_denon_extract_main_power "$power_xml")
    source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="1" index="\([0-9]\+\)".*:\1:p')
    raw_vol=$(_denon_extract_main_volume_raw "$vol_xml")
    mute=$(_denon_resolve_main_mute "$(_denon_extract_main_mute "$vol_xml")")
    source_name=$(_denon_alias_for_source "1" "$source_idx" || _denon_source_name_by_idx "1" "$source_idx")

    case "$power_code" in
      1) power="ON" ;;
      2) power="STANDBY" ;;
      3) power="OFF" ;;
      *) power="UNKNOWN($power_code)" ;;
    esac

    if [[ -n "$raw_vol" ]]; then
      db=$(_denon_raw_to_db "$raw_vol")
    else
      db="Unknown"
    fi
    mute_str=$([[ "$(_denon_normalize_mute "$mute")" == "yes" ]] && echo " [MUTED]" || echo "")

    printf 'Power: %s | Source: %s | Volume: %s dB%s\n' \
      "$power" "${source_name:-Unknown}" "$db" "$mute_str"
  }

  _denon_status_json() {
    local power_xml source_xml vol_xml
    local power_code power source_idx source_name raw_vol mute db muted_json source_json

    power_xml="$(_denon_get_power_xml)" || return 1
    source_xml="$(_denon_get_source_xml)" || return 1
    vol_xml="$(_denon_get_vol_xml)" || return 1

    power_code=$(_denon_extract_main_power "$power_xml")
    source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="1" index="\([0-9]\+\)".*:\1:p')
    raw_vol=$(_denon_extract_main_volume_raw "$vol_xml")
    mute=$(_denon_resolve_main_mute "$(_denon_extract_main_mute "$vol_xml")")
    source_name=$(_denon_alias_for_source "1" "$source_idx" || _denon_source_name_by_idx "1" "$source_idx")

    case "$power_code" in
      1) power="ON" ;;
      2) power="STANDBY" ;;
      3) power="OFF" ;;
      *) power="UNKNOWN" ;;
    esac

    if [[ -n "$raw_vol" ]]; then
      db=$(_denon_raw_to_db "$raw_vol")
    else
      db="null"
    fi

    muted_json=$(_denon_mute_json_value "$mute")
    source_json=$(printf '%s' "${source_name:-Unknown}" | _denon_json_escape)

    printf '{"ip":"%s","power":"%s","sourceIndex":%s,"sourceName":"%s","volumeDb":%s,"muted":%s}\n' \
      "$IP" "$power" "${source_idx:-null}" "$source_json" "$db" "$muted_json"
  }

  _denon_sources() {
    local zone=1 format=text arg
    for arg in "$@"; do
      case "$arg" in
        --json) format=json ;;
        [0-9]*) zone="$arg" ;;
      esac
    done

    local source_idx
    source_idx=$(_denon_current_source_idx "$zone")
    if [[ -z "$source_idx" ]]; then
      echo "Error: could not read source list for zone $zone from receiver" >&2
      return 1
    fi

    if [[ "$format" == "json" ]]; then
      _denon_source_rows_with_aliases "$zone" |
        awk -F '\t' -v current="$source_idx" -v zone="$zone" '
          function jsesc(s,  out) {
            out=s; gsub(/\\/, "\\\\", out); gsub(/"/, "\\\"", out)
            gsub(/\n/, "\\n", out); gsub(/\r/, "", out)
            return out
          }
          BEGIN { print "[" }
          {
            sep=(NR==1 ? "" : ",")
            active=($1==current ? "true" : "false")
            printf "%s  {\"zone\":%s,\"index\":\"%s\",\"receiverName\":\"%s\",\"displayName\":\"%s\",\"active\":%s}\n",
              sep, zone, jsesc($1), jsesc($2), jsesc($3), active
          }
          END { print "]" }
        '
      return
    fi

    if [[ "$zone" == "1" ]]; then
      echo "Main Zone sources:"
    else
      echo "Zone $zone sources:"
    fi

    _denon_source_rows_with_aliases "$zone" |
      awk -F '\t' -v current="$source_idx" '
        {
          marker=($1 == current ? "*" : " ")
          if ($2 == $3) {
            printf "%s %2s  %s\n", marker, $1, $3
          } else {
            printf "%s %2s  %s (receiver: %s)\n", marker, $1, $3, $2
          }
        }
      '
  }

  _denon_signal_debug_indent() {
    sed 's/^/  /'
  }

  _denon_signal_debug() {
    local source_idx source_name si_text ins_text asp_text ms_text

    source_idx=$(_denon_current_source_idx 1)
    source_name=$(_denon_alias_for_source "1" "$source_idx" || _denon_source_name_by_idx "1" "$source_idx" || printf 'Unknown')

    si_text=$(_denon_telnet_query "SI?" 2>&1 | tr '\r' '\n' | sed '/^$/d')
    ins_text=$(_denon_telnet_query "OPINFINS ?" 2>&1 | tr '\r' '\n' | sed '/^$/d')
    asp_text=$(_denon_telnet_query "OPINFASP ?" 2>&1 | tr '\r' '\n' | sed '/^$/d')
    ms_text=$(_denon_telnet_query "MS?" 2>&1 | tr '\r' '\n' | sed -n '/^OPINF/p; /^SYS/p; /^MS/p')

    echo "Signal diagnostics"
    echo "Decoder status: no proven connected/live-signal mapping is enabled."
    echo
    echo "Selected source:"
    printf '  %s (%s)\n' "${source_name:-Unknown}" "${source_idx:-unknown}"
    echo
    echo "Configured main-zone sources:"
    _denon_source_rows_with_aliases 1 |
      awk -F '\t' -v current="$source_idx" '{
        marker=($1 == current ? "*" : " ")
        printf "  %s %2s  %s\n", marker, $1, $3
      }'
    echo
    echo "Raw telnet fields:"
    echo "  SI?:"
    printf '%s\n' "${si_text:-unavailable}" | _denon_signal_debug_indent
    echo "  OPINFINS ?:"
    printf '%s\n' "${ins_text:-unavailable}" | _denon_signal_debug_indent
    echo "  OPINFASP ?:"
    printf '%s\n' "${asp_text:-unavailable}" | _denon_signal_debug_indent
    echo "  MS? signal-related lines:"
    printf '%s\n' "${ms_text:-unavailable}" | _denon_signal_debug_indent
    echo
    echo "Sources with actual detected signal/presence: not available; OPINFINS/OPINFASP remain undecoded."
  }

  _denon_raw_get() {
    local type="$1"
    if [[ -z "$type" ]] || ! _denon_is_unsigned_integer "$type"; then
      echo "Usage: denon raw get <type>" >&2
      return 1
    fi
    _denon_get_config "$type"
  }

  _denon_raw_set() {
    local type="$1"
    local data="$2"
    if [[ -z "$type" || -z "$data" ]] || ! _denon_is_unsigned_integer "$type"; then
      echo "Usage: denon raw set <type> '<xml payload>'" >&2
      return 1
    fi
    _denon_set_config "$type" "$data" || return 1
    echo "Sent raw set_config type=$type"
  }

  _denon_raw_types() {
    cat <<'EOF'
3 identity
4 power
6 zone names
7 sources
8 setup lock
9 Bluetooth/headphones
10 speaker preset
11 system
12 volume
EOF
  }

  _denon_raw_dump() {
    local -a types=("$@")
    local type
    (( ${#types[@]} )) || types=(3 4 6 7 8 9 10 11 12)
    for type in "${types[@]}"; do
      if ! _denon_is_unsigned_integer "$type"; then
        echo "Usage: denon raw dump [type ...]" >&2
        return 1
      fi
      printf '%s\n' "----- type $type -----"
      _denon_get_config "$type" || return 1
      printf '\n'
    done
  }

  _denon_snapshot() {
    local outdir="${1:-$PWD/denon-snapshot-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$outdir" || return 1
    printf '%s\n' "$IP" >"$outdir/ip.txt"
    local type
    for type in 3 4 7 12; do
      _denon_get_config "$type" >"$outdir/type_${type}.xml" || return 1
    done
    {
      echo "receiver_ip=$IP"
      echo "generated_at=$(_denon_iso_now)"
    } >"$outdir/metadata.txt"
    echo "Snapshot saved to $outdir"
  }

  _denon_normalize_xml() {
    _denon_xml_split_tags <"$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
  }

  _denon_snapshot_diff() {
    local dir_a="$1" dir_b="$2"
    [[ -n "$dir_a" && -n "$dir_b" ]] || {
      echo "Usage: denon diff <snapshot-a> <snapshot-b>" >&2; return 1
    }
    [[ -d "$dir_a" ]] || { echo "Error: not a directory: $dir_a" >&2; return 1; }
    [[ -d "$dir_b" ]] || { echo "Error: not a directory: $dir_b" >&2; return 1; }

    echo "A: $dir_a"
    echo "B: $dir_b"
    local ts_a ts_b
    ts_a=$(grep -m1 'generated_at' "$dir_a/metadata.txt" 2>/dev/null | cut -d= -f2-)
    ts_b=$(grep -m1 'generated_at' "$dir_b/metadata.txt" 2>/dev/null | cut -d= -f2-)
    [[ -n "$ts_a" ]] && echo "  A taken: $ts_a"
    [[ -n "$ts_b" ]] && echo "  B taken: $ts_b"
    echo

    local any_diff=0 file label tmp_a tmp_b
    for file in ip.txt type_3.xml type_4.xml type_7.xml type_12.xml; do
      local path_a="$dir_a/$file" path_b="$dir_b/$file"
      [[ -f "$path_a" || -f "$path_b" ]] || continue

      case "$file" in
        ip.txt)      label="Receiver IP" ;;
        type_3.xml)  label="Identity / System  (type 3)" ;;
        type_4.xml)  label="Power / Source      (type 4)" ;;
        type_7.xml)  label="Streaming / Network (type 7)" ;;
        type_12.xml) label="Volume / Mute       (type 12)" ;;
        *)           label="$file" ;;
      esac

      if [[ ! -f "$path_a" ]]; then
        echo "  $label: missing in A"
        any_diff=1; continue
      fi
      if [[ ! -f "$path_b" ]]; then
        echo "  $label: missing in B"
        any_diff=1; continue
      fi

      tmp_a=$(mktemp)
      tmp_b=$(mktemp)
      if [[ "$file" == *.xml ]]; then
        _denon_normalize_xml "$path_a" >"$tmp_a"
        _denon_normalize_xml "$path_b" >"$tmp_b"
      else
        cp "$path_a" "$tmp_a"
        cp "$path_b" "$tmp_b"
      fi

      if diff -q "$tmp_a" "$tmp_b" >/dev/null 2>&1; then
        echo "  $label: no change"
      else
        any_diff=1
        echo "  $label:"
        diff --unified=0 "$tmp_a" "$tmp_b" 2>/dev/null \
          | grep '^[+-]' | grep -v '^[+-][+-][+-]' \
          | sed 's/^-/    A: /; s/^+/    B: /'
      fi
      rm -f "$tmp_a" "$tmp_b"
    done

    echo
    if (( any_diff == 0 )); then
      echo "No differences found."
    fi
  }

  _denon_data_usage() {
    cat <<'EOF'
Usage:
  denon data fields --all
  denon data fields --available
  denon data dump --readable
  denon data dump --all
  denon data dump --json
  denon data dump --raw [--full]
  denon data discover [--json]
  denon data capabilities [--json] [--source file] [--probe-safe]
  denon data summary [--json]

Notes:
  --all shows data fields known to this tool and where they come from.
  --available, dump, and discover query the configured AVR using read-only GET/query paths.
  capabilities defaults to offline inventory from references/deviceinfo_capabilities.xml.
  capabilities --probe-safe fetches live Deviceinfo.xml and probes only exact allowlisted Get* AppCommand verbs.
  summary queries existing safe read-only data surfaces and prints concise diagnostics.
EOF
  }

  _denon_data_field_catalog() {
    cat <<'EOF'
Receiver identity	power_xml	receiver_name	type 3 XML / FriendlyName
Receiver identity	power_xml	receiver_ip	discovered receiver IP
Receiver identity	type_1	brand_code	type 1 XML / Brand
Receiver identity	type_5	model_type	type 5 XML / ModelType
Network / HEOS	heos_players	heos_model	HEOS player/get_players / model
Network / HEOS	heos_players	heos_version	HEOS player/get_players / version
Network / HEOS	heos_players	network	HEOS player/get_players / network
Main Zone	type_6	main_zone_name	type 6 XML / MainZone
Main Zone	type_4	power	type 4 XML / MainZone/Power
Main Zone	type_7	source_index	type 7 XML / Zone zone=1 @index
Main Zone	type_7	source_name	type 7 XML / Zone zone=1 source map lookup
Main Zone	type_12	volume_raw	type 12 XML / MainZone/Volume
Main Zone	type_12	volume_db	raw volume converted to dB
Main Zone	type_12	volume_scale	type 12 XML / MainZone/VolumeScale
Main Zone	type_12	volume_limit_raw	type 12 XML / MainZone/VolumeLimit
Main Zone	type_12	volume_max_db	type 12 XML / MainZone/Max
Main Zone	type_12	muted	type 12 XML / MainZone/Mute
Zone 2	type_6	zone2_name	type 6 XML / Zone2
Zone 2	type_4	power	type 4 XML / Zone2/Power
Zone 2	type_7	source_index	type 7 XML / Zone zone=2 @index
Zone 2	type_7	source_name	type 7 XML / Zone zone=2 source map lookup
Zone 2	type_12	volume_raw	type 12 XML / Zone2/Volume
Zone 2	type_12	volume_db	raw volume converted to dB
Zone 2	type_12	volume_scale	type 12 XML / Zone2/VolumeScale
Zone 2	type_12	volume_limit_raw	type 12 XML / Zone2/VolumeLimit
Zone 2	type_12	muted	type 12 XML / Zone2/Mute
Sources	type_7	main_zone_sources	type 7 XML / Zone zone=1 source list
Sources	type_7	zone2_sources	type 7 XML / Zone zone=2 source list
Audio / surround	telnet_ms	sound_mode	telnet MS? / SYSMI
Sleep timer	telnet_sleep	main_zone_sleep	telnet SLP?
Sleep timer	telnet_sleep	zone2_sleep	telnet Z2SLP?
Tone / Audyssey	telnet_ps	dynamic_eq	telnet PSDYNEQ ?
Tone / Audyssey	telnet_ps	dynamic_volume	telnet PSDYNVOL ?
Tone / Audyssey	telnet_ps	cinema_eq	telnet PSCINEMA EQ. ?
Tone / Audyssey	telnet_ps	multeq	telnet PSMULTEQ ?
Tone / Audyssey	telnet_ps	bass	telnet PSBAS ?
Tone / Audyssey	telnet_ps	treble	telnet PSTRE ?
Tone / Audyssey	telnet_ps	subwoofer_enabled	telnet PSSWR ?
Tone / Audyssey	telnet_ps	subwoofer_level_db	telnet PSSWL ? (converted to dB)
Tone / Audyssey	telnet_ps	loudness_management	telnet PSLOM ?
Tone / Audyssey	telnet_cv	channel_levels	telnet CV? per-channel trims
Network / HEOS	heos_players	heos_volume_level	HEOS player/get_volume (main player)
System	type_8	setup_lock	type 8 XML / SetupLock raw code
System	type_9	bt_headphones_single_used	type 9 XML / BtHeadphonesSingleUsed raw code
System	type_10	speaker_preset	type 10 XML / SpeakerPreset raw code
System	type_11	advanced_mode	type 11 XML / System/AdvancedMode raw code
System	type_11	ci_mode	type 11 XML / System/CIMode raw code
System	type_11	menu_lock	type 11 XML / System/MenuLock raw code
System	type_11	gui_type	type 11 XML / System/GuiType raw code
System	type_11	heos_sign_in	type 11 XML / System/HEOSSignIn raw code
System	type_11	webui_type	type 11 XML / System/WebUIType raw code
System	type_11	product_type	type 11 XML / System/ProductType raw code
UPnP / Device Identity	upnp_deviceinfo	upnp_model	:8080/goform/Deviceinfo.xml / ModelName
UPnP / Device Identity	upnp_deviceinfo	upnp_mac	:8080/goform/Deviceinfo.xml / MacAddress
UPnP / Device Identity	upnp_deviceinfo	pending_upgrade_version	:8080/goform/Deviceinfo.xml / UpgradeVersion (pending update metadata, not installed firmware)
UPnP / Device Identity	upnp_deviceinfo	comm_api_vers	:8080/goform/Deviceinfo.xml / CommApiVers
UPnP / Device Identity	upnp_deviceinfo	device_zones	:8080/goform/Deviceinfo.xml / DeviceZones
UPnP / Device Identity	upnp_aios	serial_number	:60006/upnp/desc/aios_device/aios_device.xml / serialNumber
UPnP / Device Identity	upnp_aios	aios_firmware	:60006/upnp/desc/aios_device/aios_device.xml / modelNumber
UPnP / Device Identity	upnp_aios	udn	:60006/upnp/desc/aios_device/aios_device.xml / UDN
Now Playing	now_playing	title	formNetAudio_StatusXml.xml / Song
Now Playing	now_playing	artist	formNetAudio_StatusXml.xml / Artist
Now Playing	now_playing	album	formNetAudio_StatusXml.xml / Album
Raw XML endpoints	get_config	type_3	/ajax/globals/get_config?type=3
Raw XML endpoints	get_config	type_4	/ajax/globals/get_config?type=4
Raw XML endpoints	get_config	type_6	/ajax/globals/get_config?type=6
Raw XML endpoints	get_config	type_7	/ajax/globals/get_config?type=7
Raw XML endpoints	get_config	type_12	/ajax/globals/get_config?type=12
Raw XML endpoints	get_config	discovered_types	/ajax/globals/get_config?type=N for N=0..DENON_DATA_DISCOVERY_MAX_TYPE
Web UI information	web_ui	general_page	/general/general.html
Web UI information	web_ui	discovered_links	same-host read-only HTML/JS/XML/AJAX links referenced by the receiver UI
Discovered read-only endpoints	web_js	safe_ajax_paths	read-only URL-looking strings found in receiver HTML/JS
EOF
  }

  _denon_data_endpoint_types() {
    printf '%s\n' 3 4 6 7 12
  }

  _denon_data_endpoint_name() {
    case "$1" in
      3) printf 'Identity / System' ;;
      4) printf 'Power' ;;
      6) printf 'Zone names' ;;
      7) printf 'Sources' ;;
      12) printf 'Volume / Mute' ;;
      *) printf 'type %s' "$1" ;;
    esac
  }

  _denon_data_discovery_max_type() {
    local max_type="${DENON_DATA_DISCOVERY_MAX_TYPE:-30}"
    if ! _denon_is_unsigned_integer "$max_type"; then
      echo "Error: DENON_DATA_DISCOVERY_MAX_TYPE must be an unsigned integer" >&2
      return 1
    fi
    printf '%s' "$max_type"
  }

  _denon_data_response_has_data() {
    local body="$1"
    [[ -n "$(_denon_trim "$body")" ]] || return 1
    printf '%s' "$body" | grep -qi '<html' && return 1
    printf '%s' "$body" | grep -qiE 'not found|invalid|error|failed' && return 1
    printf '%s' "$body" | grep -q '<' || return 1
    return 0
  }

  _denon_data_discovery_delay() {
    local delay="$1"
    sleep "$delay" 2>/dev/null || true
  }

  _denon_data_var_id() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_]/_/g'
  }

  _denon_data_store_get_config() {
    local type="$1"
    local body="$2"
    local var="data_get_config_raw_${type}"
    printf -v "$var" '%s' "$body"
    data_get_config_types="${data_get_config_types}${type}"$'\n'
    case "$type" in
      1) data_raw_type_1="$body" ;;
      2) data_raw_type_2="$body" ;;
      3) data_raw_type_3="$body" ;;
      4) data_raw_type_4="$body" ;;
      5) data_raw_type_5="$body" ;;
      6) data_raw_type_6="$body" ;;
      7) data_raw_type_7="$body" ;;
      8) data_raw_type_8="$body" ;;
      9) data_raw_type_9="$body" ;;
      10) data_raw_type_10="$body" ;;
      11) data_raw_type_11="$body" ;;
      12) data_raw_type_12="$body" ;;
    esac
  }

  _denon_data_store_raw_body() {
    local label="$1"
    local path="$2"
    local body="$3"
    local idx

    data_raw_web_count=$((data_raw_web_count + 1))
    idx="$data_raw_web_count"
    printf -v "data_raw_web_${idx}_label" '%s' "$label"
    printf -v "data_raw_web_${idx}_path" '%s' "$path"
    printf -v "data_raw_web_${idx}_body" '%s' "$body"
  }

  _denon_data_xml_leaf_paths() {
    local xml="$1"

    printf '%s' "$xml" |
      _denon_xml_split_tags |
      awk '
        function tag_name(line, out) {
          out=line
          sub(/^<\//, "", out)
          sub(/^</, "", out)
          sub("[ >/].*$", "", out)
          return out
        }
        function path(  i, out) {
          out=""
          for (i=1; i<=depth; i++) out=(out == "" ? stack[i] : out "." stack[i])
          return out
        }
        {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          if ($0 ~ /^<\?/) next
          if ($0 ~ /^<!--/) next
          if ($0 ~ /^<[^\/][^>]*>[^<]+<\/[^>]+>$/) {
            name=tag_name($0)
            value=$0
            sub(/^<[^>]*>/, "", value)
            sub(/<\/[^>]+>$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value != "") printf "%s%s%s\t%s\n", path(), (path() == "" ? "" : "."), name, value
            next
          }
          if ($0 ~ /^<[^\/!][^>]*>$/ && $0 !~ /\/>$/) {
            stack[++depth]=tag_name($0)
            next
          }
          if ($0 ~ /^<\//) {
            if (depth > 0) depth--
            next
          }
        }
      '
  }

  _denon_data_xml_leaf_first() {
    local xml="$1"
    local wanted_path="$2"

    _denon_data_xml_leaf_paths "$xml" |
      awk -F '\t' -v wanted="$wanted_path" '$1 == wanted { print $2; found=1; exit } END { exit found ? 0 : 1 }'
  }

  _denon_data_is_promoted_xml_leaf() {
    local type="$1"
    local path="$2"

    case "${type}:${path}" in
      1:Brand|3:FriendlyName|4:listGlobals.MainZone.Power|4:listGlobals.Zone2.Power|5:ModelType|6:ZoneRename.MainZone|6:ZoneRename.Zone2)
        return 0
        ;;
      7:SourceList.Zone.Source.Name)
        return 0
        ;;
      8:SetupLock|9:BtHeadphonesSingleUsed|10:SpeakerPreset)
        return 0
        ;;
      11:System.AdvancedMode|11:System.CIMode|11:System.MenuLock|11:System.GuiType|11:System.HEOSSignIn|11:System.WebUIType|11:System.ProductType)
        return 0
        ;;
      12:listGlobals.MainZone.Volume|12:listGlobals.MainZone.VolumeScale|12:listGlobals.MainZone.VolumeLimit|12:listGlobals.MainZone.Mute|12:listGlobals.MainZone.Max)
        return 0
        ;;
      12:listGlobals.Zone2.Volume|12:listGlobals.Zone2.VolumeScale|12:listGlobals.Zone2.VolumeLimit|12:listGlobals.Zone2.Mute)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_data_add_xml_leaves() {
    local type="$1"
    local xml="$2"
    local path value field

    while IFS=$'\t' read -r path value; do
      [[ -n "$path$value" ]] || continue
      data_get_config_leaf_records+="${type}"$'\t'"${path}"$'\t'"${value}"$'\n'
      _denon_data_is_promoted_xml_leaf "$type" "$path" && continue
      field="type_${type}.${path}"
      _denon_data_add_value "xml_leaves" "Unhandled parsed XML leaves" "$field" "$value"
    done < <(_denon_data_xml_leaf_paths "$xml")
  }

  _denon_data_safe_path() {
    local path="$1"
    local lower

    [[ -n "$path" ]] || return 1
    case "$path" in
      http://*|https://*|//*|mailto:*|javascript:*|\#*) return 1 ;;
    esac
    [[ "$path" == /* ]] || path="/$path"
    lower=$(_denon_lower "$path")
    case "$lower" in
      *set*|*cmd*|*update*|*upgrade*|*upload*|*delete*|*reboot*|*factory*|*write*|*save*|*apply*|*logout*|*password*|*account*) return 1 ;;
    esac
    case "$lower" in
      *.html|*.htm|*.js|*.css|*.xml|/ajax/*|*get_config*|*status*|*information*|*general*) printf '%s' "$path"; return 0 ;;
    esac
    return 1
  }

  _denon_data_discover_web_endpoints_from_text() {
    local text="$1"
    local token safe

    {
      # Bug B-1 fix: parse HTML attribute-embedded paths from src=/href= attributes.
      printf '%s' "$text" |
        grep -oiE '(src|href)="[^"]*"' |
        sed 's/^[^=]*="//; s/"$//'

      # Token-split approach for bare path strings in JS/HTML.
      # Bug B-2 fix: accept only tokens that look like clean URL paths —
      # leading / followed by [A-Za-z0-9_\-./]+ — and reject any token
      # containing , ; = ? & | : ( ) { } or whitespace.
      printf '%s' "$text" |
        grep -oE '"[/][A-Za-z0-9_./-][A-Za-z0-9_./-]*"' |
        sed 's/^"//; s/"$//'
    } | while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        # Reject tokens containing forbidden characters (Bug B-2 tightening).
        case "$token" in
          *[',;=?&|:(){}']* | *\ * | *$'\t'*) continue ;;
        esac
        safe=$(_denon_data_safe_path "$token") || continue
        printf '%s\n' "$safe"
      done | awk '!seen[$0]++'
  }

  _denon_data_parse_web_information() {
    local html="$1"

    printf '%s' "$html" |
      sed 's/<script[^>]*>.*<\/script>//g; s/<style[^>]*>.*<\/style>//g' |
      sed 's/<[^>]*>/\n/g' |
      sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/^[[:space:]]*//; s/[[:space:]]*$//' |
      awk '
        function next_value(  line) {
          while ((getline line) > 0) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line != "") return line
          }
          return ""
        }
        function emit(label, value) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          if (label != "" && value != "") print label "\t" value
        }
        /^(Firmware Version|DTS Version|Input Signal|Sound Mode|Format|HDR|HDMI Signal Info|HDMI Monitor Interface|Main Zone|Zone 2|Notifications)/ {
          label=$0
          value=next_value()
          emit(label, value)
        }
        /:$/ {
          label=$0
          sub(/:$/, "", label)
          value=next_value()
          emit(label, value)
        }
      ' | awk '!seen[$0]++'
  }

  _denon_data_fetch_path() {
    local path="$1"
    _denon_curl -L "${BASE}${path}" 2>/dev/null
  }

  _denon_data_print_field_catalog() {
    local category="" line_category line_field line_source

    printf 'Known read-only/exposed Denon AVR fields and endpoints supported by this tool.\n'
    printf 'This is not a list of hidden firmware internals.\n\n'
    while IFS=$'\t' read -r line_category _ line_field line_source; do
      [[ -n "$line_category" ]] || continue
      if [[ "$line_category" != "$category" ]]; then
        [[ -z "$category" ]] || printf '\n'
        printf '%s\n' "$line_category"
        category="$line_category"
      fi
      printf '  %-22s %s\n' "$line_field" "$line_source"
    done < <(_denon_data_field_catalog)
  }

  _denon_data_add_value() {
    local group_key="$1"
    local group_label="$2"
    local field_key="$3"
    local value="$4"

    value=$(_denon_trim "${value:-}")
    [[ -n "$value" ]] || return 0
    data_available_records+="${group_key}"$'\t'"${group_label}"$'\t'"${field_key}"$'\t'"${value}"$'\n'
  }

  _denon_data_source_json_array() {
    local rows="$1"

    printf '['
    printf '%s\n' "$rows" | awk -F '\t' '
      function jsesc(s, out) {
        out=s
        gsub(/\\/, "\\\\", out)
        gsub(/"/, "\\\"", out)
        gsub(/\n/, "\\n", out)
        gsub(/\r/, "", out)
        return out
      }
      NF >= 3 {
        sep=(count++ > 0 ? "," : "")
        printf "%s{\"index\":\"%s\",\"receiver_name\":\"%s\",\"display_name\":\"%s\"}",
          sep, jsesc($1), jsesc($2), jsesc($3)
      }
    '
    printf ']'
  }

  _denon_data_print_readable() {
    local current="" group_key group_label field_key value

    while IFS=$'\t' read -r group_key group_label field_key value; do
      [[ -n "$group_label" ]] || continue
      if [[ "$group_label" != "$current" ]]; then
        [[ -z "$current" ]] || printf '\n'
        printf '%s\n' "$(_denon_display_section_label "$group_label")"
        current="$group_label"
      fi
      value=$(_denon_display_data_value "$field_key" "$value")
      printf '  %-22s %s\n' "$field_key" "$value"
    done <<<"$data_available_records"
  }

  _denon_data_print_json_section() {
    local wanted_key="$1"
    local group_key group_label field_key value
    local first=1

    printf '{'
    while IFS=$'\t' read -r group_key group_label field_key value; do
      [[ "$group_key" == "$wanted_key" ]] || continue
      (( first )) || printf ','
      printf '"%s":"%s"' "$field_key" "$(printf '%s' "$value" | _denon_json_escape)"
      first=0
    done <<<"$data_available_records"
    printf '}'
  }

  _denon_data_record_value() {
    local wanted_group="$1"
    local wanted_field="$2"

    awk -F '\t' -v group="$wanted_group" -v field="$wanted_field" \
      '$1 == group && $3 == field { print $4; found=1; exit } END { exit found ? 0 : 1 }' <<<"$data_available_records"
  }

  _denon_data_raw_label() {
    local raw="$1"

    if [[ -z "$raw" ]]; then
      printf 'unknown'
    else
      printf 'unknown'
    fi
  }

  _denon_data_print_raw_labeled_line() {
    local label="$1"
    local raw="$2"
    local text

    text=$(_denon_display_unknown "$raw")
    printf '  %-28s raw=%s label=%s\n' "$label" "$text" "$(_denon_display_unknown "$(_denon_data_raw_label "$raw")")"
  }

  _denon_data_json_string_or_null() {
    local value="$1"

    if [[ -z "$value" ]]; then
      printf 'null'
    else
      printf '"%s"' "$(printf '%s' "$value" | _denon_json_escape)"
    fi
  }

  _denon_data_json_raw_label() {
    local raw="$1"

    printf '{"raw":'
    _denon_data_json_string_or_null "$raw"
    printf ',"label":"%s"}' "$(_denon_data_raw_label "$raw")"
  }

  _denon_data_print_summary_readable() {
    local receiver ip brand_code model_type
    local main_zone main_volume_scale main_volume_limit main_volume_max
    local zone2_name zone2_volume_scale zone2_volume_limit
    local setup_lock bt_headphones speaker_preset advanced_mode ci_mode menu_lock gui_type heos_sign_in webui_type product_type
    local heos_model heos_version network pending_upgrade_version aios_firmware

    receiver=$(_denon_data_record_value "receiver" "name" 2>/dev/null || printf '')
    ip=$(_denon_data_record_value "receiver" "ip" 2>/dev/null || printf '')
    brand_code=$(_denon_data_record_value "receiver" "brand_code" 2>/dev/null || printf '')
    model_type=$(_denon_data_record_value "receiver" "model_type" 2>/dev/null || printf '')
    main_zone=$(_denon_data_record_value "main_zone" "zone_name" 2>/dev/null || printf '')
    main_volume_scale=$(_denon_data_record_value "main_zone" "volume_scale" 2>/dev/null || printf '')
    main_volume_limit=$(_denon_data_record_value "main_zone" "volume_limit_raw" 2>/dev/null || printf '')
    main_volume_max=$(_denon_data_record_value "main_zone" "volume_max_db" 2>/dev/null || printf '')
    zone2_name=$(_denon_data_record_value "zone2" "zone_name" 2>/dev/null || printf '')
    zone2_volume_scale=$(_denon_data_record_value "zone2" "volume_scale" 2>/dev/null || printf '')
    zone2_volume_limit=$(_denon_data_record_value "zone2" "volume_limit_raw" 2>/dev/null || printf '')
    setup_lock=$(_denon_data_record_value "system" "setup_lock" 2>/dev/null || printf '')
    bt_headphones=$(_denon_data_record_value "system" "bt_headphones_single_used" 2>/dev/null || printf '')
    speaker_preset=$(_denon_data_record_value "system" "speaker_preset" 2>/dev/null || printf '')
    advanced_mode=$(_denon_data_record_value "system" "advanced_mode" 2>/dev/null || printf '')
    ci_mode=$(_denon_data_record_value "system" "ci_mode" 2>/dev/null || printf '')
    menu_lock=$(_denon_data_record_value "system" "menu_lock" 2>/dev/null || printf '')
    gui_type=$(_denon_data_record_value "system" "gui_type" 2>/dev/null || printf '')
    heos_sign_in=$(_denon_data_record_value "system" "heos_sign_in" 2>/dev/null || printf '')
    webui_type=$(_denon_data_record_value "system" "webui_type" 2>/dev/null || printf '')
    product_type=$(_denon_data_record_value "system" "product_type" 2>/dev/null || printf '')
    heos_model=$(_denon_data_record_value "network_heos" "heos_model" 2>/dev/null || printf '')
    heos_version=$(_denon_data_record_value "network_heos" "heos_version" 2>/dev/null || printf '')
    network=$(_denon_data_record_value "network_heos" "network" 2>/dev/null || printf '')
    pending_upgrade_version=$(_denon_data_record_value "upnp" "pending_upgrade_version" 2>/dev/null || printf '')
    aios_firmware=$(_denon_data_record_value "upnp" "aios_firmware" 2>/dev/null || printf '')

    printf 'Receiver Diagnostics\n'
    printf '  %-28s %s\n' "name" "$(_denon_display_unknown "$receiver")"
    printf '  %-28s %s\n' "ip" "$(_denon_display_unknown "$ip")"
    _denon_data_print_raw_labeled_line "brand_code" "$brand_code"
    _denon_data_print_raw_labeled_line "model_type" "$model_type"
    printf '\n'

    printf 'Volume Diagnostics\n'
    printf '  %-28s %s\n' "main_zone" "$(_denon_display_zone_label "$main_zone")"
    _denon_data_print_raw_labeled_line "main_volume_scale" "$main_volume_scale"
    printf '  %-28s %s\n' "main_volume_limit_raw" "$(_denon_display_unknown "$main_volume_limit")"
    printf '  %-28s %s dB\n' "main_volume_max" "$(_denon_display_unknown "$main_volume_max")"
    printf '  %-28s %s\n' "zone2" "$(_denon_display_zone_label "$zone2_name")"
    _denon_data_print_raw_labeled_line "zone2_volume_scale" "$zone2_volume_scale"
    printf '  %-28s %s\n' "zone2_volume_limit_raw" "$(_denon_display_unknown "$zone2_volume_limit")"
    printf '\n'

    printf 'System Diagnostics\n'
    _denon_data_print_raw_labeled_line "setup_lock" "$setup_lock"
    _denon_data_print_raw_labeled_line "menu_lock" "$menu_lock"
    _denon_data_print_raw_labeled_line "advanced_mode" "$advanced_mode"
    _denon_data_print_raw_labeled_line "ci_mode" "$ci_mode"
    _denon_data_print_raw_labeled_line "speaker_preset" "$speaker_preset"
    _denon_data_print_raw_labeled_line "gui_type" "$gui_type"
    _denon_data_print_raw_labeled_line "webui_type" "$webui_type"
    _denon_data_print_raw_labeled_line "product_type" "$product_type"
    _denon_data_print_raw_labeled_line "bt_headphones_single_used" "$bt_headphones"
    _denon_data_print_raw_labeled_line "heos_sign_in" "$heos_sign_in"
    printf '\n'

    printf 'Network / Firmware Notes\n'
    printf '  %-28s %s\n' "heos_model" "$(_denon_display_unknown "$heos_model")"
    printf '  %-28s %s (separate HEOS firmware, not AVR mainboard firmware)\n' "heos_version" "$(_denon_display_unknown "$heos_version")"
    printf '  %-28s %s\n' "network" "$(_denon_display_network_label "$network")"
    printf '  %-28s %s (pending update metadata, not installed firmware)\n' "pending_upgrade_version" "$(_denon_display_unknown "$pending_upgrade_version")"
    printf '  %-28s %s (separate AIOS/HEOS firmware, not AVR mainboard firmware)\n' "aios_firmware" "$(_denon_display_unknown "$aios_firmware")"
    printf '  %-28s %s\n' "avr_mainboard_firmware" "unavailable on tested read-only surfaces"
  }

  _denon_data_print_summary_json() {
    local receiver ip brand_code model_type
    local main_zone main_volume_scale main_volume_limit main_volume_max
    local zone2_name zone2_volume_scale zone2_volume_limit
    local setup_lock bt_headphones speaker_preset advanced_mode ci_mode menu_lock gui_type heos_sign_in webui_type product_type
    local heos_model heos_version network pending_upgrade_version aios_firmware

    receiver=$(_denon_data_record_value "receiver" "name" 2>/dev/null || printf '')
    ip=$(_denon_data_record_value "receiver" "ip" 2>/dev/null || printf '')
    brand_code=$(_denon_data_record_value "receiver" "brand_code" 2>/dev/null || printf '')
    model_type=$(_denon_data_record_value "receiver" "model_type" 2>/dev/null || printf '')
    main_zone=$(_denon_data_record_value "main_zone" "zone_name" 2>/dev/null || printf '')
    main_volume_scale=$(_denon_data_record_value "main_zone" "volume_scale" 2>/dev/null || printf '')
    main_volume_limit=$(_denon_data_record_value "main_zone" "volume_limit_raw" 2>/dev/null || printf '')
    main_volume_max=$(_denon_data_record_value "main_zone" "volume_max_db" 2>/dev/null || printf '')
    zone2_name=$(_denon_data_record_value "zone2" "zone_name" 2>/dev/null || printf '')
    zone2_volume_scale=$(_denon_data_record_value "zone2" "volume_scale" 2>/dev/null || printf '')
    zone2_volume_limit=$(_denon_data_record_value "zone2" "volume_limit_raw" 2>/dev/null || printf '')
    setup_lock=$(_denon_data_record_value "system" "setup_lock" 2>/dev/null || printf '')
    bt_headphones=$(_denon_data_record_value "system" "bt_headphones_single_used" 2>/dev/null || printf '')
    speaker_preset=$(_denon_data_record_value "system" "speaker_preset" 2>/dev/null || printf '')
    advanced_mode=$(_denon_data_record_value "system" "advanced_mode" 2>/dev/null || printf '')
    ci_mode=$(_denon_data_record_value "system" "ci_mode" 2>/dev/null || printf '')
    menu_lock=$(_denon_data_record_value "system" "menu_lock" 2>/dev/null || printf '')
    gui_type=$(_denon_data_record_value "system" "gui_type" 2>/dev/null || printf '')
    heos_sign_in=$(_denon_data_record_value "system" "heos_sign_in" 2>/dev/null || printf '')
    webui_type=$(_denon_data_record_value "system" "webui_type" 2>/dev/null || printf '')
    product_type=$(_denon_data_record_value "system" "product_type" 2>/dev/null || printf '')
    heos_model=$(_denon_data_record_value "network_heos" "heos_model" 2>/dev/null || printf '')
    heos_version=$(_denon_data_record_value "network_heos" "heos_version" 2>/dev/null || printf '')
    network=$(_denon_data_record_value "network_heos" "network" 2>/dev/null || printf '')
    pending_upgrade_version=$(_denon_data_record_value "upnp" "pending_upgrade_version" 2>/dev/null || printf '')
    aios_firmware=$(_denon_data_record_value "upnp" "aios_firmware" 2>/dev/null || printf '')

    printf '{"receiver":{"name":'
    _denon_data_json_string_or_null "$receiver"
    printf ',"ip":'
    _denon_data_json_string_or_null "$ip"
    printf ',"brand_code":'
    _denon_data_json_raw_label "$brand_code"
    printf ',"model_type":'
    _denon_data_json_raw_label "$model_type"
    printf '},"volume":{"main_zone":{"zone_name":'
    _denon_data_json_string_or_null "$main_zone"
    printf ',"volume_scale":'
    _denon_data_json_raw_label "$main_volume_scale"
    printf ',"volume_limit_raw":'
    _denon_data_json_string_or_null "$main_volume_limit"
    printf ',"volume_max_db":'
    _denon_data_json_string_or_null "$main_volume_max"
    printf '},"zone2":{"zone_name":'
    _denon_data_json_string_or_null "$zone2_name"
    printf ',"volume_scale":'
    _denon_data_json_raw_label "$zone2_volume_scale"
    printf ',"volume_limit_raw":'
    _denon_data_json_string_or_null "$zone2_volume_limit"
    printf '}},"system":{'
    printf '"setup_lock":'; _denon_data_json_raw_label "$setup_lock"
    printf ',"menu_lock":'; _denon_data_json_raw_label "$menu_lock"
    printf ',"advanced_mode":'; _denon_data_json_raw_label "$advanced_mode"
    printf ',"ci_mode":'; _denon_data_json_raw_label "$ci_mode"
    printf ',"speaker_preset":'; _denon_data_json_raw_label "$speaker_preset"
    printf ',"gui_type":'; _denon_data_json_raw_label "$gui_type"
    printf ',"webui_type":'; _denon_data_json_raw_label "$webui_type"
    printf ',"product_type":'; _denon_data_json_raw_label "$product_type"
    printf ',"bt_headphones_single_used":'; _denon_data_json_raw_label "$bt_headphones"
    printf ',"heos_sign_in":'; _denon_data_json_raw_label "$heos_sign_in"
    printf '},"network":{"heos_model":'
    _denon_data_json_string_or_null "$heos_model"
    printf ',"network":'
    _denon_data_json_string_or_null "$network"
    printf '},"firmware":{"installed_avr_mainboard_firmware":"unavailable_on_tested_read_only_surfaces","pending_upgrade_version":{"value":'
    _denon_data_json_string_or_null "$pending_upgrade_version"
    printf ',"meaning":"pending_update_metadata_not_installed_firmware"},"heos_version":{"value":'
    _denon_data_json_string_or_null "$heos_version"
    printf ',"meaning":"separate_heos_firmware_not_avr_mainboard_firmware"},"aios_firmware":{"value":'
    _denon_data_json_string_or_null "$aios_firmware"
    printf ',"meaning":"separate_aios_heos_firmware_not_avr_mainboard_firmware"}}}\n'
  }

  _denon_data_print_get_config_json() {
    local type raw_var raw first_type=1

    printf '{'
    while IFS= read -r type; do
      [[ -n "$type" ]] || continue
      (( first_type )) || printf ','
      raw_var="data_get_config_raw_${type}"
      raw="${!raw_var:-}"
      printf '"%s":{"raw":"%s","fields":{' "$type" "$(printf '%s' "$raw" | _denon_json_escape)"
      # Bug B-4 fix: repeated sibling elements (same dotted path) are emitted as
      # JSON arrays rather than the last value clobbering all previous ones.
      printf '%s\n' "$data_get_config_leaf_records" |
        awk -F '\t' -v target="$type" '
          function jsesc(s,  out) {
            out=s; gsub(/\\/, "\\\\", out); gsub(/"/, "\\\"", out)
            gsub(/\n/, "\\n", out); gsub(/\r/, "", out); return out
          }
          $1 == target && NF >= 3 {
            path=$2; val=$3
            count[path]++
            if (count[path] == 1) { first[path]=val; vals[path]=jsesc(val) }
            else {
              if (count[path] == 2) vals[path]="\"" jsesc(first[path]) "\",\"" jsesc(val) "\""
              else vals[path]=vals[path] ",\"" jsesc(val) "\""
            }
          }
          END {
            sep=""
            for (path in count) {
              printf "%s\"%s\":", sep, jsesc(path)
              if (count[path] == 1) printf "\"%s\"", vals[path]
              else printf "[%s]", vals[path]
              sep=","
            }
          }
        '
      printf '}}'
      first_type=0
    done <<<"$data_get_config_types"
    printf '}'
  }

  _denon_data_print_discovered_json() {
    local path status content_type summary first=1

    printf '['
    while IFS=$'\t' read -r path status content_type summary; do
      [[ -n "$path" ]] || continue
      (( first )) || printf ','
      printf '{"path":"%s","status":"%s","content_type":"%s","summary":"%s"}' \
        "$(printf '%s' "$path" | _denon_json_escape)" \
        "$(printf '%s' "$status" | _denon_json_escape)" \
        "$(printf '%s' "$content_type" | _denon_json_escape)" \
        "$(printf '%s' "$summary" | _denon_json_escape)"
      first=0
    done <<<"$data_discovered_endpoint_records"
    printf ']'
  }

  _denon_data_print_json() {
    printf '{'
    printf '"receiver":'
    _denon_data_print_json_section "receiver"
    printf ',"heos":'
    _denon_data_print_json_section "network_heos"
    printf ',"main_zone":'
    _denon_data_print_json_section "main_zone"
    printf ',"zone2":'
    _denon_data_print_json_section "zone2"
    printf ',"sources":{"main_zone":'
    _denon_data_source_json_array "$data_source_rows_main"
    printf ',"zone2":'
    _denon_data_source_json_array "$data_source_rows_zone2"
    printf '}'
    printf ',"audio_video":'
    _denon_data_print_json_section "audio_surround"
    printf ',"sleep":'
    _denon_data_print_json_section "sleep_timer"
    printf ',"tone_audyssey":'
    _denon_data_print_json_section "tone_audyssey"
    printf ',"system":'
    _denon_data_print_json_section "system"
    printf ',"now_playing":'
    _denon_data_print_json_section "now_playing"
    printf ',"web_information":'
    _denon_data_print_json_section "web_information"
    printf ',"upnp":'
    _denon_data_print_json_section "upnp"
    printf ',"get_config":'
    _denon_data_print_get_config_json
    printf ',"discovered_endpoints":'
    _denon_data_print_discovered_json
    printf ',"unknown_fields":'
    _denon_data_print_json_section "xml_leaves"
    printf '}'
    printf '\n'
  }

  _denon_data_print_raw() {
    local full="${1:-0}"
    local type value value_var idx label path body body_len label_var path_var body_var
    local max_body=20000

    if [[ "$full" != "1" ]]; then
      printf 'Note: discovered web/JS raw bodies are truncated at %s bytes. Use --raw --full for full bodies.\n\n' "$max_body"
    fi

    while IFS= read -r type; do
      [[ -n "$type" ]] || continue
      value_var="data_get_config_raw_${type}"
      value="${!value_var:-}"
      printf '=== type %s: %s ===\n' "$type" "$(_denon_data_endpoint_name "$type")"
      printf '%s\n\n' "$value"
    done <<<"$data_get_config_types"

    for ((idx=1; idx<=data_raw_web_count; idx++)); do
      label_var="data_raw_web_${idx}_label"
      path_var="data_raw_web_${idx}_path"
      body_var="data_raw_web_${idx}_body"
      label="${!label_var:-web}"
      path="${!path_var:-}"
      body="${!body_var:-}"
      printf '=== %s %s ===\n' "$label" "$path"
      if [[ "$full" == "1" ]]; then
        printf '%s\n\n' "$body"
      else
        body_len=${#body}
        printf '%s\n' "${body:0:max_body}"
        if (( body_len > max_body )); then
          printf '[truncated: %s bytes total]\n' "$body_len"
        fi
        printf '\n'
      fi
    done
  }

  _denon_data_collect_raw_endpoints() {
    local max_type type body rc delay="${DENON_DATA_DISCOVERY_DELAY_SECONDS:-0.08}"

    max_type=$(_denon_data_discovery_max_type) || return 1
    data_get_config_types=""
    data_get_config_leaf_records=""
    data_raw_type_1=""
    data_raw_type_2=""
    data_raw_type_3=""
    data_raw_type_4=""
    data_raw_type_5=""
    data_raw_type_6=""
    data_raw_type_7=""
    data_raw_type_8=""
    data_raw_type_9=""
    data_raw_type_10=""
    data_raw_type_11=""
    data_raw_type_12=""

    for ((type=0; type<=max_type; type++)); do
      body=$(_denon_get_config "$type" 2>/dev/null)
      rc=$?
      if (( rc == 0 )) && _denon_data_response_has_data "$body"; then
        _denon_data_store_get_config "$type" "$body"
        _denon_data_add_xml_leaves "$type" "$body"
        _denon_data_discovery_delay "$delay"
      fi
    done

    [[ -n "$data_raw_type_3" ]] || { echo "Error: failed to query receiver identity data (type 3 XML)" >&2; return 1; }
    [[ -n "$data_raw_type_4" ]] || { echo "Error: failed to query receiver power data (type 4 XML)" >&2; return 1; }
    [[ -n "$data_raw_type_7" ]] || { echo "Error: failed to query receiver source data (type 7 XML)" >&2; return 1; }
    [[ -n "$data_raw_type_12" ]] || { echo "Error: failed to query receiver volume data (type 12 XML)" >&2; return 1; }
  }

  _denon_data_collect_available() {
    local identity_xml power_xml source_xml vol_xml zone_names_xml
    local brand_xml model_type_xml setup_lock_xml bt_headphones_xml speaker_preset_xml system_xml
    local friendly_name main_source_idx zone2_source_idx main_source_name zone2_source_name
    local main_power zone2_power main_mute zone2_mute main_vol_raw zone2_vol_raw
    local mute_raw zone2_mute_raw
    local main_vol_scale main_vol_limit zone2_vol_scale zone2_vol_limit
    local sound_mode_text sleep_line heos_text track_text track_rc
    local dynamic_eq_line dynamic_volume_line cinema_eq_line multeq_line bass_line treble_line
    local dash_main_zone_name="Main Zone" dash_zone2_name="Zone 2"
    local dash_main_max_volume_db="" dash_zone2_volume_db="" dash_zone2_volume_raw=""
    local dash_sound_mode="Unknown"
    local dash_now_title="" dash_now_artist="" dash_now_album="" dash_now_station="" dash_now_service="" dash_now_type="" dash_now_message="" dash_now_available=0
    local dash_heos_pid="" dash_heos_model="" dash_heos_version="" dash_heos_network="" dash_transport_state=""

    data_available_records=""
    data_source_rows_main=""
    data_source_rows_zone2=""
    # shellcheck disable=SC2034 # Stored and read later through indirect raw XML variables.
    data_raw_type_1=""
    # shellcheck disable=SC2034 # Stored and read later through indirect raw XML variables.
    data_raw_type_2=""
    data_raw_type_3=""
    data_raw_type_4=""
    data_raw_type_5=""
    data_raw_type_6=""
    data_raw_type_7=""
    data_raw_type_8=""
    data_raw_type_9=""
    data_raw_type_10=""
    data_raw_type_11=""
    data_raw_type_12=""

    _denon_data_collect_raw_endpoints || return 1
    brand_xml="$data_raw_type_1"
    identity_xml="$data_raw_type_3"
    power_xml="$data_raw_type_4"
    model_type_xml="$data_raw_type_5"
    zone_names_xml="$data_raw_type_6"
    source_xml="$data_raw_type_7"
    setup_lock_xml="$data_raw_type_8"
    bt_headphones_xml="$data_raw_type_9"
    speaker_preset_xml="$data_raw_type_10"
    system_xml="$data_raw_type_11"
    vol_xml="$data_raw_type_12"

    friendly_name=$(printf '%s' "$identity_xml" | sed -n 's:.*<FriendlyName>\([^<]*\)</FriendlyName>.*:\1:p' | sed -n '1p')
    main_source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="1" index="\([0-9]\+\)".*:\1:p' | sed -n '1p')
    zone2_source_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="2" index="\([0-9]\+\)".*:\1:p' | sed -n '1p')
    main_source_name=$(_denon_source_rows_with_aliases_from_xml "1" "$source_xml" | awk -F '\t' -v idx="$main_source_idx" '$1 == idx { print $3; exit }')
    zone2_source_name=$(_denon_source_rows_with_aliases_from_xml "2" "$source_xml" | awk -F '\t' -v idx="$zone2_source_idx" '$1 == idx { print $3; exit }')
    main_power=$(_denon_power_name "$(_denon_extract_main_power "$power_xml")")
    zone2_power=$(_denon_power_name "$(_denon_extract_zone2_power "$power_xml")")
    mute_raw=$(_denon_resolve_main_mute "$(_denon_extract_main_mute "$vol_xml")")
    main_mute=$(_denon_normalize_mute "$mute_raw")
    zone2_mute_raw=$(_denon_resolve_zone2_mute "$(_denon_extract_zone2_mute "$vol_xml")")
    zone2_mute=$(_denon_normalize_mute "$zone2_mute_raw")
    main_vol_raw=$(_denon_extract_main_volume_raw "$vol_xml")
    zone2_vol_raw=$(_denon_extract_zone2_volume_raw "$vol_xml")
    main_vol_scale=$(_denon_data_xml_leaf_first "$vol_xml" "listGlobals.MainZone.VolumeScale" 2>/dev/null || printf '')
    main_vol_limit=$(_denon_data_xml_leaf_first "$vol_xml" "listGlobals.MainZone.VolumeLimit" 2>/dev/null || printf '')
    zone2_vol_scale=$(_denon_data_xml_leaf_first "$vol_xml" "listGlobals.Zone2.VolumeScale" 2>/dev/null || printf '')
    zone2_vol_limit=$(_denon_data_xml_leaf_first "$vol_xml" "listGlobals.Zone2.VolumeLimit" 2>/dev/null || printf '')

    if [[ -n "$zone_names_xml" ]]; then
      _denon_dashboard_parse_zone_names "$zone_names_xml"
    fi
    _denon_dashboard_parse_volume_details "$vol_xml"

    data_source_rows_main=$(_denon_source_rows_with_aliases_from_xml "1" "$source_xml")
    data_source_rows_zone2=$(_denon_source_rows_with_aliases_from_xml "2" "$source_xml")

    _denon_data_add_value "receiver" "Receiver" "name" "$friendly_name"
    _denon_data_add_value "receiver" "Receiver" "ip" "${IP:-}"
    _denon_data_add_value "receiver" "Receiver" "brand_code" "$(_denon_data_xml_leaf_first "$brand_xml" "Brand" 2>/dev/null || printf '')"
    _denon_data_add_value "receiver" "Receiver" "model_type" "$(_denon_data_xml_leaf_first "$model_type_xml" "ModelType" 2>/dev/null || printf '')"
    _denon_data_add_value "main_zone" "Main Zone" "zone_name" "$dash_main_zone_name"
    _denon_data_add_value "main_zone" "Main Zone" "power" "$main_power"
    _denon_data_add_value "main_zone" "Main Zone" "source_index" "$main_source_idx"
    _denon_data_add_value "main_zone" "Main Zone" "source_name" "$main_source_name"
    _denon_data_add_value "main_zone" "Main Zone" "volume_raw" "$main_vol_raw"
    [[ -n "$main_vol_raw" ]] && _denon_data_add_value "main_zone" "Main Zone" "volume_db" "$(_denon_raw_to_db "$main_vol_raw")"
    _denon_data_add_value "main_zone" "Main Zone" "volume_scale" "$main_vol_scale"
    _denon_data_add_value "main_zone" "Main Zone" "volume_limit_raw" "$main_vol_limit"
    _denon_data_add_value "main_zone" "Main Zone" "volume_max_db" "$dash_main_max_volume_db"
    _denon_data_add_value "main_zone" "Main Zone" "muted" "$main_mute"
    _denon_data_add_value "zone2" "Zone 2" "zone_name" "$dash_zone2_name"
    _denon_data_add_value "zone2" "Zone 2" "power" "$zone2_power"
    _denon_data_add_value "zone2" "Zone 2" "source_index" "$zone2_source_idx"
    _denon_data_add_value "zone2" "Zone 2" "source_name" "$zone2_source_name"
    _denon_data_add_value "zone2" "Zone 2" "volume_raw" "$zone2_vol_raw"
    _denon_data_add_value "zone2" "Zone 2" "volume_db" "$dash_zone2_volume_db"
    _denon_data_add_value "zone2" "Zone 2" "volume_scale" "$zone2_vol_scale"
    _denon_data_add_value "zone2" "Zone 2" "volume_limit_raw" "$zone2_vol_limit"
    _denon_data_add_value "zone2" "Zone 2" "muted" "$zone2_mute"
    _denon_data_add_value "sources" "Sources" "main_zone_sources" "$(printf '%s\n' "$data_source_rows_main" | awk -F '\t' '{ printf "%s%s:%s", (NR>1 ? ", " : ""), $1, $3 }')"
    _denon_data_add_value "sources" "Sources" "zone2_sources" "$(printf '%s\n' "$data_source_rows_zone2" | awk -F '\t' '{ printf "%s%s:%s", (NR>1 ? ", " : ""), $1, $3 }')"

    _denon_data_add_value "system" "System" "setup_lock" "$(_denon_data_xml_leaf_first "$setup_lock_xml" "SetupLock" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "bt_headphones_single_used" "$(_denon_data_xml_leaf_first "$bt_headphones_xml" "BtHeadphonesSingleUsed" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "speaker_preset" "$(_denon_data_xml_leaf_first "$speaker_preset_xml" "SpeakerPreset" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "advanced_mode" "$(_denon_data_xml_leaf_first "$system_xml" "System.AdvancedMode" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "ci_mode" "$(_denon_data_xml_leaf_first "$system_xml" "System.CIMode" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "menu_lock" "$(_denon_data_xml_leaf_first "$system_xml" "System.MenuLock" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "gui_type" "$(_denon_data_xml_leaf_first "$system_xml" "System.GuiType" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "heos_sign_in" "$(_denon_data_xml_leaf_first "$system_xml" "System.HEOSSignIn" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "webui_type" "$(_denon_data_xml_leaf_first "$system_xml" "System.WebUIType" 2>/dev/null || printf '')"
    _denon_data_add_value "system" "System" "product_type" "$(_denon_data_xml_leaf_first "$system_xml" "System.ProductType" 2>/dev/null || printf '')"

    sound_mode_text=$(_denon_dashboard_telnet_status 2>/dev/null || printf '')
    if [[ -n "$sound_mode_text" ]]; then
      _denon_dashboard_parse_telnet_status "$sound_mode_text"
      _denon_data_add_value "audio_surround" "Audio / surround" "sound_mode" "$dash_sound_mode"
    fi

    sleep_line=$(_denon_sleep_timer 1 2>/dev/null || printf '')
    _denon_data_add_value "sleep_timer" "Sleep timer" "main_zone_sleep" "${sleep_line#Main zone sleep timer: }"
    sleep_line=$(_denon_sleep_timer 2 2>/dev/null || printf '')
    _denon_data_add_value "sleep_timer" "Sleep timer" "zone2_sleep" "${sleep_line#Zone 2 sleep timer: }"

    dynamic_eq_line=$(_denon_audyssey_toggle "Dynamic EQ" "" "PSDYNEQ" 2>/dev/null || printf '')
    _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "dynamic_eq" "${dynamic_eq_line#Dynamic EQ: }"
    dynamic_volume_line=$(_denon_dynamic_volume 2>/dev/null || printf '')
    _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "dynamic_volume" "${dynamic_volume_line#Dynamic Volume: }"
    cinema_eq_line=$(_denon_cinema_eq 2>/dev/null || printf '')
    _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "cinema_eq" "${cinema_eq_line#Cinema EQ: }"
    multeq_line=$(_denon_multeq 2>/dev/null || printf '')
    _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "multeq" "${multeq_line#MultEQ: }"
    bass_line=$(_denon_tone_control bass 2>/dev/null || printf '')
    _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "bass" "${bass_line#Bass: }"
    treble_line=$(_denon_tone_control treble 2>/dev/null || printf '')
    _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "treble" "${treble_line#Treble: }"

    track_text=$(_denon_track 2>&1)
    track_rc=$?
    _denon_dashboard_parse_now "$track_rc" "$track_text"
    _denon_data_add_value "now_playing" "Now Playing" "title" "$dash_now_title"
    _denon_data_add_value "now_playing" "Now Playing" "artist" "$dash_now_artist"
    _denon_data_add_value "now_playing" "Now Playing" "album" "$dash_now_album"

    heos_text=$(_denon_dashboard_heos_status players-only 2>/dev/null || printf '')
    if [[ -n "$heos_text" ]]; then
      _denon_dashboard_parse_heos_status "$heos_text"
      _denon_data_add_value "network_heos" "Network / HEOS" "heos_model" "$dash_heos_model"
      _denon_data_add_value "network_heos" "Network / HEOS" "heos_version" "$dash_heos_version"
      _denon_data_add_value "network_heos" "Network / HEOS" "network" "$dash_heos_network"
    fi

    # Extended telnet probes (new in Phase 5)
    local _tl_resp _tl_line
    _tl_resp=$(_denon_telnet_query "PSSWR ?" 2>/dev/null || printf '')
    _tl_line=$(printf '%s\n' "$_tl_resp" | tr '\r' '\n' | sed -n '/^PSSWR/ {p; q;}')
    [[ -n "$_tl_line" ]] && _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "subwoofer_enabled" "${_tl_line#PSSWR }"

    _tl_resp=$(_denon_telnet_query "PSSWL ?" 2>/dev/null || printf '')
    _tl_line=$(printf '%s\n' "$_tl_resp" | tr '\r' '\n' | sed -n '/^PSSWL/ {p; q;}')
    if [[ -n "$_tl_line" ]]; then
      local _swl_raw="${_tl_line#PSSWL }"
      if [[ "$_swl_raw" =~ ^[0-9]+$ ]]; then
        _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "subwoofer_level_db" "$(awk -v v="$_swl_raw" 'BEGIN{printf "%+.0f dB", v-50}')"
      else
        _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "subwoofer_level_db" "$_swl_raw"
      fi
    fi

    _tl_resp=$(_denon_telnet_query "PSLOM ?" 2>/dev/null || printf '')
    _tl_line=$(printf '%s\n' "$_tl_resp" | tr '\r' '\n' | sed -n '/^PSLOM/ {p; q;}')
    [[ -n "$_tl_line" ]] && _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "loudness_management" "${_tl_line#PSLOM }"

    _tl_resp=$(_denon_telnet_query "CV?" 2>/dev/null || printf '')
    if [[ -n "$_tl_resp" ]]; then
      local _cv_str
      _cv_str=$(printf '%s\n' "$_tl_resp" | tr '\r' '\n' | grep -E '^CV(FL|FR|C|SW|SL|SR|SBL|SBR|SB|FHL|FHR|FWL|FWR|TFL|TFR|TRL|TRR|RHL|RHR) ' | \
        awk '{ sub(/^CV/,""); printf "%s%s", (NR>1 ? "," : ""), $0 }')
      [[ -n "$_cv_str" ]] && _denon_data_add_value "tone_audyssey" "Tone / Audyssey" "channel_levels" "$_cv_str"
    fi

    # Extended HEOS probes (new in Phase 5)
    local _heos_account_resp _heos_vol_resp _heos_mute_resp
    if _denon_is_heos_pid "${dash_heos_pid:-}"; then
      _heos_vol_resp=$(_denon_heos_helper get-volume "$dash_heos_pid" 2>/dev/null | sed -n 's/.*"level":"\([0-9]*\)".*/\1/p; s/.*level=\([0-9]*\).*/\1/p; /^[0-9][0-9]*$/p' | head -1 || printf '')
      [[ -n "$_heos_vol_resp" ]] && _denon_data_add_value "network_heos" "Network / HEOS" "heos_volume_level" "$_heos_vol_resp"
    fi
  }

  _denon_data_record_discovered_endpoint() {
    local path="$1"
    local body="$2"
    local summary
    # Collapse entire body to a single line before summarising (Bug B-3 fix: multi-line
    # bodies must not embed newlines in the tab-separated record).
    summary=$(printf '%s' "$body" | sed 's/<[^>]*>/ /g' | tr '\n\r' '  ' | \
      sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c 1-160)
    data_discovered_endpoint_records+="${path}"$'\t'"ok"$'\t'"unknown"$'\t'"${summary}"$'\n'
  }

  _denon_data_collect_web_information() {
    local html path safe body endpoints js_endpoints count=0 max_endpoints="${DENON_DATA_DISCOVERY_MAX_ENDPOINTS:-25}"
    local label value

    data_discovered_endpoint_records=""
    data_raw_web_count=0

    html=$(_denon_data_fetch_path "/general/general.html" 2>/dev/null || printf '')
    if [[ -n "$(_denon_trim "$html")" ]]; then
      _denon_data_store_raw_body "web" "/general/general.html" "$html"
      while IFS=$'\t' read -r label value; do
        [[ -n "$label$value" ]] || continue
        _denon_data_add_value "web_information" "Web UI information" "$label" "$value"
      done < <(_denon_data_parse_web_information "$html")
      endpoints=$(_denon_data_discover_web_endpoints_from_text "$html")
    else
      endpoints=""
    fi

    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      safe=$(_denon_data_safe_path "$path") || continue
      case "$safe" in
        *.js)
          body=$(_denon_data_fetch_path "$safe" 2>/dev/null || printf '')
          [[ -n "$(_denon_trim "$body")" ]] || continue
          _denon_data_store_raw_body "web" "$safe" "$body"
          _denon_data_record_discovered_endpoint "$safe" "$body"
          js_endpoints=$(_denon_data_discover_web_endpoints_from_text "$body")
          endpoints="${endpoints}"$'\n'"${js_endpoints}"
          ;;
      esac
    done <<<"$endpoints"

    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      safe=$(_denon_data_safe_path "$path") || continue
      case "$safe" in
        /general/general.html) continue ;;
      esac
      if printf '%s\n' "$data_discovered_endpoint_records" | awk -F '\t' -v p="$safe" '$1 == p { found=1 } END { exit found ? 0 : 1 }'; then
        continue
      fi
      (( count < max_endpoints )) || break
      body=$(_denon_data_fetch_path "$safe" 2>/dev/null || printf '')
      [[ -n "$(_denon_trim "$body")" ]] || continue
      _denon_data_store_raw_body "discovered" "$safe" "$body"
      _denon_data_record_discovered_endpoint "$safe" "$body"
      count=$((count + 1))
    done < <(printf '%s\n' "$endpoints" | awk '!seen[$0]++')

    while IFS=$'\t' read -r path _ _ summary; do
      [[ -n "$path" ]] || continue
      _denon_data_add_value "discovered_endpoints" "Discovered read-only endpoints" "$path" "$summary"
    done <<<"$data_discovered_endpoint_records"
  }

  _denon_data_parse_xml_field() {
    local xml="$1" tag="$2"
    printf '%s' "$xml" | sed -n "s:.*<${tag}>\([^<]*\)</${tag}>.*:\1:p" | sed -n '1p'
  }

  _denon_data_collect_upnp() {
    local deviceinfo_body aios_body url

    data_upnp_mac="" data_upnp_model="" data_upnp_pending_upgrade_version="" data_upnp_comm_api="" data_upnp_zones=""
    data_upnp_serial="" data_upnp_aios_fw="" data_upnp_udn=""

    # Deviceinfo.xml on port 8080 — AVR identity: MAC, firmware, API version
    url="http://${IP}:8080/goform/Deviceinfo.xml"
    deviceinfo_body=$(_denon_curl "$url" 2>/dev/null || printf '')
    if printf '%s' "$deviceinfo_body" | grep -q '<ModelName>'; then
      data_upnp_model=$(_denon_data_parse_xml_field "$deviceinfo_body" "ModelName")
      data_upnp_mac=$(_denon_data_parse_xml_field "$deviceinfo_body" "MacAddress")
      data_upnp_pending_upgrade_version=$(_denon_data_parse_xml_field "$deviceinfo_body" "UpgradeVersion")
      data_upnp_comm_api=$(_denon_data_parse_xml_field "$deviceinfo_body" "CommApiVers")
      data_upnp_zones=$(_denon_data_parse_xml_field "$deviceinfo_body" "DeviceZones")
      _denon_data_store_raw_body "upnp" "$url" "$deviceinfo_body"
    fi

    # aios_device.xml on port 60006 — HEOS board: serial number, AIOS firmware
    url="http://${IP}:60006/upnp/desc/aios_device/aios_device.xml"
    aios_body=$(_denon_curl "$url" 2>/dev/null || printf '')
    if printf '%s' "$aios_body" | grep -q '<serialNumber>'; then
      data_upnp_serial=$(printf '%s' "$aios_body" | sed -n 's:.*<serialNumber>\([^<]*\)</serialNumber>.*:\1:p' | sed -n '1p')
      data_upnp_aios_fw=$(printf '%s' "$aios_body" | sed -n 's:.*<modelNumber>\([^<]*\)</modelNumber>.*:\1:p' | sed -n '1p')
      data_upnp_udn=$(printf '%s' "$aios_body" | sed -n 's:.*<UDN>\([^<]*\)</UDN>.*:\1:p' | sed -n '1p')
      _denon_data_store_raw_body "upnp" "$url" "$aios_body"
    fi

    [[ -n "$data_upnp_mac$data_upnp_serial" ]]
  }

  _denon_data_collect_full() {
    _denon_data_collect_summary || return 1
    _denon_data_collect_web_information || true
  }

  _denon_data_collect_summary() {
    _denon_data_collect_available || return 1
    if _denon_data_collect_upnp; then
      [[ -n "$data_upnp_model"    ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "upnp_model"       "$data_upnp_model"
      [[ -n "$data_upnp_mac"      ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "upnp_mac"         "$data_upnp_mac"
      [[ -n "$data_upnp_pending_upgrade_version" ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "pending_upgrade_version" "$data_upnp_pending_upgrade_version"
      [[ -n "$data_upnp_comm_api" ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "comm_api_vers"    "$data_upnp_comm_api"
      [[ -n "$data_upnp_zones"    ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "device_zones"     "$data_upnp_zones"
      [[ -n "$data_upnp_serial"   ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "serial_number"    "$data_upnp_serial"
      [[ -n "$data_upnp_aios_fw"  ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "aios_firmware"    "$data_upnp_aios_fw"
      [[ -n "$data_upnp_udn"      ]] && _denon_data_add_value "upnp" "UPnP / Device Identity" "udn"              "$data_upnp_udn"
    fi
  }

  _denon_data_print_discovery_readable() {
    local path status content_type summary

    printf 'Discovered read-only endpoints\n'
    if [[ -z "$(_denon_trim "$data_discovered_endpoint_records")" ]]; then
      printf '  none\n'
      return 0
    fi
    while IFS=$'\t' read -r path status content_type summary; do
      [[ -n "$path" ]] || continue
      printf '  %-40s %s\n' "$path" "$summary"
    done <<<"$data_discovered_endpoint_records"
  }

  _denon_data_print_discovery_json() {
    printf '{"discovered_endpoints":'
    _denon_data_print_discovered_json
    printf '}\n'
  }

  _denon_data_capabilities_usage() {
    cat <<'EOF'
Usage:
  denon data capabilities [--json] [--source file] [--probe-safe]

Options:
  --json          Print structured JSON.
  --source file   Parse a Deviceinfo/AppCommand capability XML file instead of the bundled reference.
  --probe-safe    Fetch live Deviceinfo.xml and probe only exact allowlisted read-only AppCommand Get* verbs.
  --help          Show this help.

Default behavior is dry-run inventory only. Unknown verbs are listed but not executed.
EOF
  }

  _denon_data_capabilities_default_source() {
    local script_path script_dir
    script_path=$(_denon_script_path) || return 1
    script_dir=$(cd "$(dirname "$script_path")" 2>/dev/null && pwd)
    [[ -n "$script_dir" ]] || return 1
    printf '%s/references/deviceinfo_capabilities.xml' "$script_dir"
  }

  _denon_data_capability_records_from_xml() {
    local source_endpoint="$1"
    local xml="$2"

    printf '%s' "$xml" |
      _denon_xml_split_tags |
      awk -v source="$source_endpoint" '
        function tag_name(line, out) {
          out=line
          sub(/^<\//, "", out)
          sub(/^</, "", out)
          sub(/[ >\/].*$/, "", out)
          gsub(/[[:space:]]+$/, "", out)
          return out
        }
        function path(  i, out) {
          out=""
          for (i=1; i<=depth; i++) out=(out == "" ? stack[i] : out "." stack[i])
          return out
        }
        function trim(value) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          return value
        }
        function emit(xml_path, verb, kind) {
          verb=trim(verb)
          if (verb == "") return
          printf "%s\t%s\t%s\t%s\n", source, xml_path, verb, kind
        }
        {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          if ($0 ~ /^<\?/) next
          if ($0 ~ /^<!--/) next
          if ($0 ~ /^<[^\/][^>]*>[^<]*<\/[^>]+>$/) {
            name=tag_name($0)
            value=$0
            sub(/^<[^>]*>/, "", value)
            sub(/<\/[^>]+>$/, "", value)
            value=trim(value)
            full_path=path() (path() == "" ? "" : ".") name
            if (name == "FuncName") {
              emit(full_path, value, "function")
            } else if (path() ~ /(^|\.)(Functions|Commands)$/ && value == "1" && name ~ /^[A-Za-z][A-Za-z0-9_ -]*$/) {
              emit(full_path, name, "appcommand")
            }
            next
          }
          if ($0 ~ /^<[^\/!][^>]*>$/ && $0 !~ /\/>$/) {
            stack[++depth]=tag_name($0)
            next
          }
          if ($0 ~ /^<\//) {
            if (depth > 0) depth--
            next
          }
        }
      '
  }

  _denon_data_capability_skip_reason() {
    local verb="$1"
    local lower
    lower=$(_denon_lower "$verb")

    case "$lower" in
      set*|put*|update*|upgrade*|factory*|reset*|reboot*|delete*|pair*|register*|login*|account*|write*)
        printf 'mutating or account/action verb prefix'
        return 0
        ;;
    esac
    case "$lower" in
      *firmware*|*update*|*upgrade*|*factory*|*reboot*|*delete*|*pair*|*register*|*login*|*account*|*write*)
        printf 'blocked keyword in advertised verb'
        return 0
        ;;
    esac
    return 1
  }

  _denon_data_capability_is_known_safe() {
    case "$1" in
      GetAllZonePowerStatus|GetZoneName|GetVolume|GetMute|GetSource|GetSurroundMode|GetSoundMode|GetAudyssey|GetToneControl|GetVideoSelect|GetECO|GetECOMeter|GetAutoStandby|GetNetworkInfo|GetDeviceInfo|GetStatus|GetDialogLevel|GetSubwooferLevel|GetChLevel|GetAllZoneStereo|GetDimmer|GetInputSignal|GetActiveSpeaker|GetVideoInfo|GetAudioInfo|GetAudyssyInfo)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_data_capability_has_parser() {
    case "$1" in
      GetZoneName|GetVolume|GetMute|GetSource|GetSurroundMode|GetSoundMode|GetAudyssey|GetToneControl|GetNetworkInfo|GetStatus)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_data_capability_classify() {
    local verb="$1"
    local reason

    reason=$(_denon_data_capability_skip_reason "$verb") && {
      printf 'skipped\t%s' "$reason"
      return 0
    }
    if _denon_data_capability_is_known_safe "$verb"; then
      printf 'known-safe\tnone'
    else
      printf 'unknown\tnone'
    fi
  }

  _denon_data_capability_probe_result() {
    local verb="$1" line status summary
    line=$(printf '%s\n' "$data_capability_probe_records" | awk -F '\t' -v v="$verb" '$1 == v { print; found=1; exit } END { exit found ? 0 : 1 }') || return 1
    status=${line#*$'\t'}
    summary=${status#*$'\t'}
    status=${status%%$'\t'*}
    printf '%s\t%s' "$status" "$summary"
  }

  _denon_data_appcommand_response_status_summary() {
    local response="$1"
    local summary status compact

    summary=$(printf '%s' "$response" | sed 's/<[^>]*>/ /g' | tr '\n\r' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c 1-160)
    [[ -n "$summary" ]] || summary="none"
    compact=$(printf '%s' "$response" | tr '\n\r' '  ')
    if [[ -z "$(_denon_trim "$response")" ]]; then
      status="empty"
    elif ! printf '%s' "$compact" | grep -Eq '<rx([[:space:]>])'; then
      status="malformed"
    elif ! printf '%s' "$compact" | grep -q '</rx>'; then
      status="malformed"
    elif [[ "$summary" == "none" ]]; then
      status="empty"
    else
      status="ok"
    fi
    printf '%s\t%s' "$status" "$summary"
  }

  _denon_data_probe_appcommand_safe() {
    local verb="$1"
    local request response rc

    _denon_data_capability_is_known_safe "$verb" || {
      printf 'not_probed\tnot in exact live-probe allowlist'
      return 0
    }
    # The firmware needs a newline after the XML declaration or it silently
    # returns an empty <rx>.
    request="<?xml version=\"1.0\" encoding=\"utf-8\"?>"$'\n'"<tx><cmd id=\"1\">${verb}</cmd></tx>"
    response=$(_denon_curl -X POST -H 'Content-Type: text/xml' --data-binary "$request" "$BASE/goform/AppCommand.xml" 2>/dev/null)
    rc=$?
    if (( rc != 0 )); then
      printf 'curl_error\tcurl exited %s' "$rc"
      return 0
    fi
    _denon_data_appcommand_response_status_summary "$response"
  }

  _denon_data_capability_prepare_records() {
    local xml="$1"
    local source_endpoint="$2"
    local probe_safe="$3"
    local source xml_path verb kind safety reason has_parser probe_status probe_summary probe_line

    data_capability_records=""
    data_capability_probe_records=""

    while IFS=$'\t' read -r source xml_path verb kind; do
      [[ -n "$source$xml_path$verb$kind" ]] || continue
      IFS=$'\t' read -r safety reason <<<"$(_denon_data_capability_classify "$verb")"
      has_parser="no"
      _denon_data_capability_has_parser "$verb" && has_parser="yes"
      probe_status="dry-run"
      probe_summary="none"

      if [[ "$safety" == "skipped" ]]; then
        probe_status="skipped"
        probe_summary="$reason"
      elif [[ "$safety" == "unknown" ]]; then
        probe_status="not_probed"
        probe_summary="not in exact live-probe allowlist"
      elif [[ "$probe_safe" == "1" && "$kind" == "appcommand" ]]; then
        probe_line=$(_denon_data_capability_probe_result "$verb" 2>/dev/null || true)
        if [[ -z "$probe_line" ]]; then
          probe_line=$(_denon_data_probe_appcommand_safe "$verb")
          data_capability_probe_records+="${verb}"$'\t'"${probe_line}"$'\n'
          sleep "${DENON_DATA_CAPABILITY_PROBE_DELAY_SECONDS:-0.10}" 2>/dev/null || true
        fi
        probe_status=${probe_line%%$'\t'*}
        probe_summary=${probe_line#*$'\t'}
      elif [[ "$safety" == "known-safe" ]]; then
        probe_summary="eligible for --probe-safe"
      fi

      [[ -n "$reason" ]] || reason="none"
      [[ -n "$probe_summary" ]] || probe_summary="none"
      data_capability_records+="${source}"$'\t'"${xml_path}"$'\t'"${verb}"$'\t'"${kind}"$'\t'"${safety}"$'\t'"${reason}"$'\t'"${has_parser}"$'\t'"${probe_status}"$'\t'"${probe_summary}"$'\n'
    done < <(_denon_data_capability_records_from_xml "$source_endpoint" "$xml")
  }

  _denon_data_print_capabilities_readable() {
    local source xml_path verb kind safety reason has_parser probe_status probe_summary

    printf 'Advertised Deviceinfo/AppCommand capabilities\n'
    printf '  %-34s %-28s %-11s %-6s %s\n' "source endpoint" "verb" "safety" "parser" "status / reason"
    while IFS=$'\t' read -r source xml_path verb kind safety reason has_parser probe_status probe_summary; do
      [[ -n "$verb" ]] || continue
      printf '  %-34s %-28s %-11s %-6s %s' "$source" "$verb" "$safety" "$has_parser" "$probe_status"
      if [[ "$safety" == "skipped" && "$reason" != "none" ]]; then
        printf ': %s' "$reason"
      elif [[ "$probe_summary" != "none" ]]; then
        printf ': %s' "$probe_summary"
      fi
      printf ' [%s]\n' "$xml_path"
    done <<<"$data_capability_records"
  }

  _denon_data_print_capabilities_json() {
    local source xml_path verb kind safety reason has_parser probe_status probe_summary first=1
    local json_reason json_summary

    printf '{"capabilities":['
    while IFS=$'\t' read -r source xml_path verb kind safety reason has_parser probe_status probe_summary; do
      [[ -n "$verb" ]] || continue
      (( first )) || printf ','
      json_reason="$reason"
      json_summary="$probe_summary"
      [[ "$json_reason" == "none" ]] && json_reason=""
      [[ "$json_summary" == "none" ]] && json_summary=""
      printf '{"source_endpoint":"%s","xml_path":"%s","verb":"%s","kind":"%s","safety":"%s","skip_reason":"%s","has_parser":%s,"probe_status":"%s","probe_summary":"%s"}' \
        "$(printf '%s' "$source" | _denon_json_escape)" \
        "$(printf '%s' "$xml_path" | _denon_json_escape)" \
        "$(printf '%s' "$verb" | _denon_json_escape)" \
        "$(printf '%s' "$kind" | _denon_json_escape)" \
        "$(printf '%s' "$safety" | _denon_json_escape)" \
        "$(printf '%s' "$json_reason" | _denon_json_escape)" \
        "$([[ "$has_parser" == "yes" ]] && printf true || printf false)" \
        "$(printf '%s' "$probe_status" | _denon_json_escape)" \
        "$(printf '%s' "$json_summary" | _denon_json_escape)"
      first=0
    done <<<"$data_capability_records"
    printf ']}\n'
  }

  _denon_data_capabilities_cmd() {
    local json=0 probe_safe=0 source_file="" arg source_endpoint xml

    while [[ $# -gt 0 ]]; do
      arg="$1"
      case "$arg" in
        --json) json=1; shift ;;
        --probe-safe) probe_safe=1; shift ;;
        --source)
          source_file="${2:-}"
          if [[ -z "$source_file" ]]; then
            echo "Error: --source requires a file path" >&2
            return 1
          fi
          shift 2
          ;;
        --help|-h|help)
          _denon_data_capabilities_usage
          return 0
          ;;
        *)
          _denon_data_capabilities_usage >&2
          return 1
          ;;
      esac
    done

    if [[ -n "$source_file" ]]; then
      [[ -r "$source_file" ]] || { echo "Error: cannot read capability source: $source_file" >&2; return 1; }
      source_endpoint="$source_file"
      xml=$(<"$source_file")
    elif [[ "$probe_safe" == "1" ]]; then
      source_endpoint="http://${IP}:8080/goform/Deviceinfo.xml"
      xml=$(_denon_curl "$source_endpoint" 2>/dev/null || printf '')
      [[ -n "$(_denon_trim "$xml")" ]] || { echo "Error: live Deviceinfo.xml returned no data" >&2; return 1; }
    else
      source_file=$(_denon_data_capabilities_default_source) || {
        echo "Error: could not locate bundled capability reference" >&2
        return 1
      }
      [[ -r "$source_file" ]] || { echo "Error: cannot read bundled capability reference: $source_file" >&2; return 1; }
      source_endpoint="$source_file"
      xml=$(<"$source_file")
    fi

    _denon_data_capability_prepare_records "$xml" "$source_endpoint" "$probe_safe"
    if [[ "$json" == "1" ]]; then
      _denon_data_print_capabilities_json
    else
      _denon_data_print_capabilities_readable
    fi
  }

  _denon_data_requires_receiver() {
    local sub
    local mode
    local arg
    sub=$(_denon_lower "${1:-}")
    mode=$(_denon_lower "${2:-}")

    case "$sub:$mode" in
      fields:--available|dump:--readable|dump:--all|dump:--json|dump:--raw|discover:*|summary:*) return 0 ;;
    esac
    if [[ "$sub" == "capabilities" ]]; then
      for arg in "$@"; do
        [[ "$(_denon_lower "$arg")" == "--probe-safe" ]] && return 0
      done
    fi
    return 1
  }

  _denon_data_target_ip() {
    local cache
    local candidate=""
    cache=$(_denon_ip_cache_path) || return 1

    if [[ -n "${DENON_IP:-}" ]]; then
      candidate="$DENON_IP"
    elif [[ -n "${DENON_DEFAULT_IP:-}" ]]; then
      candidate="$DENON_DEFAULT_IP"
    elif [[ -f "$cache" ]]; then
      candidate=$(<"$cache")
    fi

    if [[ -z "$candidate" ]] || ! _denon_is_ipv4 "$candidate"; then
      echo "Error: data live modes require DENON_IP, DENON_DEFAULT_IP, or a cached receiver IP; no network scan is performed" >&2
      return 1
    fi
    printf '%s' "$candidate"
  }

  _denon_data_cmd() {
    local sub
    local mode
    sub=$(_denon_lower "${1:-}")
    mode=$(_denon_lower "${2:-}")

    case "$sub" in
      fields)
        case "$mode" in
          --all)
            _denon_data_print_field_catalog
            ;;
          --available)
            _denon_data_collect_full || return 1
            _denon_data_print_readable
            ;;
          *)
            _denon_data_usage >&2
            return 1
            ;;
        esac
        ;;
      dump)
        case "$mode" in
          --readable|--all)
            _denon_data_collect_full || return 1
            _denon_data_print_readable
            ;;
          --json)
            _denon_data_collect_full || return 1
            _denon_data_print_json
            ;;
          --raw)
            local full=0
            case "$(_denon_lower "${3:-}")" in
              "") ;;
              --full) full=1 ;;
              *) _denon_data_usage >&2; return 1 ;;
            esac
            _denon_data_collect_full || return 1
            _denon_data_print_raw "$full"
            ;;
          *)
            _denon_data_usage >&2
            return 1
            ;;
        esac
        ;;
      discover)
        case "$mode" in
          ""|--json)
            _denon_data_collect_full || return 1
            if [[ "$mode" == "--json" ]]; then
              _denon_data_print_discovery_json
            else
              _denon_data_print_discovery_readable
            fi
            ;;
          *)
            _denon_data_usage >&2
            return 1
            ;;
        esac
        ;;
      capabilities|discover-capabilities|verbs)
        _denon_data_capabilities_cmd "${@:2}"
        ;;
      summary)
        case "$mode" in
          ""|--json)
            _denon_data_collect_summary || return 1
            if [[ "$mode" == "--json" ]]; then
              _denon_data_print_summary_json
            else
              _denon_data_print_summary_readable
            fi
            ;;
          *)
            _denon_data_usage >&2
            return 1
            ;;
        esac
        ;;
      *)
        _denon_data_usage >&2
        return 1
        ;;
    esac
  }

  _denon_ms_now() {
    local value
    value=$(date +%s%3N 2>/dev/null || printf '')
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
      value=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '')
      if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    fi
    printf '0\n'
  }

  _denon_probe_candidate() {
    local label="$1" candidate="$2" xml model t0 t1 ms
    [[ -n "$candidate" ]] || return 1
    printf '%-18s %s ... ' "$label" "$candidate"
    t0=$(_denon_ms_now)
    xml=$(_denon_curl -G "https://$candidate:10443/ajax/globals/get_config" \
      --data-urlencode "type=3" 2>/dev/null)
    t1=$(_denon_ms_now)
    ms=$(( t1 - t0 ))
    if printf '%s' "$xml" | grep -q "Denon"; then
      model=$(printf '%s' "$xml" | sed -n 's:.*<FriendlyName>\([^<]*\)</FriendlyName>.*:\1:p')
      echo "OK (${model:-Denon receiver}) [${ms}ms]"
      return 0
    fi
    echo "no Denon response [${ms}ms]"
    return 1
  }

  _denon_doctor() {
    local cache
    local default_ip="${DENON_DEFAULT_IP:-}"
    local cached_ip=""
    local route_target=""
    local exit_status=0
    cache=$(_denon_ip_cache_path) || return 1

    echo "Denon doctor"
    echo "User: $(id -un 2>/dev/null || echo unknown)"
    echo "HOME: $HOME"
    echo

    echo "Dependencies:"
    local cmd cmd_path
    for cmd in curl grep sed awk tr mktemp; do
      cmd_path=$(command -v "$cmd" 2>/dev/null)
      if [[ -n "$cmd_path" ]]; then
        echo "  OK      $cmd ($cmd_path)"
      else
        echo "  MISSING $cmd"
        exit_status=1
      fi
    done
    for cmd in ip arp nc zsh; do
      cmd_path=$(command -v "$cmd" 2>/dev/null)
      if [[ -n "$cmd_path" ]]; then
        echo "  OK      $cmd ($cmd_path)"
      else
        echo "  OPTIONAL-MISSING $cmd"
      fi
    done
    echo

    echo "Receiver hints:"
    echo "  DENON_IP:              ${DENON_IP:-unset}"
    echo "  DENON_DEFAULT_IP:      ${DENON_DEFAULT_IP:-unset}"
    echo "  DENON_SCAN_LAN:        ${DENON_SCAN_LAN:-0}"
    echo "  DENON_MAX_VOLUME_DB:   ${DENON_MAX_VOLUME_DB:--10}"
    echo "  DENON_CURL_MAX_TIME:   ${DENON_CURL_MAX_TIME:-4}"
    echo "  DENON_CURL_CONNECT_TIMEOUT: ${DENON_CURL_CONNECT_TIMEOUT:-2}"
    echo "  TLS verification:      $(_denon_curl_tls_mode)"
    if [[ -n "${DENON_CURL_CACERT:-}" ]]; then
      echo "  TLS CA certificate:    $DENON_CURL_CACERT"
    fi
    if [[ -n "${DENON_CURL_PINNEDPUBKEY:-}" ]]; then
      echo "  TLS pinned public key: configured"
    else
      echo "  TLS pinned public key: unset"
    fi
    echo "  DENON_SSDP_TIMEOUT:    ${DENON_SSDP_TIMEOUT:-2}"
    echo "  DENON_SSDP_MX:         ${DENON_SSDP_MX:-1}"
    if [[ -f "$cache" ]]; then
      cached_ip=$(<"$cache")
      if _denon_is_ipv4 "$cached_ip"; then
        echo "  Cache:                 $cache -> $cached_ip"
      else
        echo "  Cache:                 $cache -> invalid (ignored)"
        cached_ip=""
      fi
    else
      echo "  Cache:                 $cache -> missing"
    fi
    echo

    if _denon_curl_insecure_mode_active; then
      echo "Warning: HTTPS certificate verification is disabled for AVR compatibility; use DENON_CURL_INSECURE=0, DENON_CURL_CACERT, or DENON_CURL_PINNEDPUBKEY to harden this on trusted networks."
      echo
    fi

    if command -v ip >/dev/null 2>&1; then
      echo "Network route:"
      route_target="${DENON_IP:-${cached_ip:-$default_ip}}"
      if [[ -n "$route_target" ]]; then
        ip -4 route get "$route_target" 2>/dev/null | sed 's/^/  /' || {
          echo "  Could not route to $route_target"
          exit_status=1
        }
      else
        ip -4 route show 2>/dev/null | sed -n '1,5s/^/  /p'
      fi
      echo
    fi

    echo "Known local hosts:"
    local known_hosts t0 t1 ms
    t0=$(_denon_ms_now)
    known_hosts=$(_denon_known_hosts | tr '\n' ' ')
    t1=$(_denon_ms_now)
    ms=$(( t1 - t0 ))
    echo "  ${known_hosts:-none} [${ms}ms]"
    echo

    echo "Receiver probes:"
    local found=0
    if [[ -n "${DENON_IP:-}" ]]; then
      _denon_probe_candidate "DENON_IP" "$DENON_IP" && found=1
    fi
    if [[ -n "$cached_ip" && "$cached_ip" != "${DENON_IP:-}" ]]; then
      _denon_probe_candidate "cache" "$cached_ip" && found=1
    fi
    if [[ -n "$default_ip" && "$default_ip" != "${DENON_IP:-}" && "$default_ip" != "$cached_ip" ]]; then
      _denon_probe_candidate "default" "$default_ip" && found=1
    fi

    local candidate
    for candidate in $(_denon_known_hosts); do
      if [[ "$candidate" != "${DENON_IP:-}" && "$candidate" != "$cached_ip" && "$candidate" != "$default_ip" ]]; then
        _denon_probe_candidate "neighbor" "$candidate" && found=1
      fi
    done

    if (( found == 0 )); then
      echo "  No reachable Denon receiver found on the checked addresses."
      return 1
    fi

    return "$exit_status"
  }

  _denon_dashboard_json_section() {
    local json="$1"
    local section="$2"

    case "$section" in
      mainZone)
        printf '%s' "$json" | sed -n 's/^.*"mainZone":{\([^}]*\)},"zone2":.*$/\1/p'
        ;;
      zone2)
        printf '%s' "$json" | sed -n 's/^.*"zone2":{\([^}]*\)}}.*$/\1/p'
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_dashboard_json_value() {
    local json="$1"
    local path="$2"
    local section key chunk

    if command -v jq >/dev/null 2>&1; then
      jq -r ".$path | if . == null then empty else . end" 2>/dev/null <<<"$json" | sed 's/^null$//'
      return 0
    fi

    case "$path" in
      receiver|ip)
        key="$path"
        chunk="$json"
        ;;
      mainZone.*)
        section="mainZone"
        key="${path#mainZone.}"
        chunk=$(_denon_dashboard_json_section "$json" "$section")
        ;;
      zone2.*)
        section="zone2"
        key="${path#zone2.}"
        chunk=$(_denon_dashboard_json_section "$json" "$section")
        ;;
      *)
        return 1
        ;;
    esac

    printf '%s' "$chunk" |
      awk -v key="$key" '
        {
          quoted="\"" key "\":\""
          raw="\"" key "\":"
          if (index($0, quoted)) {
            value=$0
            sub("^.*" quoted, "", value)
            sub("\".*$", "", value)
            print value
            exit
          }
          if (index($0, raw)) {
            value=$0
            sub("^.*" raw, "", value)
            sub(",.*$", "", value)
            gsub(/[{}]/, "", value)
            print value
            exit
          }
        }
      '
  }

  _denon_dashboard_parse_info_text() {
    local text="$1"
    local line label value

    while IFS= read -r line; do
      label=${line%%:*}
      value=${line#*:}
      [[ "$line" == *:* ]] || continue
      value=$(_denon_trim "$value")
      case "$label" in
        Receiver) [[ -n "$value" ]] && dash_receiver="$value" ;;
        IP) [[ -n "$value" ]] && dash_ip="$value" ;;
        "Main Zone Power") dash_main_power="$value" ;;
        "Main Zone Source")
          dash_main_source=$(_denon_clean_source_name "$value")
          dash_main_source_index=$(printf '%s' "$value" | sed -n 's/^.*(\([0-9][0-9]*\))[[:space:]]*$/\1/p')
          ;;
        "Main Zone Volume") dash_main_volume=${value% dB} ;;
        "Main Zone Muted") dash_main_muted=$(_denon_normalize_mute "$value") ;;
        "Zone 2 Power") dash_zone2_power="$value" ;;
        "Zone 2 Source")
          dash_zone2_source=$(_denon_clean_source_name "$value")
          dash_zone2_source_index=$(printf '%s' "$value" | sed -n 's/^.*(\([0-9][0-9]*\))[[:space:]]*$/\1/p')
          ;;
        "Zone 2 Volume") dash_zone2_volume_db="${value% dB}" ;;
        "Zone 2 Volume Raw") dash_zone2_volume="$value" ;;
        "Zone 2 Muted") dash_zone2_muted=$(_denon_normalize_mute "$value") ;;
      esac
    done <<<"$text"
  }

  _denon_dashboard_parse_status() {
    local text="$1"
    local line rest value

    line=$(printf '%s\n' "$text" | sed -n '/^Power: /{p; q;}')
    [[ -n "$line" ]] || return 1

    value=${line#Power: }
    dash_main_power=$(_denon_trim "${value%% | Source:*}")
    rest=${line#* | Source: }
    dash_main_source=$(_denon_clean_source_name "${rest%% | Volume:*}")
    rest=${rest#* | Volume: }
    dash_main_volume=$(_denon_trim "${rest%% dB*}")
    if [[ "$line" == *"[MUTED]"* ]]; then
      dash_main_muted="yes"
    elif [[ -z "$dash_main_muted" || "$dash_main_muted" == "Unknown" ]]; then
      dash_main_muted="Unknown"
    fi
  }

  _denon_dashboard_parse_zone2_status() {
    local text="$1"
    local line rest value

    line=$(printf '%s\n' "$text" | sed -n '/^Zone 2 | /{p; q;}')
    [[ -n "$line" ]] || return 1

    rest=${line#Zone 2 | Power: }
    dash_zone2_power=$(_denon_trim "${rest%% | Source:*}")
    rest=${rest#* | Source: }
    dash_zone2_source=$(_denon_clean_source_name "${rest%% | Volume:*}")
    rest=${rest#* | Volume: }
    dash_zone2_volume=$(_denon_trim "${rest%% | Muted:*}")
    value=${rest#* | Muted:}
    dash_zone2_muted=$(_denon_normalize_mute "$value")
  }

  _denon_dashboard_parse_sources() {
    local zone="$1"
    local text="$2"
    local line marker idx name

    while IFS= read -r line; do
      marker=${line:0:1}
      [[ "$marker" == "*" ]] || continue
      line=$(_denon_trim "${line:1}")
      idx=${line%%[[:space:]]*}
      name=$(_denon_clean_source_name "${line#"$idx"}")
      if [[ "$zone" == "1" ]]; then
        dash_main_source_index="$idx"
        [[ -n "$dash_main_source" && "$dash_main_source" != "Unknown" ]] || dash_main_source="$name"
      else
        dash_zone2_source_index="$idx"
        [[ -n "$dash_zone2_source" && "$dash_zone2_source" != "Unknown" ]] || dash_zone2_source="$name"
      fi
    done <<<"$text"
  }

  _denon_dashboard_sources_body() {
    local text="$1"
    local line marker rest

    while IFS= read -r line; do
      [[ "$line" == *sources:* ]] && continue
      line=$(_denon_trim "$line")
      [[ -n "$line" ]] || continue
      marker=${line:0:1}
      if [[ "$marker" == "*" ]]; then
        rest=$(_denon_trim "${line:1}")
        printf '* %s\n' "$rest"
      else
        printf '  %s\n' "$line"
      fi
    done <<<"$text"
  }

  _denon_dashboard_xml_value() {
    local xml="$1"
    local tag="$2"

    printf '%s' "$xml" | sed -n "s:.*<${tag}>\\([^<]*\\)</${tag}>.*:\\1:p" | sed -n '1p'
  }

  _denon_dashboard_parse_zone_names() {
    local xml="$1"
    local value

    value=$(_denon_dashboard_xml_value "$xml" "MainZone")
    [[ -n "$value" ]] && dash_main_zone_name="$value"
    value=$(_denon_dashboard_xml_value "$xml" "Zone2")
    [[ -n "$value" ]] && dash_zone2_name="$value"
  }

  _denon_dashboard_parse_volume_details() {
    local xml="$1"
    local main_max zone2_raw

    main_max=$(printf '%s' "$xml" | sed -n 's:.*<MainZone>.*<Max>\([0-9][0-9]*\)</Max>.*</MainZone>.*:\1:p' | sed -n '1p')
    zone2_raw=$(printf '%s' "$xml" | sed -n 's:.*<Zone2>.*<Volume>\([0-9][0-9]*\)</Volume>.*</Zone2>.*:\1:p' | sed -n '1p')

    if [[ -n "$main_max" ]]; then
      dash_main_max_volume_db=$(_denon_raw_to_db "$main_max")
    fi
    if [[ -n "$zone2_raw" ]]; then
      dash_zone2_volume_raw="$zone2_raw"
      dash_zone2_volume_db=$(_denon_raw_to_db "$zone2_raw")
    fi
  }

  _denon_dashboard_telnet_status() {
    _denon_telnet_query "MS?" 2>/dev/null
  }

  _denon_dashboard_parse_telnet_status() {
    local text="$1"
    local line value

    text=${text//$'\r'/$'\n'}
    while IFS= read -r line; do
      case "$line" in
        SYSMI*)
          value=$(_denon_trim "${line#SYSMI}")
          [[ -n "$value" ]] && dash_sound_mode="$value"
          ;;
        MS*)
          if [[ "$dash_sound_mode" == "Unknown" ]]; then
            value=$(_denon_trim "${line#MS}")
            [[ -n "$value" ]] && dash_sound_mode="$value"
          fi
          ;;
      esac
    done <<<"$text"
  }

  _denon_dashboard_json_scalar() {
    local json="$1"
    local key="$2"
    local value

    value=$(printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | sed -n '1p' | tr -d '" '
  }

  _denon_dashboard_clean_field() {
    local value
    value=$(_denon_trim "$1")
    case "$(_denon_lower "$value")" in
      ""|unknown|null|none|n/a|na|"-") return 0 ;;
      *) printf '%s' "$value" ;;
    esac
  }

  _denon_dashboard_is_heos_source() {
    case "$(_denon_lower "$dash_main_source")" in
      *heos*) return 0 ;;
      *) return 1 ;;
    esac
  }

  _denon_dashboard_transport_name() {
    case "$(_denon_lower "$1")" in
      play|playing) echo "Playing" ;;
      pause|paused) echo "Paused" ;;
      stop|stopped) echo "Stopped" ;;
      "") return 1 ;;
      *) printf '%s' "$1" ;;
    esac
  }

  _denon_dashboard_event_value_known() {
    [[ -n "$(_denon_dashboard_clean_field "$1")" ]]
  }

  _denon_dashboard_event_changed_known() {
    local old="$1"
    local new="$2"
    [[ "$old" != "$new" ]] || return 1
    _denon_dashboard_event_value_known "$old" || return 1
    _denon_dashboard_event_value_known "$new" || return 1
    return 0
  }

  _denon_dashboard_event_volume_display() {
    local value

    value=$(_denon_dashboard_clean_field "$1")
    [[ -n "$value" ]] || return 0
    case "$value" in
      *" dB") printf '%s\n' "$value" ;;
      *) printf '%s dB\n' "$value" ;;
    esac
  }

  _denon_dashboard_event_mute_display() {
    local value

    value=$(_denon_mute_display_name "$1")
    [[ "$value" != "Unknown" ]] || return 0
    printf '%s\n' "$value"
  }

  _denon_dashboard_now_playing_event_text() {
    local title artist station service

    title=$(_denon_dashboard_clean_field "$dash_now_title")
    artist=$(_denon_dashboard_clean_field "$dash_now_artist")
    station=$(_denon_dashboard_clean_field "$dash_now_station")
    service=$(_denon_dashboard_clean_field "$dash_now_service")

    if [[ -n "$title" ]]; then
      if [[ -n "$artist" ]]; then
        printf 'Now Playing: %s — %s\n' "$title" "$artist"
      else
        printf 'Now Playing: %s\n' "$title"
      fi
    elif [[ -n "$station" ]]; then
      printf 'Now Playing: %s\n' "$station"
    elif [[ -n "$service" ]]; then
      printf 'Now Playing: %s\n' "$service"
    fi
  }

  _denon_dashboard_heos_service_name() {
    local sid="$1"
    local mid="$2"

    case "$mid" in
      spotify:*) echo "Spotify"; return 0 ;;
      *) ;;
    esac

    case "$sid" in
      1) echo "Pandora" ;;
      2) echo "Rhapsody" ;;
      3) echo "TuneIn" ;;
      4) echo "Spotify" ;;
      5) echo "Deezer" ;;
      7) echo "iHeartRadio" ;;
      8) echo "SiriusXM" ;;
      9) echo "SoundCloud" ;;
      10) echo "Tidal" ;;
      13) echo "Amazon" ;;
      30) echo "Qobuz" ;;
      1024) echo "Local Music" ;;
      1025) echo "Playlists" ;;
      1026) echo "History" ;;
      1027) echo "AUX Input" ;;
      1028) echo "Favorites" ;;
      "") return 1 ;;
      *) echo "sid $sid" ;;
    esac
  }

  _denon_dashboard_heos_command() {
    local command="$1"
    command -v nc >/dev/null 2>&1 || return 1

    {
      printf '%s\r\n' "$command"
      sleep 0.1
    } | nc -w 1 "$IP" 1255 2>/dev/null
  }

  _denon_dashboard_heos_status() {
    local players pid helper_status

    if [[ "${1:-}" != "players-only" ]]; then
      helper_status=$(_denon_heos_helper status-json 2>/dev/null || printf '')
      if [[ -n "$helper_status" ]]; then
        printf '%s\n' "$helper_status"
        return 0
      fi
    fi

    players=$(_denon_dashboard_heos_command 'heos://player/get_players')
    printf '%s\n' "$players"
    [[ "${1:-}" == "players-only" ]] && return 0
    pid=$(_denon_dashboard_json_scalar "$players" "pid")
    _denon_is_heos_pid "$pid" || return 0

    _denon_dashboard_heos_command "heos://player/get_now_playing_media?pid=$pid"
    _denon_dashboard_heos_command "heos://player/get_play_state?pid=$pid"
  }

  _denon_dashboard_parse_heos_status() {
    local text="$1"
    local line value sid mid service

    while IFS= read -r line; do
      case "$line" in
        *'"pid"'*'"state"'*)
          value=$(_denon_dashboard_json_scalar "$line" "pid"); _denon_is_heos_pid "$value" && dash_heos_pid="$value"
          value=$(_denon_dashboard_json_scalar "$line" "player_model"); [[ -n "$value" ]] && dash_heos_model="$value"
          value=$(_denon_dashboard_json_scalar "$line" "player_version"); [[ -n "$value" ]] && dash_heos_version="$value"
          value=$(_denon_dashboard_json_scalar "$line" "network"); [[ -n "$value" ]] && dash_heos_network="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "song")")
          [[ -n "$value" ]] && dash_now_title="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "artist")")
          [[ -n "$value" ]] && dash_now_artist="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "album")")
          [[ -n "$value" ]] && dash_now_album="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "station")")
          [[ -n "$value" && "$value" != "$dash_now_title" ]] && dash_now_station="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "type")")
          [[ -n "$value" ]] && dash_now_type="$value"
          sid=$(_denon_dashboard_json_scalar "$line" "sid")
          mid=$(_denon_dashboard_json_scalar "$line" "mid")
          service=$(_denon_dashboard_heos_service_name "$sid" "$mid")
          [[ -n "$service" ]] && dash_now_service="$service"
          value=$(_denon_dashboard_transport_name "$(_denon_dashboard_json_scalar "$line" "state")")
          [[ -n "$value" ]] && dash_transport_state="$value"
          if [[ -n "$dash_now_title$dash_now_artist$dash_now_album$dash_now_station" ]]; then
            dash_now_available=1
            dash_now_message="${dash_now_title:-${dash_now_station:-HEOS media}}"
            [[ -z "$dash_now_artist" ]] || dash_now_message="$dash_now_message - $dash_now_artist"
          fi
          ;;
        *'"command": "player/get_players"'*)
          value=$(_denon_dashboard_json_scalar "$line" "pid"); _denon_is_heos_pid "$value" && dash_heos_pid="$value"
          value=$(_denon_dashboard_json_scalar "$line" "model"); [[ -n "$value" ]] && dash_heos_model="$value"
          value=$(_denon_dashboard_json_scalar "$line" "version"); [[ -n "$value" ]] && dash_heos_version="$value"
          value=$(_denon_dashboard_json_scalar "$line" "network"); [[ -n "$value" ]] && dash_heos_network="$value"
          ;;
        *'"command": "player/get_now_playing_media"'*)
          [[ "$line" == *'"result": "success"'* ]] || continue
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "song")")
          [[ -n "$value" ]] && dash_now_title="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "artist")")
          [[ -n "$value" ]] && dash_now_artist="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "album")")
          [[ -n "$value" ]] && dash_now_album="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "station")")
          [[ -n "$value" && "$value" != "$dash_now_title" ]] && dash_now_station="$value"
          value=$(_denon_dashboard_clean_field "$(_denon_dashboard_json_scalar "$line" "type")")
          [[ -n "$value" ]] && dash_now_type="$value"
          sid=$(_denon_dashboard_json_scalar "$line" "sid")
          mid=$(_denon_dashboard_json_scalar "$line" "mid")
          service=$(_denon_dashboard_heos_service_name "$sid" "$mid")
          [[ -n "$service" ]] && dash_now_service="$service"
          if [[ -n "$dash_now_title$dash_now_artist$dash_now_album$dash_now_station" ]]; then
            dash_now_available=1
            dash_now_message="${dash_now_title:-${dash_now_station:-HEOS media}}"
            [[ -z "$dash_now_artist" ]] || dash_now_message="$dash_now_message - $dash_now_artist"
          fi
          ;;
        *'"command": "player/get_play_state"'*)
          [[ "$line" == *'"result": "success"'* ]] || continue
          value=$(printf '%s' "$line" | sed -n 's/.*[?&]state=\([^"&]*\).*/\1/p' | sed -n '1p')
          value=$(_denon_dashboard_transport_name "$value")
          [[ -n "$value" ]] && dash_transport_state="$value"
          ;;
      esac
    done <<<"$text"

    if [[ "$dash_transport_state" == "Stopped" && "$dash_now_available" != "1" ]]; then
      dash_now_message="HEOS Stopped"
    fi
  }

  _denon_dashboard_parse_now() {
    local now_status="$1"
    local text="$2"
    local line label value

    dash_now_title=""
    dash_now_artist=""
    dash_now_album=""
    dash_now_station=""
    dash_now_service=""
    dash_now_type=""
    dash_now_available=0

    if [[ "$now_status" != "0" ]]; then
      if printf '%s' "$text" | grep -qiE 'unavailable|not available|no metadata|Track info unavailable'; then
        dash_now_message=$(_denon_display_empty_message no-metadata)
      else
        dash_now_message=$(_denon_trim "${text:-$(_denon_display_empty_message now-playing-unavailable)}")
      fi
      return 0
    fi

    while IFS= read -r line; do
      label=${line%%:*}
      value=${line#*:}
      [[ "$line" == *:* ]] || continue
      value=$(_denon_trim "$value")
      case "$label" in
        Title) dash_now_title="$value" ;;
        Artist) dash_now_artist="$value" ;;
        Album) dash_now_album="$value" ;;
      esac
    done <<<"$text"

    if [[ -n "$dash_now_title$dash_now_artist$dash_now_album" ]]; then
      dash_now_available=1
      dash_now_message="${dash_now_title:-Unknown title}"
      [[ -z "$dash_now_artist" || "$dash_now_artist" == "Unknown" ]] || dash_now_message="$dash_now_message - $dash_now_artist"
    else
      dash_now_message=$(_denon_display_empty_message no-metadata)
    fi
  }

  _denon_dashboard_summary_value() {
    local json="$1"
    local path="$2"

    if command -v jq >/dev/null 2>&1; then
      jq -r ".$path | if . == null then empty else . end" 2>/dev/null <<<"$json" | sed 's/^null$//'
      return 0
    fi
    return 1
  }

  _denon_dashboard_collect_diagnostics() {
    local summary_json value

    dash_diag_brand_code=""
    dash_diag_model_type=""
    dash_diag_main_volume_scale=""
    dash_diag_main_volume_limit=""
    dash_diag_zone2_volume_scale=""
    dash_diag_zone2_volume_limit=""
    dash_diag_setup_lock=""
    dash_diag_menu_lock=""
    dash_diag_speaker_preset=""
    dash_diag_advanced_mode=""
    dash_diag_ci_mode=""
    dash_diag_heos_sign_in=""
    dash_diag_gui_type=""
    dash_diag_webui_type=""
    dash_diag_avr_firmware="unavailable"
    dash_diag_heos_firmware=""

    _denon_data_collect_summary >/dev/null 2>&1 || {
      dash_errors="${dash_errors}diagnostics unavailable; "
      return 0
    }
    summary_json=$(_denon_data_print_summary_json 2>/dev/null || printf '')
    [[ -n "$summary_json" ]] || {
      dash_errors="${dash_errors}diagnostics unavailable; "
      return 0
    }

    value=$(_denon_dashboard_summary_value "$summary_json" "receiver.brand_code.raw"); [[ -n "$value" ]] && dash_diag_brand_code="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "receiver.model_type.raw"); [[ -n "$value" ]] && dash_diag_model_type="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "volume.main_zone.volume_scale.raw"); [[ -n "$value" ]] && dash_diag_main_volume_scale="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "volume.main_zone.volume_limit_raw"); [[ -n "$value" ]] && dash_diag_main_volume_limit="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "volume.zone2.volume_scale.raw"); [[ -n "$value" ]] && dash_diag_zone2_volume_scale="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "volume.zone2.volume_limit_raw"); [[ -n "$value" ]] && dash_diag_zone2_volume_limit="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.setup_lock.raw"); [[ -n "$value" ]] && dash_diag_setup_lock="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.menu_lock.raw"); [[ -n "$value" ]] && dash_diag_menu_lock="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.speaker_preset.raw"); [[ -n "$value" ]] && dash_diag_speaker_preset="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.advanced_mode.raw"); [[ -n "$value" ]] && dash_diag_advanced_mode="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.ci_mode.raw"); [[ -n "$value" ]] && dash_diag_ci_mode="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.heos_sign_in.raw"); [[ -n "$value" ]] && dash_diag_heos_sign_in="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.gui_type.raw"); [[ -n "$value" ]] && dash_diag_gui_type="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "system.webui_type.raw"); [[ -n "$value" ]] && dash_diag_webui_type="$value"
    value=$(_denon_dashboard_summary_value "$summary_json" "firmware.installed_avr_mainboard_firmware")
    if [[ -n "$value" ]]; then
      dash_diag_avr_firmware="$value"
      case "$(_denon_lower "$value")" in
        unavailable|unavailable_*|*unavailable*) ;;
        *) dash_avr_version="$value" ;;
      esac
    fi
    value=$(_denon_dashboard_summary_value "$summary_json" "firmware.heos_version.value"); [[ -n "$value" ]] && dash_diag_heos_firmware="$value"
  }

  _denon_dashboard_fetch_core_status() {
    # Populate receiver/IP and main/zone2 power, source, volume, mute from the
    # stable info/status endpoints. Sets info_ok=1 (caller scope) when the
    # JSON info path answered; otherwise falls back to the pretty status
    # parsers. Shared by the stable dashboard and the dashboard-ultra
    # appcommand fallback.
    local info_json info_rc info_text status_text zone2_text value

    info_json=$(_denon_info --json 2>/dev/null)
    info_rc=$?
    if [[ "$info_rc" == "0" && "$info_json" == *'"mainZone"'* ]]; then
      info_ok=1
      value=$(_denon_dashboard_json_value "$info_json" "receiver"); [[ -n "$value" ]] && dash_receiver="$value"
      value=$(_denon_dashboard_json_value "$info_json" "ip"); [[ -n "$value" ]] && dash_ip="$value"
      value=$(_denon_dashboard_json_value "$info_json" "mainZone.power"); [[ -n "$value" ]] && dash_main_power="$value"
      value=$(_denon_dashboard_json_value "$info_json" "mainZone.sourceIndex"); [[ -n "$value" ]] && dash_main_source_index="$value"
      value=$(_denon_dashboard_json_value "$info_json" "mainZone.sourceName"); [[ -n "$value" ]] && dash_main_source=$(_denon_clean_source_name "$value")
      value=$(_denon_dashboard_json_value "$info_json" "mainZone.volumeDb"); [[ -n "$value" ]] && dash_main_volume="$value"
      value=$(_denon_dashboard_json_value "$info_json" "mainZone.muted")
      dash_main_muted=$(_denon_normalize_mute "$value")
      value=$(_denon_dashboard_json_value "$info_json" "zone2.power"); [[ -n "$value" ]] && dash_zone2_power="$value"
      value=$(_denon_dashboard_json_value "$info_json" "zone2.sourceIndex"); [[ -n "$value" ]] && dash_zone2_source_index="$value"
      value=$(_denon_dashboard_json_value "$info_json" "zone2.sourceName"); [[ -n "$value" ]] && dash_zone2_source=$(_denon_clean_source_name "$value")
      value=$(_denon_dashboard_json_value "$info_json" "zone2.volumeRaw"); [[ -n "$value" ]] && dash_zone2_volume="$value"
      value=$(_denon_dashboard_json_value "$info_json" "zone2.muted")
      dash_zone2_muted=$(_denon_normalize_mute "$value")
    else
      info_text=$(_denon_info 2>/dev/null)
      if [[ -n "$info_text" ]]; then
        _denon_dashboard_parse_info_text "$info_text"
      else
        dash_errors="${dash_errors}info unavailable; "
      fi
    fi

    if [[ "$info_ok" != "1" ]]; then
      status_text=$(_denon_status_pretty 2>/dev/null)
      if [[ -n "$status_text" ]]; then
        _denon_dashboard_parse_status "$status_text" || true
      else
        dash_errors="${dash_errors}main status unavailable; "
      fi

      zone2_text=$(_denon_zone_status_pretty 2 2>/dev/null)
      if [[ -n "$zone2_text" ]]; then
        _denon_dashboard_parse_zone2_status "$zone2_text" || true
      else
        dash_errors="${dash_errors}zone2 status unavailable; "
      fi
    fi
  }

  _denon_dashboard_collect() {
    local info_ok=0 sources_text zone2_sources_text now_text now_rc
    local zone_names_xml vol_xml telnet_text
    local value

    dash_receiver="Unknown"
    dash_ip="${IP:-Unknown}"
    dash_main_zone_name="Main Zone"
    dash_main_power="Unknown"
    dash_main_source="Unknown"
    dash_main_source_index=""
    dash_main_volume="Unknown"
    dash_main_max_volume_db=""
    dash_main_muted="Unknown"
    dash_sound_mode="Unknown"
    dash_transport_state=""
    dash_avr_version="Unknown"
    # shellcheck disable=SC2034 # Parsed for dashboard diagnostics/future display; not rendered today.
    dash_heos_pid=""
    # shellcheck disable=SC2034 # Parsed for dashboard diagnostics/future display; not rendered today.
    dash_heos_model=""
    dash_heos_version=""
    dash_heos_network=""
    dash_zone2_name="Zone 2"
    dash_zone2_power="Unknown"
    dash_zone2_source="Unknown"
    dash_zone2_source_index=""
    dash_zone2_volume="Unknown"
    dash_zone2_volume_db=""
    dash_zone2_volume_raw=""
    dash_zone2_muted="Unknown"
    dash_now_message=$(_denon_display_empty_message no-metadata)
    dash_now_title=""
    dash_now_artist=""
    dash_now_album=""
    dash_now_station=""
    dash_now_service=""
    # shellcheck disable=SC2034 # Parsed for dashboard diagnostics/future display; not rendered today.
    dash_now_type=""
    dash_now_available=0
    dash_errors=""
    dash_main_sources=$(_denon_display_empty_message no-sources)
    dash_diag_body=""

    _denon_dashboard_fetch_core_status

    sources_text=$(_denon_sources 1 2>/dev/null)
    if [[ -n "$sources_text" ]]; then
      _denon_dashboard_parse_sources "1" "$sources_text"
      dash_main_sources=$(_denon_dashboard_sources_body "$sources_text")
      [[ -n "$(_denon_trim "$dash_main_sources")" ]] || dash_main_sources=$(_denon_display_empty_message no-sources)
    else
      dash_errors="${dash_errors}main sources unavailable; "
    fi

    if [[ "$info_ok" != "1" ]]; then
      zone2_sources_text=$(_denon_sources 2 2>/dev/null)
      if [[ -n "$zone2_sources_text" ]]; then
        _denon_dashboard_parse_sources "2" "$zone2_sources_text"
      else
        dash_errors="${dash_errors}zone2 sources unavailable; "
      fi
    fi

    now_text=$(_denon_track 2>&1)
    now_rc=$?
    _denon_dashboard_parse_now "$now_rc" "$now_text"

    zone_names_xml=$(_denon_get_config 6 2>/dev/null)
    if [[ -n "$zone_names_xml" ]]; then
      _denon_dashboard_parse_zone_names "$zone_names_xml"
    fi

    vol_xml=$(_denon_get_vol_xml 2>/dev/null)
    if [[ -n "$vol_xml" ]]; then
      _denon_dashboard_parse_volume_details "$vol_xml"
      local raw_mute
      raw_mute=$(_denon_resolve_main_mute "$(_denon_extract_main_mute "$vol_xml")")
      local mute_from_vol
      mute_from_vol=$(_denon_normalize_mute "$raw_mute")
      [[ "$mute_from_vol" != "Unknown" ]] && dash_main_muted="$mute_from_vol"
    fi

    if [[ "$dash_receiver" == "Unknown" ]]; then
      local receiver_name
      receiver_name=$(_denon_get_receiver_name 2>/dev/null)
      [[ -n "$receiver_name" && "$receiver_name" != "Unknown" ]] && dash_receiver="$receiver_name"
    fi

    telnet_text=$(_denon_dashboard_telnet_status)
    if [[ -n "$telnet_text" ]]; then
      _denon_dashboard_parse_telnet_status "$telnet_text"
    fi

    if _denon_dashboard_is_heos_source; then
      local heos_text
      heos_text=$(_denon_dashboard_heos_status)
      if [[ -n "$heos_text" ]]; then
        _denon_dashboard_parse_heos_status "$heos_text"
      fi
    else
      local heos_text
      heos_text=$(_denon_dashboard_heos_status players-only)
      if [[ -n "$heos_text" ]]; then
        _denon_dashboard_parse_heos_status "$heos_text"
      fi
    fi

    if [[ "${dashboard_diagnostics:-0}" == "1" ]]; then
      _denon_dashboard_collect_diagnostics
    fi
  }

  _denon_dashboard_event_key() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$dash_main_power" "$dash_main_source_index:$dash_main_source" "$dash_main_muted" "$dash_main_volume" "$dash_sound_mode" \
      "$dash_zone2_power" "$dash_zone2_source_index:$dash_zone2_source" "$dash_zone2_muted" "$dash_transport_state" \
      "$dash_zone2_volume_db" "$dash_now_title" "$dash_now_artist" "$dash_now_album" "$dash_now_station" "$dash_now_service"
  }

  _denon_dashboard_add_event() {
    local entry="$1"
    local stamped
    [[ -n "$entry" ]] || return 0
    [[ "$entry" == "$last_dashboard_event" ]] && return 0
    last_dashboard_event="$entry"
    stamped="$(date +%H:%M:%S) $entry"
    if [[ -n "$dashboard_events" ]]; then
      dashboard_events="$stamped"$'\n'"$dashboard_events"
    else
      dashboard_events="$stamped"
    fi
    dashboard_events=$(printf '%s\n' "$dashboard_events" | sed '/^[[:space:]]*$/d' | awk 'NR <= 100')
  }

  _denon_dashboard_queue_event() {
    local entry="$1"
    [[ -n "$entry" ]] || return 0
    [[ "$entry" == "$last_dashboard_event" ]] && return 0
    if [[ -n "$cycle_events" ]]; then
      cycle_events="$cycle_events"$'\n'"$entry"
    else
      cycle_events="$entry"
    fi
    last_dashboard_event="$entry"
  }

  _denon_dashboard_commit_events() {
    local stamped
    [[ -n "$cycle_events" ]] || return 0
    stamped=$(printf '%s\n' "$cycle_events" | sed "s/^/$(date +%H:%M:%S) /")
    if [[ -n "$dashboard_events" ]]; then
      dashboard_events="$stamped"$'\n'"$dashboard_events"
    else
      dashboard_events="$stamped"
    fi
    dashboard_events=$(printf '%s\n' "$dashboard_events" | sed '/^[[:space:]]*$/d' | awk 'NR <= 100')
  }

  _denon_dashboard_update_events() {
    local current_key cycle_events zone2_parts zone2_changed source_changed
    local prev_main_volume_display dash_main_volume_display prev_zone2_volume_display dash_zone2_volume_display
    local prev_main_mute_display dash_main_mute_display prev_zone2_mute_display dash_zone2_mute_display
    local now_playing_changed now_playing_event dash_now_title_clean dash_now_station_clean
    current_key=$(_denon_dashboard_event_key)

    if [[ "$dashboard_initialized" != "1" ]]; then
      dashboard_initialized=1
      previous_dashboard_key="$current_key"
      prev_main_power="$dash_main_power"
      prev_main_source="$dash_main_source"
      prev_main_source_index="$dash_main_source_index"
      prev_main_muted="$dash_main_muted"
      prev_main_volume="$dash_main_volume"
      prev_sound_mode="$dash_sound_mode"
      prev_zone2_power="$dash_zone2_power"
      prev_zone2_source="$dash_zone2_source"
      prev_zone2_source_index="$dash_zone2_source_index"
      prev_zone2_muted="$dash_zone2_muted"
      prev_zone2_volume_db="$dash_zone2_volume_db"
      prev_transport_state="$dash_transport_state"
      prev_now_title="$dash_now_title"
      prev_now_artist="$dash_now_artist"
      prev_now_album="$dash_now_album"
      prev_now_station="$dash_now_station"
      prev_now_service="$dash_now_service"
      return 0
    fi

    source_changed=0
    if [[ "$dash_main_source_index:$dash_main_source" != "$prev_main_source_index:$prev_main_source" ]]; then
      source_changed=1
    fi

    if (( source_changed )) &&
      _denon_dashboard_event_changed_known "$prev_main_source" "$dash_main_source"; then
      _denon_dashboard_queue_event "Source: ${prev_main_source} -> ${dash_main_source}"
    fi

    if _denon_dashboard_event_changed_known "$prev_sound_mode" "$dash_sound_mode"; then
      _denon_dashboard_queue_event "Mode: ${prev_sound_mode} -> ${dash_sound_mode}"
    fi

    if (( source_changed == 0 )) && _denon_dashboard_is_heos_source &&
      _denon_dashboard_event_changed_known "$prev_transport_state" "$dash_transport_state"; then
      _denon_dashboard_queue_event "HEOS Playback: ${prev_transport_state} -> ${dash_transport_state}"
    fi

    now_playing_changed=0
    dash_now_title_clean=$(_denon_dashboard_clean_field "$dash_now_title")
    dash_now_station_clean=$(_denon_dashboard_clean_field "$dash_now_station")
    if _denon_dashboard_event_changed_known "$prev_now_title" "$dash_now_title"; then
      now_playing_changed=1
    elif [[ -z "$dash_now_title_clean" ]] &&
      _denon_dashboard_event_changed_known "$prev_now_station" "$dash_now_station"; then
      now_playing_changed=1
    elif [[ -z "$dash_now_title_clean" && -z "$dash_now_station_clean" ]] &&
      _denon_dashboard_event_changed_known "$prev_now_service" "$dash_now_service"; then
      now_playing_changed=1
    elif [[ "$dash_now_title" == "$prev_now_title" ]] &&
      _denon_dashboard_event_changed_known "$prev_now_artist" "$dash_now_artist"; then
      now_playing_changed=1
    elif [[ "$dash_now_title" == "$prev_now_title" ]] &&
      _denon_dashboard_event_changed_known "$prev_now_album" "$dash_now_album"; then
      now_playing_changed=1
    fi
    if (( now_playing_changed )); then
      now_playing_event=$(_denon_dashboard_now_playing_event_text)
      [[ -n "$now_playing_event" ]] && _denon_dashboard_queue_event "$now_playing_event"
    fi

    prev_main_volume_display=$(_denon_dashboard_event_volume_display "$prev_main_volume")
    dash_main_volume_display=$(_denon_dashboard_event_volume_display "$dash_main_volume")
    if _denon_dashboard_event_changed_known "$prev_main_volume_display" "$dash_main_volume_display"; then
      _denon_dashboard_queue_event "Main Volume: ${prev_main_volume_display} -> ${dash_main_volume_display}"
    fi

    prev_zone2_volume_display=$(_denon_dashboard_event_volume_display "$prev_zone2_volume_db")
    dash_zone2_volume_display=$(_denon_dashboard_event_volume_display "$dash_zone2_volume_db")
    if _denon_dashboard_event_changed_known "$prev_zone2_volume_display" "$dash_zone2_volume_display"; then
      _denon_dashboard_queue_event "Zone 2 Volume: ${prev_zone2_volume_display} -> ${dash_zone2_volume_display}"
    fi

    prev_main_mute_display=$(_denon_dashboard_event_mute_display "$prev_main_muted")
    dash_main_mute_display=$(_denon_dashboard_event_mute_display "$dash_main_muted")
    if _denon_dashboard_event_changed_known "$prev_main_mute_display" "$dash_main_mute_display"; then
      _denon_dashboard_queue_event "Main Mute: ${prev_main_mute_display} -> ${dash_main_mute_display}"
    fi

    prev_zone2_mute_display=$(_denon_dashboard_event_mute_display "$prev_zone2_muted")
    dash_zone2_mute_display=$(_denon_dashboard_event_mute_display "$dash_zone2_muted")
    if _denon_dashboard_event_changed_known "$prev_zone2_mute_display" "$dash_zone2_mute_display"; then
      _denon_dashboard_queue_event "Zone 2 Mute: ${prev_zone2_mute_display} -> ${dash_zone2_mute_display}"
    fi

    zone2_parts=""
    zone2_changed=0
    if _denon_dashboard_event_changed_known "$prev_zone2_power" "$dash_zone2_power"; then
      zone2_parts="power ${prev_zone2_power} -> ${dash_zone2_power}"
      zone2_changed=1
    fi
    if [[ "$dash_zone2_source_index:$dash_zone2_source" != "$prev_zone2_source_index:$prev_zone2_source" ]] &&
      _denon_dashboard_event_changed_known "$prev_zone2_source" "$dash_zone2_source"; then
      if [[ -n "$zone2_parts" ]]; then
        zone2_parts="$zone2_parts, source ${prev_zone2_source} -> ${dash_zone2_source}"
      else
        zone2_parts="source ${prev_zone2_source} -> ${dash_zone2_source}"
      fi
      zone2_changed=1
    fi
    if (( zone2_changed )); then
      _denon_dashboard_queue_event "Zone 2: $zone2_parts"
    fi

    _denon_dashboard_commit_events

    previous_dashboard_key="$current_key"
    prev_main_power="$dash_main_power"
    prev_main_source="$dash_main_source"
    prev_main_source_index="$dash_main_source_index"
    prev_main_muted="$dash_main_muted"
    prev_main_volume="$dash_main_volume"
    prev_sound_mode="$dash_sound_mode"
    prev_zone2_power="$dash_zone2_power"
    prev_zone2_source="$dash_zone2_source"
    prev_zone2_source_index="$dash_zone2_source_index"
    prev_zone2_muted="$dash_zone2_muted"
    prev_zone2_volume_db="$dash_zone2_volume_db"
    prev_transport_state="$dash_transport_state"
    prev_now_title="$dash_now_title"
    prev_now_artist="$dash_now_artist"
    prev_now_album="$dash_now_album"
    prev_now_station="$dash_now_station"
    prev_now_service="$dash_now_service"
  }

  _denon_dashboard_display_width() {
    # Display width = bytes minus UTF-8 continuation bytes (0x80..0xBF).
    # Treats every codepoint as 1 column. CJK / emoji (2 cols) are not
    # handled; add wcwidth if that ever matters.
    LC_ALL=C awk -v s="$1" 'BEGIN {
      n = length(s); cont = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c >= "\200" && c <= "\277") cont++
      }
      print n - cont
    }'
  }

  _denon_dashboard_fit() {
    local text="$1"
    local width="$2"
    local max=$((width - 3))
    local dw pad

    (( width > 0 )) || return 0
    text=${text//$'\n'/ }
    text=${text//$'\r'/ }

    dw=$(_denon_dashboard_display_width "$text")

    if (( dw > width && width > 3 )); then
      text="${text:0:max}..."
      dw=$width
    elif (( dw > width )); then
      text="${text:0:width}"
      dw=$width
    fi

    printf '%s' "$text"
    pad=$((width - dw))
    (( pad > 0 )) && printf '%*s' "$pad" ''
  }

  _denon_dashboard_strip_ansi() {
    local text="$1"
    local sgr_regex match prefix suffix

    sgr_regex=$'\033\\[[0-9;]*m'
    while [[ "$text" =~ $sgr_regex ]]; do
      match="${BASH_REMATCH[0]}"
      prefix="${text%%"$match"*}"
      suffix="${text#*"$match"}"
      text="${prefix}${suffix}"
    done
    printf '%s' "$text"
  }

  _denon_dashboard_visible_width() {
    local text="$1"

    text=$(_denon_dashboard_strip_ansi "$text")
    text=${text//$'\n'/ }
    text=${text//$'\r'/ }
    _denon_dashboard_display_width "$text"
  }

  _denon_dashboard_truncate_visible() {
    local text="$1"
    local width="$2"
    local max=$((width - 3))
    local dw

    (( width > 0 )) || return 0
    text=$(_denon_dashboard_strip_ansi "$text")
    text=${text//$'\n'/ }
    text=${text//$'\r'/ }
    dw=$(_denon_dashboard_display_width "$text")
    if (( dw > width && width > 3 )); then
      text="${text:0:max}..."
    elif (( dw > width )); then
      text="${text:0:width}"
    fi
    printf '%s' "$text"
  }

  _denon_dashboard_color_capable() {
    [[ -t 1 ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    case "${TERM:-}" in
      ""|dumb) return 1 ;;
      *color*|xterm*|screen*|tmux*|rxvt*|linux|vt100|ansi) return 0 ;;
      *) return 1 ;;
    esac
  }

  _denon_dashboard_setup_color() {
    dashboard_use_color=0
    dash_c_reset=""
    dash_c_dim=""
    dash_c_green=""
    dash_c_yellow=""
    dash_c_red=""

    case "$dashboard_color_mode" in
      never)
        return 0
        ;;
      always)
        [[ -n "${NO_COLOR:-}" ]] && return 0
        dashboard_use_color=1
        ;;
      auto|"")
        _denon_dashboard_color_capable || return 0
        dashboard_use_color=1
        ;;
    esac

    dash_c_reset=$'\033[0m'
    dash_c_dim=$'\033[2m'
    dash_c_green=$'\033[32m'
    dash_c_yellow=$'\033[33m'
    dash_c_red=$'\033[31m'
  }

  _denon_dashboard_c() {
    local color="$1"
    local text="$2"
    local code=""
    [[ "$dashboard_use_color" == "1" ]] || {
      printf '%s' "$text"
      return 0
    }

    case "$color" in
      dim) code="$dash_c_dim" ;;
      green) code="$dash_c_green" ;;
      yellow) code="$dash_c_yellow" ;;
      red) code="$dash_c_red" ;;
      *) code="" ;;
    esac
    if [[ -n "$code" ]]; then
      printf '%s%s%s' "$code" "$text" "$dash_c_reset"
    else
      printf '%s' "$text"
    fi
  }

  _denon_dashboard_value_color() {
    local label="$1"
    local value="$2"
    local lower
    lower=$(_denon_lower "$value")

    if [[ "$value" == \** ]]; then
      echo "green"
      return
    fi

    if [[ -n "$dash_errors" && "$label" == "Notes" ]]; then
      echo "red"
      return
    fi

    case "$lower" in
      on|playing|play|ok|success|wired|wifi|wi-fi|ethernet) echo "green"; return ;;
      paused|pause|muted|yes|unknown|*"unavailable"*|*"no metadata"*|*"stopped"*) echo "yellow"; return ;;
      off|standby|no|"") echo ""; return ;;
      error|*"error"*|fail|failed|unreachable|*"unreachable"*) echo "red"; return ;;
    esac

    case "$label" in
      Muted)
        [[ "$lower" == "yes" ]] && echo "yellow" || echo ""
        return
        ;;
      Power|State)
        [[ "$lower" == "on" || "$lower" == "playing" ]] && echo "green" || echo ""
        return
        ;;
    esac

    echo ""
  }

  _denon_dashboard_color_body_line() {
    local line="$1"
    local label value color

    [[ "$dashboard_use_color" == "1" ]] || {
      printf '%s' "$line"
      return 0
    }

    if [[ "$line" == *:* ]]; then
      label=${line%%:*}
      value=${line#*:}
      color=$(_denon_dashboard_value_color "$(_denon_trim "$label")" "$(_denon_trim "$value")")
      _denon_dashboard_c dim "$label:"
      printf '%s' "${value%%[![:space:]]*}"
      value="${value#"${value%%[![:space:]]*}"}"
      _denon_dashboard_c "$color" "$value"
    else
      color=$(_denon_dashboard_value_color "" "$line")
      _denon_dashboard_c "$color" "$line"
    fi
  }

  _denon_dashboard_repeat() {
    local char="$1"
    local count="$2"
    local i

    for ((i=0; i<count; i++)); do
      printf '%s' "$char"
    done
  }

  _denon_dashboard_width() {
    local cols=""

    if [[ -n "${DENON_DASHBOARD_WIDTH:-}" ]]; then
      cols="$DENON_DASHBOARD_WIDTH"
    elif [[ -t 1 ]]; then
      cols=$(tput cols 2>/dev/null || printf '')
      [[ -n "$cols" ]] || cols="${COLUMNS:-}"
    else
      cols="${COLUMNS:-}"
    fi

    if ! _denon_is_unsigned_integer "$cols"; then
      cols=$(tput cols 2>/dev/null || printf '80')
    fi
    if ! _denon_is_unsigned_integer "$cols"; then
      cols=80
    fi

    if (( cols < 20 )); then
      printf '20'
    elif [[ -n "${DENON_DASHBOARD_WIDTH:-}" ]]; then
      printf '%s' "$cols"
    else
      printf '%s' $((cols - 1))
    fi
  }

  _denon_dashboard_height() {
    local rows=""

    if [[ -n "${DENON_DASHBOARD_HEIGHT:-}" ]]; then
      rows="$DENON_DASHBOARD_HEIGHT"
    elif [[ -t 1 ]]; then
      rows=$(tput lines 2>/dev/null || printf '')
      [[ -n "$rows" ]] || rows="${LINES:-}"
    else
      rows="${LINES:-}"
    fi

    if ! _denon_is_unsigned_integer "$rows"; then
      rows=$(tput lines 2>/dev/null || printf '30')
    fi
    if ! _denon_is_unsigned_integer "$rows"; then
      rows=30
    fi

    if (( rows < 8 )); then
      printf '8'
    else
      printf '%s' "$rows"
    fi
  }

  _denon_dashboard_line_count() {
    local body="$1"

    [[ -n "$body" ]] || {
      printf '0'
      return 0
    }
    printf '%s\n' "$body" | awk 'END { print NR }'
  }

  _denon_dashboard_clamp() {
    local value="$1"
    local min="$2"
    local max="$3"

    (( value < min )) && value="$min"
    (( value > max )) && value="$max"
    printf '%s' "$value"
  }

  _denon_dashboard_layout() {
    local cols="$1"
    local rows="$2"
    local gap=2 footer_height=1
    local top_available bottom_available available usable
    local min_top min_now min_bottom min_total deficit

    if [[ "${dashboard_keyboard_active:-0}" == "1" ]]; then
      footer_height=2
    fi

    dash_layout_width="$cols"
    # shellcheck disable=SC2034 # Layout globals are consumed by dashboard render helpers.
    dash_layout_height="$rows"
    # shellcheck disable=SC2034 # Layout globals are consumed by dashboard render helpers.
    dash_layout_gap="$gap"
    # shellcheck disable=SC2034 # Layout globals are consumed by dashboard render helpers.
    dash_layout_footer_height="$footer_height"

    if (( cols >= 100 )); then
      dash_layout_mode="wide"
      top_available=$((cols - (gap * 2)))
      dash_layout_top_w1=$((top_available / 3))
      dash_layout_top_w2="$dash_layout_top_w1"
      dash_layout_top_w3=$((top_available - dash_layout_top_w1 - dash_layout_top_w2))

      bottom_available=$((cols - gap))
      dash_layout_sources_w=$((bottom_available / 2))
      dash_layout_events_w=$((bottom_available - dash_layout_sources_w))

      available=$((rows - footer_height - 2))
      (( available < 3 )) && available=3

      dash_layout_top_h=$(((available * 25) / 100))
      dash_layout_now_h=$(((available * 20) / 100))
      dash_layout_bottom_h=$((available - dash_layout_top_h - dash_layout_now_h))

      if (( available >= 27 )); then
        min_top=10
        min_now=10
        min_bottom=7
      elif (( available >= 12 )); then
        min_top=4
        min_now=4
        min_bottom=4
      else
        min_top=1
        min_now=1
        min_bottom=1
      fi
      min_total=$((min_top + min_now + min_bottom))

      if (( available >= min_total && dash_layout_top_h < min_top )); then
        deficit=$((min_top - dash_layout_top_h))
        dash_layout_top_h="$min_top"
        dash_layout_bottom_h=$((dash_layout_bottom_h - deficit))
      fi
      if (( available >= min_total && dash_layout_now_h < min_now )); then
        deficit=$((min_now - dash_layout_now_h))
        dash_layout_now_h="$min_now"
        dash_layout_bottom_h=$((dash_layout_bottom_h - deficit))
      fi
      if (( available >= min_total && dash_layout_bottom_h < min_bottom )); then
        deficit=$((min_bottom - dash_layout_bottom_h))
        dash_layout_bottom_h="$min_bottom"
        while (( deficit > 0 && dash_layout_top_h > min_top )); do
          dash_layout_top_h=$((dash_layout_top_h - 1))
          deficit=$((deficit - 1))
        done
        while (( deficit > 0 && dash_layout_now_h > min_now )); do
          dash_layout_now_h=$((dash_layout_now_h - 1))
          deficit=$((deficit - 1))
        done
      fi

      while (( dash_layout_top_h < min_top && dash_layout_bottom_h > min_bottom )); do
        dash_layout_top_h=$((dash_layout_top_h + 1))
        dash_layout_bottom_h=$((dash_layout_bottom_h - 1))
      done
      while (( dash_layout_now_h < min_now && dash_layout_bottom_h > min_bottom )); do
        dash_layout_now_h=$((dash_layout_now_h + 1))
        dash_layout_bottom_h=$((dash_layout_bottom_h - 1))
      done
      (( dash_layout_top_h < 1 )) && dash_layout_top_h=1
      (( dash_layout_now_h < 1 )) && dash_layout_now_h=1
      (( dash_layout_bottom_h < 1 )) && dash_layout_bottom_h=1
      return 0
    fi

    dash_layout_mode="narrow"
    usable=$((rows - footer_height))

    dash_layout_top_w1="$cols"
    dash_layout_top_w2="$cols"
    dash_layout_top_w3="$cols"
    dash_layout_sources_w="$cols"
    dash_layout_events_w="$cols"
    dash_layout_main_h=10
    dash_layout_zone2_h=9
    dash_layout_receiver_h=7
    dash_layout_now_h=10
    usable=$((usable - dash_layout_main_h - dash_layout_zone2_h - dash_layout_receiver_h - dash_layout_now_h))
    (( usable < 12 )) && usable=12
    dash_layout_sources_h=$(((usable * 60) / 100))
    dash_layout_events_h=$((usable - dash_layout_sources_h))
    (( dash_layout_sources_h < 6 )) && dash_layout_sources_h=6
    (( dash_layout_events_h < 6 )) && dash_layout_events_h=6
  }

  _denon_dashboard_set_borders() {
    if [[ "$dashboard_ascii" == "1" ]]; then
      dash_tl="+"
      dash_tr="+"
      dash_bl="+"
      dash_br="+"
      dash_h="-"
      dash_v="|"
    else
      dash_tl="┌"
      dash_tr="┐"
      dash_bl="└"
      dash_br="┘"
      dash_h="─"
      dash_v="│"
    fi
  }

  _denon_dashboard_body_line() {
    local body="$1"
    local idx="$2"

    printf '%s\n' "$body" | sed -n "${idx}p"
  }

  _denon_dashboard_render_card_line() {
    local title="$1"
    local body="$2"
    local width="$3"
    local height="$4"
    local row="$5"
    local inner=$((width - 4))
    local body_idx line fitted

    (( height > 0 )) || return 0
    (( width < 4 )) && width=4
    inner=$((width - 4))

    if (( row == 0 )); then
      _denon_dashboard_c dim "$dash_tl"
      _denon_dashboard_c dim "$(_denon_dashboard_repeat "$dash_h" $((width - 2)))"
      _denon_dashboard_c dim "$dash_tr"
    elif (( row == height - 1 )); then
      _denon_dashboard_c dim "$dash_bl"
      _denon_dashboard_c dim "$(_denon_dashboard_repeat "$dash_h" $((width - 2)))"
      _denon_dashboard_c dim "$dash_br"
    elif (( row == 1 )); then
      fitted=$(_denon_dashboard_fit "$title" "$inner")
      _denon_dashboard_c dim "$dash_v"
      printf ' '
      _denon_dashboard_c "" "$fitted"
      printf ' '
      _denon_dashboard_c dim "$dash_v"
    elif (( row == 2 )); then
      _denon_dashboard_c dim "$dash_v"
      printf ' '
      _denon_dashboard_c dim "$(_denon_dashboard_repeat "$dash_h" "$inner")"
      printf ' '
      _denon_dashboard_c dim "$dash_v"
    else
      body_idx=$((row - 2))
      line=$(_denon_dashboard_body_line "$body" "$body_idx")
      fitted=$(_denon_dashboard_fit "$line" "$inner")
      _denon_dashboard_c dim "$dash_v"
      printf ' '
      _denon_dashboard_color_body_line "$fitted"
      printf ' '
      _denon_dashboard_c dim "$dash_v"
    fi
  }

  _denon_dashboard_render_card() {
    local title="$1"
    local body="$2"
    local width="$3"
    local height="$4"
    local row

    for ((row=0; row<height; row++)); do
      _denon_dashboard_render_card_line "$title" "$body" "$width" "$height" "$row"
      printf '\n'
    done
  }

  _denon_dashboard_render_columns() {
    local count="$1"
    local height="$2"
    local gap="  "
    local row

    for ((row=0; row<height; row++)); do
      if [[ "$count" == "3" ]]; then
        _denon_dashboard_render_card_line "$col1_title" "$col1_body" "$col1_width" "$height" "$row"
        printf '%s' "$gap"
        _denon_dashboard_render_card_line "$col2_title" "$col2_body" "$col2_width" "$height" "$row"
        printf '%s' "$gap"
        _denon_dashboard_render_card_line "$col3_title" "$col3_body" "$col3_width" "$height" "$row"
      else
        _denon_dashboard_render_card_line "$col1_title" "$col1_body" "$col1_width" "$height" "$row"
        printf '%s' "$gap"
        _denon_dashboard_render_card_line "$col2_title" "$col2_body" "$col2_width" "$height" "$row"
      fi
      printf '\n'
    done
  }

  _denon_dashboard_render_two_panel_row() {
    local left_title="$1"
    local left_body="$2"
    local left_width="$3"
    local right_title="$4"
    local right_body="$5"
    local right_width="$6"
    local height="$7"
    local gap="  "
    local row

    for ((row=0; row<height; row++)); do
      _denon_dashboard_render_card_line "$left_title" "$left_body" "$left_width" "$height" "$row"
      printf '%s' "$gap"
      _denon_dashboard_render_card_line "$right_title" "$right_body" "$right_width" "$height" "$row"
      printf '\n'
    done
  }

  _denon_dashboard_build_bodies() {
    dash_source_label="$dash_main_source"
    dash_zone2_source_label="$dash_zone2_source"
    local dash_main_muted_label dash_zone2_muted_label dash_transport_state_label dash_now_title_label
    local dash_main_zone_label dash_zone2_zone_label dash_heos_network_label dash_heos_label

    if [[ -n "$dash_main_max_volume_db" ]]; then
      dash_main_volume_label="${dash_main_volume:-Unknown} dB / max ${dash_main_max_volume_db} dB"
    else
      dash_main_volume_label="${dash_main_volume:-Unknown} dB"
    fi
    dash_main_zone_label=$(_denon_display_zone_label "${dash_main_zone_name:-Main Zone}")
    dash_main_muted_label=$(_denon_mute_display_name "$dash_main_muted")
    dash_main_body=$(printf 'Zone:   %s\nPower:  %s\nSource: %s\nMode:   %s\nVolume: %s\nMuted:  %s' \
      "$dash_main_zone_label" "${dash_main_power:-Unknown}" "${dash_source_label:-Unknown}" \
      "${dash_sound_mode:-Unknown}" "$dash_main_volume_label" "$dash_main_muted_label")

    dash_transport_state_label=$(_denon_dashboard_transport_name "${dash_transport_state:-Unknown}")
    [[ -n "$dash_transport_state_label" ]] || dash_transport_state_label="Unknown"
    case "$(_denon_lower "${dash_now_message:-}")" in
      "no metadata for current source") dash_now_title_label=$(_denon_display_empty_message no-metadata) ;;
      "now-playing unavailable") dash_now_title_label=$(_denon_display_empty_message now-playing-unavailable) ;;
      *) dash_now_title_label="${dash_now_title:-${dash_now_message:-Unknown}}" ;;
    esac
    dash_now_body=$(printf 'Title:   %s\nArtist:  %s\nAlbum:   %s\nService: %s\nStation: %s\nState:   %s' \
      "$dash_now_title_label" "${dash_now_artist:-Unknown}" "${dash_now_album:-Unknown}" \
      "${dash_now_service:-Unknown}" "${dash_now_station:-Unknown}" "$dash_transport_state_label")

    if [[ -n "$dash_zone2_volume_db" && -n "$dash_zone2_volume_raw" ]]; then
      dash_zone2_volume_label="${dash_zone2_volume_db} dB (raw ${dash_zone2_volume_raw})"
    else
      dash_zone2_volume_label="${dash_zone2_volume:-Unknown}"
    fi
    dash_zone2_zone_label=$(_denon_display_zone_label "${dash_zone2_name:-Zone 2}")
    dash_zone2_muted_label=$(_denon_mute_display_name "$dash_zone2_muted")
    dash_zone2_body=$(printf 'Zone:   %s\nPower:  %s\nSource: %s\nVolume: %s\nMuted:  %s' \
      "$dash_zone2_zone_label" "${dash_zone2_power:-Unknown}" "${dash_zone2_source_label:-Unknown}" \
      "$dash_zone2_volume_label" "$dash_zone2_muted_label")

    dash_heos_network_label=$(_denon_display_network_label "$dash_heos_network")
    dash_heos_label="${dash_heos_version:-Unknown}"
    if [[ "$dash_heos_network_label" != "Unknown" ]]; then
      dash_heos_label="$dash_heos_label $dash_heos_network_label"
    fi
    dash_receiver_body=$(printf 'Receiver: %s\nIP:       %s\nVersion: %s\nHEOS:    %s' \
      "$(_denon_display_unknown "$dash_receiver")" "$(_denon_display_unknown "$dash_ip")" \
      "$(_denon_dashboard_receiver_version_label "${dash_avr_version:-}")" "$dash_heos_label")
    if [[ -n "${dash_diag_model_type:-}" ]]; then
      dash_receiver_body="$dash_receiver_body"$'\n'"Model Type: ${dash_diag_model_type}"
    fi
    if [[ -n "${dash_diag_brand_code:-}" ]]; then
      dash_receiver_body="$dash_receiver_body"$'\n'"Brand Code: ${dash_diag_brand_code}"
    fi
    if [[ "${dashboard_diagnostics:-0}" == "1" ]]; then
      dash_diag_body=$(printf 'Brand:  raw=%s label=%s\nModel:  raw=%s label=%s\nMain Volume: scale %s / limit %s\nZone 2 Volume: scale %s / limit %s\nLocks: setup %s / menu %s\nPreset: raw=%s label=%s\nModes: advanced %s / CI %s\nHEOS Sign-In: raw=%s label=%s\nUI: gui %s / web %s\nAVR FW: %s\nHEOS FW: %s separate' \
        "$(_denon_display_unknown "$dash_diag_brand_code")" "$(_denon_display_unknown "$(_denon_data_raw_label "${dash_diag_brand_code:-}")")" \
        "$(_denon_display_unknown "$dash_diag_model_type")" "$(_denon_display_unknown "$(_denon_data_raw_label "${dash_diag_model_type:-}")")" \
        "$(_denon_display_unknown "$dash_diag_main_volume_scale")" "$(_denon_display_unknown "$dash_diag_main_volume_limit")" \
        "$(_denon_display_unknown "$dash_diag_zone2_volume_scale")" "$(_denon_display_unknown "$dash_diag_zone2_volume_limit")" \
        "$(_denon_display_unknown "$dash_diag_setup_lock")" "$(_denon_display_unknown "$dash_diag_menu_lock")" \
        "$(_denon_display_unknown "$dash_diag_speaker_preset")" "$(_denon_display_unknown "$(_denon_data_raw_label "${dash_diag_speaker_preset:-}")")" \
        "$(_denon_display_unknown "$dash_diag_advanced_mode")" "$(_denon_display_unknown "$dash_diag_ci_mode")" \
        "$(_denon_display_unknown "$dash_diag_heos_sign_in")" "$(_denon_display_unknown "$(_denon_data_raw_label "${dash_diag_heos_sign_in:-}")")" \
        "$(_denon_display_unknown "$dash_diag_gui_type")" "$(_denon_display_unknown "$dash_diag_webui_type")" \
        "$(_denon_display_unknown "${dash_diag_avr_firmware:-unavailable}")" "$(_denon_display_unknown "$dash_diag_heos_firmware")")
    fi

    local events_max=$(( ${dash_layout_bottom_h:-12} - 4 ))
    (( events_max < 5 )) && events_max=5
    if [[ -n "$dashboard_events" ]]; then
      dash_events_body=$(printf '%s\n' "$dashboard_events" | head -n "$events_max")
    else
      dash_events_body=$(_denon_display_empty_message no-state-changes)
    fi
  }

  _denon_tool_version_label() {
    printf '%s v%s' "${DENON_CONTROLLER_NAME:-denon-avr-controller}" "$(_denon_tool_version)"
  }

  _denon_tool_version() {
    printf '%s' "${DENON_CONTROLLER_VERSION:-unknown}"
  }

  _denon_resolved_tool_version() {
    local script_path script_dir version_file version

    script_path=$(_denon_script_path 2>/dev/null || printf '')
    if [[ -n "$script_path" ]]; then
      script_dir=$(cd "$(dirname "$script_path")" 2>/dev/null && pwd)
      version_file="${script_dir:-$PWD}/VERSION"
      if [[ -r "$version_file" ]]; then
        version=$(_denon_trim "$(sed -n '1p' "$version_file")")
        if [[ -n "$version" ]]; then
          printf '%s' "$version"
          return 0
        fi
      fi
      if [[ -r "$script_path" ]]; then
        version=$(DENON_UNIT_TEST='' bash "$script_path" --version 2>/dev/null | sed -n '1p')
        version=$(_denon_trim "$version")
        if [[ -n "$version" ]]; then
          printf '%s' "$version"
          return 0
        fi
      fi
    fi

    version=$(env DENON_UNIT_TEST= denon --version 2>/dev/null | sed -n '1p')
    version=$(_denon_trim "$version")
    if [[ -n "$version" ]]; then
      printf '%s' "$version"
      return 0
    fi

    printf '%s' "${DENON_CONTROLLER_VERSION:-unknown}"
  }

  _denon_dashboard_receiver_version_label() {
    local value="$1"
    case "$(_denon_lower "$(_denon_trim "$value")")" in
      ""|unknown|null|none|n/a|na|-|unavailable|unavailable_*|*unavailable*) echo "Unknown" ;;
      *) _denon_display_unknown "$value" ;;
    esac
  }

  _denon_dashboard_compose_footer_line() {
    local left_text="$1"
    local right_text="$2"
    local available_width="$3"
    local padding=2
    local right_width left_width left_visible space_count left_fit

    (( available_width > 0 )) || return 0
    right_width=$(_denon_dashboard_visible_width "$right_text")
    if (( right_width <= 0 )); then
      _denon_dashboard_truncate_visible "$left_text" "$available_width"
      return 0
    fi

    if (( available_width <= right_width )); then
      printf '%s' "$right_text"
      return 0
    fi

    left_width=$((available_width - right_width - padding))
    if (( left_width <= 0 )); then
      space_count=$((available_width - right_width))
      _denon_dashboard_repeat ' ' "$space_count"
      printf '%s' "$right_text"
      return 0
    fi

    left_fit=$(_denon_dashboard_truncate_visible "$left_text" "$left_width")
    left_visible=$(_denon_dashboard_visible_width "$left_fit")
    space_count=$((available_width - right_width - left_visible))
    printf '%s' "$left_fit"
    _denon_dashboard_repeat ' ' "$space_count"
    printf '%s' "$right_text"
  }

  _denon_dashboard_footer_left_text() {
    local max_width="$1"
    local updated receiver ip receiver_info version_info notes candidate
    local prefix suffix detail_width detail

    updated="Updated $(date '+%H:%M:%S')"
    receiver="${dash_receiver:-Unknown}"
    ip="${dash_ip:-Unknown}"
    receiver_info="$receiver @ $ip"
    version_info="$(_denon_tool_version_label)"
    notes=""
    if [[ -n "$dash_errors" ]]; then
      notes=" | Notes: ${dash_errors%; }"
    fi

    candidate="$updated | $receiver_info | $version_info$notes"
    if (( max_width <= 0 || $(_denon_dashboard_visible_width "$candidate") <= max_width )); then
      printf '%s' "$candidate"
      return 0
    fi

    candidate="$updated | $receiver | $version_info$notes"
    if (( $(_denon_dashboard_visible_width "$candidate") <= max_width )); then
      printf '%s' "$candidate"
      return 0
    fi

    prefix="$updated | "
    suffix=" | $version_info$notes"
    detail_width=$((max_width - $(_denon_dashboard_visible_width "$prefix") - $(_denon_dashboard_visible_width "$suffix")))
    if (( detail_width >= 4 )); then
      detail=$(_denon_dashboard_truncate_visible "$receiver_info" "$detail_width")
      printf '%s%s%s' "$prefix" "$detail" "$suffix"
      return 0
    fi

    printf '%s' "$updated | $version_info$notes"
  }

  _denon_dashboard_key_help_text() {
    local width="$1"
    local full="Keys: ↑/↓=Volume  ←/→=Prev/Next  Space=Play/Pause  M=Mute  #=Source From List  Z=Zone  Q=Quit"
    local compact="Keys: ↑/↓=Vol  ←/→=Prev/Next  Space=Play/Pause  M=Mute  #=Src From List  Z=Zone  Q=Quit"

    if (( $(_denon_dashboard_visible_width "$full") <= width )); then
      printf '%s' "$full"
    else
      printf '%s' "$compact"
    fi
  }

  _denon_dashboard_render_footer() {
    local width="$1"
    local hints="" hint_width left_width left footer

    if [[ "${watch:-0}" == "1" ]]; then
      if [[ "${dashboard_keyboard_active:-0}" == "1" ]]; then
        hints=$(_denon_dashboard_key_help_text "$width")
        _denon_dashboard_compose_footer_line \
          "Control Target: ${dashboard_control_target:-Main}" \
          "$(_denon_tool_version_label)" "$width"
        printf '\n'
        _denon_dashboard_fit "$hints" "$width"
        printf '\n'
        return 0
      fi
      hints="[q] Quit | [r] Redraw"
      hint_width=$(_denon_dashboard_visible_width "$hints")
      left_width=$((width - hint_width - 2))
      left=$(_denon_dashboard_footer_left_text "$left_width")
      footer=$(_denon_dashboard_compose_footer_line "$left" "$hints" "$width")
    else
      left=$(_denon_dashboard_footer_left_text "$width")
      footer=$(_denon_dashboard_compose_footer_line "$left" "" "$width")
    fi
    printf '%s' "$footer"
    printf '\n'
  }

  _denon_dashboard_render_narrow() {
    local width="${dash_layout_width:-$1}"

    _denon_dashboard_render_card "Main Zone" "$dash_main_body" "$width" "${dash_layout_main_h:-10}"
    _denon_dashboard_render_card "Zone 2" "$dash_zone2_body" "$width" "${dash_layout_zone2_h:-9}"
    _denon_dashboard_render_card "Receiver Info" "$dash_receiver_body" "$width" "${dash_layout_receiver_h:-7}"
    _denon_dashboard_render_card "Now Playing / Audio" "$dash_now_body" "$width" "${dash_layout_now_h:-10}"
    if [[ "${dashboard_diagnostics:-0}" == "1" ]]; then
      _denon_dashboard_render_card "Diagnostics" "$dash_diag_body" "$width" 15
    fi
    _denon_dashboard_render_card "Main Zone Sources" "$dash_main_sources" "$width" "${dash_layout_sources_h:-12}"
    _denon_dashboard_render_card "Recent Events" "$dash_events_body" "$width" "${dash_layout_events_h:-12}"
  }

  _denon_dashboard_render_wide() {
    col1_title="Main Zone"
    col1_body="$dash_main_body"
    col1_width="$dash_layout_top_w1"
    col2_title="Zone 2"
    col2_body="$dash_zone2_body"
    col2_width="$dash_layout_top_w2"
    col3_title="Receiver Info"
    col3_body="$dash_receiver_body"
    col3_width="$dash_layout_top_w3"
    _denon_dashboard_render_columns 3 "$dash_layout_top_h"
    printf '\n'

    _denon_dashboard_render_card "Now Playing / Audio" "$dash_now_body" "$dash_layout_width" "$dash_layout_now_h"
    printf '\n'

    _denon_dashboard_render_two_panel_row \
      "Main Zone Sources" "$dash_main_sources" "$dash_layout_sources_w" \
      "Recent Events" "$dash_events_body" "$dash_layout_events_w" \
      "$dash_layout_bottom_h"
    if [[ "${dashboard_diagnostics:-0}" == "1" ]]; then
      printf '\n'
      _denon_dashboard_render_card "Diagnostics" "$dash_diag_body" "$dash_layout_width" 15
    fi
  }

  _denon_dashboard_render_medium() {
    local width="$1"
    _denon_dashboard_render_wide "$width"
  }

  _denon_dashboard_render_ultrawide() {
    local width="$1"
    _denon_dashboard_render_wide "$width"
  }

  _denon_dashboard_render() {
    local width height
    width=$(_denon_dashboard_width)
    height=$(_denon_dashboard_height)
    _denon_dashboard_setup_color
    _denon_dashboard_set_borders
    _denon_dashboard_layout "$width" "$height"
    _denon_dashboard_build_bodies

    if [[ "$dash_layout_mode" == "wide" ]]; then
      _denon_dashboard_render_wide "$width"
    else
      _denon_dashboard_render_narrow "$width"
    fi
    _denon_dashboard_render_footer "$width"
  }

  _denon_dashboard_redraw() {
    local rendered

    rendered=$(_denon_dashboard_render)
    printf '\033[H\033[J%s' "$rendered"
  }

  _denon_dashboard_restore_terminal() {
    if [[ "${dashboard_terminal_active:-0}" == "1" && -n "${dashboard_saved_stty:-}" ]]; then
      stty "$dashboard_saved_stty" 2>/dev/null || true
      dashboard_terminal_active=0
    fi
    printf '\033[?25h'
  }

  _denon_dashboard_parse_key() {
    local sequence="$1"

    case "$sequence" in
      $'\033[A') echo "volume_up" ;;
      $'\033[B') echo "volume_down" ;;
      $'\033[C') echo "next" ;;
      $'\033[D') echo "previous" ;;
      " ") echo "play_pause" ;;
      [0-9]) echo "digit_$sequence" ;;
      m|M) echo "mute_toggle" ;;
      z|Z) echo "cycle_zone_target" ;;
      q|Q) echo "quit" ;;
      r|R) echo "redraw" ;;
      *) return 1 ;;
    esac
  }

  _denon_dashboard_now_ms() {
    if [[ -n "${dashboard_test_now_ms:-}" ]]; then
      printf '%s' "$dashboard_test_now_ms"
      return 0
    fi
    date +%s%3N 2>/dev/null || awk 'BEGIN { printf "%.0f", systime() * 1000 }'
  }

  _denon_dashboard_throttle_allows_command() {
    local now elapsed

    now=$(_denon_dashboard_now_ms)
    if [[ -n "${dashboard_last_command_ms:-}" ]]; then
      elapsed=$((now - dashboard_last_command_ms))
      if (( elapsed < ${dashboard_command_throttle_ms:-200} )); then
        return 1
      fi
    fi
    dashboard_last_command_ms="$now"
    return 0
  }

  _denon_dashboard_key_event_name() {
    local action="$1"

    case "$action" in
      volume_up) echo "Volume Up" ;;
      volume_down) echo "Volume Down" ;;
      previous) echo "Previous" ;;
      next) echo "Next" ;;
      play_pause) echo "Play/Pause" ;;
      mute_toggle) echo "Mute Toggle" ;;
      *) echo "$action" ;;
    esac
  }

  _denon_dashboard_command_event_name() {
    local action="$1"

    case "$action" in
      volume_up) echo "volume up" ;;
      volume_down) echo "volume down" ;;
      previous) echo "previous" ;;
      next) echo "next" ;;
      play_pause) echo "play/pause" ;;
      mute_toggle) echo "mute toggle" ;;
      *) echo "$action" ;;
    esac
  }

  _denon_dashboard_transport_event_name() {
    local action="$1"
    case "$action" in
      previous) echo "Previous" ;;
      next) echo "Next" ;;
      play_pause) echo "Play/Pause" ;;
      *) echo "$action" ;;
    esac
  }

  _denon_dashboard_is_transport_action() {
    case "$1" in
      previous|next|play_pause) return 0 ;;
      *) return 1 ;;
    esac
  }

  _denon_dashboard_transport_status_json() {
    _denon_heos_helper status-json 2>/dev/null
  }

  _denon_dashboard_transport_json_field() {
    local json="$1"
    local key="$2"
    _denon_dashboard_json_scalar "$json" "$key"
  }

  _denon_dashboard_transport_json_state() {
    local json="$1"
    local value

    value=$(_denon_dashboard_transport_json_field "$json" "state")
    _denon_dashboard_transport_name "$value"
  }

  _denon_dashboard_transport_json_signature() {
    local json="$1"
    local song artist album station mid qid sid

    song=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "song")")
    artist=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "artist")")
    album=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "album")")
    station=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "station")")
    mid=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "mid")")
    qid=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "qid")")
    sid=$(_denon_dashboard_clean_field "$(_denon_dashboard_transport_json_field "$json" "sid")")
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$song" "$artist" "$album" "$station" "$mid" "$qid" "$sid"
  }

  _denon_dashboard_transport_signature_known() {
    local signature="$1"
    [[ "$signature" != "||||||" ]]
  }

  _denon_dashboard_transport_command_for_action() {
    local action="$1"
    local state="$2"

    case "$action" in
      previous) echo "prev" ;;
      next) echo "next" ;;
      play_pause)
        case "$(_denon_lower "$state")" in
          play|playing) echo "pause" ;;
          *) echo "play" ;;
        esac
        ;;
      *) return 1 ;;
    esac
  }

  _denon_dashboard_transport_verified() {
    local action="$1"
    local command="$2"
    local before_json="$3"
    local after_json="$4"
    local before_state after_state before_signature after_signature

    case "$action" in
      play_pause)
        before_state=$(_denon_dashboard_transport_json_state "$before_json")
        after_state=$(_denon_dashboard_transport_json_state "$after_json")
        _denon_dashboard_event_changed_known "$before_state" "$after_state" || return 1
        case "$command:$after_state" in
          pause:Paused|play:Playing) return 0 ;;
          *) return 1 ;;
        esac
        ;;
      previous|next)
        before_signature=$(_denon_dashboard_transport_json_signature "$before_json")
        after_signature=$(_denon_dashboard_transport_json_signature "$after_json")
        _denon_dashboard_transport_signature_known "$before_signature" || return 1
        _denon_dashboard_transport_signature_known "$after_signature" || return 1
        [[ "$before_signature" != "$after_signature" ]]
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_dashboard_run_transport_action() {
    local action="$1"
    local before_json before_state command output output_file attempt attempts sleep_seconds after_json

    dashboard_transport_result=""
    dashboard_transport_error=""
    dashboard_transport_command=""

    _denon_dashboard_is_heos_source || {
      dashboard_transport_result="unavailable"
      dashboard_transport_error="not-heos-source"
      return 1
    }

    before_json=$(_denon_dashboard_transport_status_json 2>/dev/null || printf '')
    before_state=$(_denon_dashboard_transport_json_state "$before_json")
    [[ -n "$before_state" ]] || before_state="${dash_transport_state:-}"
    command=$(_denon_dashboard_transport_command_for_action "$action" "$before_state") || {
      dashboard_transport_result="unavailable"
      return 1
    }
    # shellcheck disable=SC2034 # Exposed to dashboard tests/diagnostics after this helper runs.
    dashboard_transport_command="$command"

    output_file=$(mktemp 2>/dev/null || printf '')
    if [[ -n "$output_file" ]] && _denon_heos_control "$command" >"$output_file" 2>&1; then
      output=$(<"$output_file")
      rm -f "$output_file"
    elif [[ -n "$output_file" ]]; then
      output=$(<"$output_file")
      rm -f "$output_file"
      # shellcheck disable=SC2034 # Exposed to dashboard tests/diagnostics after this helper runs.
      dashboard_transport_error="$output"
      if printf '%s' "$output" | grep -qiE 'no HEOS player|invalid HEOS player|no HEOS player id'; then
        dashboard_transport_result="no-player"
      else
        dashboard_transport_result="failed"
      fi
      return 1
    else
      if _denon_heos_control "$command" >/dev/null 2>&1; then
        output=""
      else
        dashboard_transport_result="failed"
        return 1
      fi
    fi

    attempts="${DENON_DASHBOARD_TRANSPORT_VERIFY_ATTEMPTS:-3}"
    sleep_seconds="${DENON_DASHBOARD_TRANSPORT_VERIFY_SLEEP:-0.75}"
    attempt=0
    while (( attempt < attempts )); do
      attempt=$((attempt + 1))
      if [[ "$sleep_seconds" != "0" && "$sleep_seconds" != "0.0" ]]; then
        sleep "$sleep_seconds" 2>/dev/null || true
      fi
      after_json=$(_denon_dashboard_transport_status_json 2>/dev/null || printf '')
      if [[ -n "$before_json" && -n "$after_json" ]] &&
        _denon_dashboard_transport_verified "$action" "$command" "$before_json" "$after_json"; then
        dashboard_transport_result="verified"
        return 0
      fi
    done

    dashboard_transport_result="sent-unverified"
    return 0
  }

  _denon_dashboard_add_command_warning() {
    local action="$1"
    local command_event

    command_event=$(_denon_dashboard_command_event_name "$action")
    case "$action" in
      previous|next|play_pause)
        _denon_dashboard_add_event "Transport command unavailable: $command_event"
        ;;
      volume_up|volume_down|mute_toggle)
        if [[ "${dashboard_control_target:-Main}" == "Zone2" ]]; then
          _denon_dashboard_add_event "Zone2 command unavailable: $command_event"
        else
          _denon_dashboard_add_event "Command unavailable: $command_event"
        fi
        ;;
      *)
        _denon_dashboard_add_event "Command unavailable: $command_event"
        ;;
    esac
  }

  _denon_dashboard_source_name_for_index() {
    local wanted="$1"
    local line idx name

    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      [[ -n "$line" ]] || continue
      [[ "${line:0:1}" == "*" ]] && line=$(_denon_trim "${line:1}")
      idx=${line%%[[:space:]]*}
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      name=$(_denon_trim "${line#"$idx"}")
      if [[ "$idx" == "$wanted" ]]; then
        printf '%s' "$name"
        return 0
      fi
    done <<<"${dash_main_sources:-}"
    return 1
  }

  _denon_dashboard_source_has_longer_prefix() {
    local prefix="$1"
    local line idx

    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      [[ -n "$line" ]] || continue
      [[ "${line:0:1}" == "*" ]] && line=$(_denon_trim "${line:1}")
      idx=${line%%[[:space:]]*}
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      if [[ "$idx" != "$prefix" && "$idx" == "$prefix"* ]]; then
        return 0
      fi
    done <<<"${dash_main_sources:-}"
    return 1
  }

  _denon_dashboard_source_has_prefix() {
    local prefix="$1"
    local line idx

    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      [[ -n "$line" ]] || continue
      [[ "${line:0:1}" == "*" ]] && line=$(_denon_trim "${line:1}")
      idx=${line%%[[:space:]]*}
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      [[ "$idx" == "$prefix"* ]] && return 0
    done <<<"${dash_main_sources:-}"
    return 1
  }

  _denon_dashboard_reset_numeric_buffer() {
    dashboard_numeric_buffer=""
    dashboard_numeric_deadline_ms=""
  }

  _denon_dashboard_dispatch_source_hotkey() {
    local source_idx="$1"
    local source_name

    _denon_dashboard_reset_numeric_buffer
    source_name=$(_denon_dashboard_source_name_for_index "$source_idx") || {
      _denon_dashboard_add_event "Source hotkey unavailable: $source_idx"
      return 0
    }
    _denon_dashboard_throttle_allows_command || return 0
    _denon_dashboard_add_event "Key: Source $source_idx $source_name"
    if ! _denon_set_source "$source_idx" "1" >/dev/null 2>&1; then
      _denon_dashboard_add_event "Source hotkey unavailable: $source_idx"
    fi
  }

  _denon_dashboard_handle_digit() {
    local digit="$1"
    local now

    now=$(_denon_dashboard_now_ms)
    dashboard_numeric_buffer="${dashboard_numeric_buffer:-}${digit}"
    dashboard_numeric_deadline_ms=$((now + ${dashboard_numeric_timeout_ms:-750}))

    if _denon_dashboard_source_name_for_index "$dashboard_numeric_buffer" >/dev/null &&
      ! _denon_dashboard_source_has_longer_prefix "$dashboard_numeric_buffer"; then
      _denon_dashboard_dispatch_source_hotkey "$dashboard_numeric_buffer"
    elif ! _denon_dashboard_source_has_prefix "$dashboard_numeric_buffer"; then
      _denon_dashboard_dispatch_source_hotkey "$dashboard_numeric_buffer"
    fi
  }

  _denon_dashboard_flush_numeric_if_expired() {
    local now

    [[ -n "${dashboard_numeric_buffer:-}" ]] || return 0
    [[ -n "${dashboard_numeric_deadline_ms:-}" ]] || return 0
    now=$(_denon_dashboard_now_ms)
    if (( now >= dashboard_numeric_deadline_ms )); then
      _denon_dashboard_dispatch_source_hotkey "$dashboard_numeric_buffer"
    fi
  }

  _denon_dashboard_zone2_is_muted() {
    case "$(_denon_lower "${dash_zone2_muted:-}")" in
      yes|true|1|on|muted) return 0 ;;
      *) return 1 ;;
    esac
  }

  _denon_dashboard_run_action() {
    local action="$1"
    local step="${DENON_VOLUME_STEP_DB:-1}"
    step="${step#[-+]}"

    case "$action" in
      volume_up)
        if [[ "${dashboard_control_target:-Main}" == "Zone2" ]]; then
          _denon_zone2_change_volume "$step"
        else
          _denon_change_volume "$step"
        fi
        ;;
      volume_down)
        if [[ "${dashboard_control_target:-Main}" == "Zone2" ]]; then
          _denon_zone2_change_volume "-$step"
        else
          _denon_change_volume "-$step"
        fi
        ;;
      mute_toggle)
        if [[ "${dashboard_control_target:-Main}" == "Zone2" ]]; then
          if _denon_dashboard_zone2_is_muted; then
            _denon_set_config 12 '<Zone2><Mute>2</Mute></Zone2>'
          else
            _denon_set_config 12 '<Zone2><Mute>1</Mute></Zone2>'
          fi
        else
          _denon_toggle mute
        fi
        ;;
      previous)
        _denon_heos_control prev
        ;;
      next)
        _denon_heos_control next
        ;;
      play_pause)
        case "$(_denon_lower "${dash_transport_state:-}")" in
          play|playing) _denon_heos_control pause ;;
          *) _denon_heos_control play ;;
        esac
        ;;
      *)
        return 1
        ;;
    esac
  }

  _denon_dashboard_handle_key() {
    local key="$1"
    local action key_event

    action=$(_denon_dashboard_parse_key "$key" 2>/dev/null) || return 0
    if [[ "$action" != digit_* && -n "${dashboard_numeric_buffer:-}" ]]; then
      _denon_dashboard_reset_numeric_buffer
    fi

    case "$action" in
      quit)
        _denon_dashboard_reset_numeric_buffer
        dashboard_stop_pending=1
        dashboard_exit_status=0
        ;;
      redraw)
        dashboard_resize_pending=0
        "${dashboard_redraw_cmd:-_denon_dashboard_redraw}"
        ;;
      cycle_zone_target)
        if [[ "${dashboard_control_target:-Main}" == "Main" ]]; then
          dashboard_control_target="Zone2"
        else
          dashboard_control_target="Main"
        fi
        _denon_dashboard_add_event "Key: Control Target: $dashboard_control_target"
        dashboard_resize_pending=0
        "${dashboard_redraw_cmd:-_denon_dashboard_redraw}"
        ;;
      digit_*)
        _denon_dashboard_handle_digit "${action#digit_}"
        ;;
      *)
        key_event=$(_denon_dashboard_key_event_name "$action")
        _denon_dashboard_add_event "Key: $key_event"
        if ! _denon_dashboard_throttle_allows_command; then
          _denon_dashboard_is_transport_action "$action" &&
            _denon_dashboard_add_event "Transport command throttled: $(_denon_dashboard_command_event_name "$action")"
          return 0
        fi
        if _denon_dashboard_is_transport_action "$action"; then
          _denon_dashboard_run_transport_action "$action" >/dev/null 2>&1 || true
          case "${dashboard_transport_result:-}" in
            verified)
              _denon_dashboard_add_event "Transport command sent: $(_denon_dashboard_transport_event_name "$action")"
              _denon_dashboard_add_event "Transport verified: $(_denon_dashboard_transport_event_name "$action")"
              ;;
            sent-unverified)
              _denon_dashboard_add_event "Transport command sent: $(_denon_dashboard_transport_event_name "$action"); no playback change verified"
              ;;
            no-player)
              _denon_dashboard_add_event "Transport command unavailable: no HEOS player for receiver"
              ;;
            failed)
              _denon_dashboard_add_event "Transport command failed: $(_denon_dashboard_command_event_name "$action")"
              ;;
            *)
              _denon_dashboard_add_command_warning "$action"
              ;;
          esac
        elif _denon_dashboard_run_action "$action" >/dev/null 2>&1; then
          :
        else
          _denon_dashboard_add_command_warning "$action"
        fi
        ;;
    esac
  }

  _denon_dashboard_poll_key() {
    local timeout="$1"
    local key=""
    local rest=""

    [[ -t 0 ]] || return 1
    if IFS= read -rsn1 -t "$timeout" key 2>/dev/null; then
      if [[ "$key" == $'\033' ]]; then
        IFS= read -rsn2 -t 0.05 rest 2>/dev/null || rest=""
        key="$key$rest"
      fi
      _denon_dashboard_handle_key "$key"
      return 0
    fi
    return 1
  }

  _denon_dashboard_sleep_or_resize() {
    local remaining="$1"
    local chunk

    if ! awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; then
      _denon_dashboard_poll_key 0.200 || true
      _denon_dashboard_flush_numeric_if_expired
      return 0
    fi
    while [[ "${dashboard_stop_pending:-0}" != "1" ]] && awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; do
      if [[ "${dashboard_resize_pending:-0}" == "1" ]]; then
        dashboard_resize_pending=0
        "${dashboard_redraw_cmd:-_denon_dashboard_redraw}"
      fi
      chunk=$(awk -v remaining="$remaining" 'BEGIN { if (remaining < 0.2) printf "%.3f", remaining; else printf "0.200" }')
      if [[ -t 0 ]]; then
        _denon_dashboard_poll_key "$chunk" || true
        _denon_dashboard_flush_numeric_if_expired
        [[ "${dashboard_stop_pending:-0}" == "1" ]] && break
      else
        _denon_dashboard_flush_numeric_if_expired
        sleep "$chunk" 2>/dev/null || true
      fi
      remaining=$(awk -v remaining="$remaining" -v chunk="$chunk" 'BEGIN { remaining -= chunk; if (remaining < 0) remaining=0; printf "%.3f", remaining }')
    done
  }

  _denon_dashboard() {
    local watch=0
    local interval=5
    local arg
    local dashboard_initialized=0
    # shellcheck disable=SC2034 # Retained with the event state block for dashboard state tracking.
    local previous_dashboard_key=""
    local dashboard_events=""
    local last_dashboard_event=""
    # shellcheck disable=SC2034 # Some previous-state fields are retained for stable dashboard event tracking.
    local prev_main_power="" prev_main_source="" prev_main_source_index="" prev_main_muted="" prev_main_volume=""
    local prev_sound_mode=""
    # shellcheck disable=SC2034 # Some previous-state fields are retained for stable dashboard event tracking.
    local prev_zone2_power="" prev_zone2_source="" prev_zone2_source_index="" prev_zone2_muted="" prev_now_title=""
    local prev_transport_state=""
    local dashboard_color_mode="auto"
    local dashboard_use_color=0
    local dash_c_reset="" dash_c_dim="" dash_c_green="" dash_c_yellow="" dash_c_red=""
    local dashboard_resize_pending=0
    local dashboard_stop_pending=0
    local dashboard_exit_status=0
    local dashboard_diagnostics=0
    local dashboard_saved_stty=""
    local dashboard_terminal_active=0
    local dashboard_keyboard_active=0
    local dashboard_control_target="Main"
    local dashboard_last_command_ms=""
    local dashboard_command_throttle_ms=200
    local dashboard_numeric_buffer=""
    local dashboard_numeric_deadline_ms=""
    local dashboard_numeric_timeout_ms=750

    dashboard_ascii=0
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *UTF-8*|*utf8*|*UTF8*) dashboard_ascii=0 ;;
      *) dashboard_ascii=1 ;;
    esac
    [[ "${DENON_DASHBOARD_ASCII:-0}" == "1" ]] && dashboard_ascii=1

    while [[ $# -gt 0 ]]; do
      arg="$1"
      case "$arg" in
        watch|--watch|-w)
          watch=1
          shift
          if [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            interval="$1"
            shift
          fi
          ;;
        once|--once)
          watch=0
          shift
          ;;
        --interval|-n)
          if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "Usage: denon dashboard [--diagnostics] [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]" >&2
            return 1
          fi
          watch=1
          interval="$2"
          shift 2
          ;;
        --ascii)
          dashboard_ascii=1
          shift
          ;;
        --unicode)
          dashboard_ascii=0
          shift
          ;;
        --diagnostics|--verbose|--details)
          dashboard_diagnostics=1
          shift
          ;;
        --color)
          case "$(_denon_lower "${2:-}")" in
            auto|always|never)
              dashboard_color_mode=$(_denon_lower "$2")
              shift 2
              ;;
            *)
              echo "Usage: denon dashboard [--diagnostics] [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]" >&2
              return 1
              ;;
          esac
          ;;
        [0-9]*)
          watch=1
          interval="$arg"
          shift
          ;;
        *)
          echo "Usage: denon dashboard [--diagnostics] [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]" >&2
          return 1
          ;;
      esac
    done

    if [[ "$watch" == "1" ]]; then
      trap 'dashboard_resize_pending=1' WINCH
      trap 'dashboard_stop_pending=1; dashboard_exit_status=130; _denon_dashboard_restore_terminal' INT TERM HUP
      if [[ -t 0 ]]; then
        dashboard_saved_stty=$(stty -g 2>/dev/null || printf '')
        if [[ -n "$dashboard_saved_stty" ]]; then
          if stty -echo -icanon min 0 time 0 2>/dev/null; then
            dashboard_terminal_active=1
            dashboard_keyboard_active=1
          fi
        fi
      fi
      printf '\033[?25l'
      while [[ "$dashboard_stop_pending" != "1" ]]; do
        local poll_start poll_end poll_elapsed poll_sleep
        poll_start=$(date +%s)
        _denon_dashboard_collect
        [[ "$dashboard_stop_pending" == "1" ]] && break
        _denon_dashboard_update_events
        dashboard_resize_pending=0
        _denon_dashboard_redraw
        poll_end=$(date +%s)
        poll_elapsed=$((poll_end - poll_start))
        poll_sleep=$(awk -v interval="$interval" -v elapsed="$poll_elapsed" 'BEGIN { sleep_for=interval-elapsed; if (sleep_for < 0) sleep_for=0; printf "%.3f", sleep_for }')
        _denon_dashboard_sleep_or_resize "$poll_sleep"
      done
      _denon_dashboard_restore_terminal
      trap - WINCH INT TERM HUP
      return "$dashboard_exit_status"
    fi

    _denon_dashboard_collect
    _denon_dashboard_update_events
    _denon_dashboard_render
  }

  # ── dashboard-ultra (alternate ultrawide dashboard) ───────────────────────
  # Self-contained alternate to `denon dashboard`. Owns its collection
  # (batched AppCommand POSTs plus one pipelined telnet session), layout, and
  # watch loop; reuses only the stable dashboard's pure rendering/parsing
  # helpers so the original code paths stay untouched.

  _denon_udash_appcommand_batch() {
    # POST one batched AppCommand request. The goform daemon handles large
    # batches fine but wedges under rapid successive POSTs, so callers send
    # at most one batch per refresh cycle. The firmware's XML parser silently
    # returns an empty <rx> unless a newline follows the XML declaration.
    local verb body
    body='<?xml version="1.0" encoding="utf-8"?>'$'\n''<tx>'
    for verb in "$@"; do
      body="${body}<cmd id=\"1\">${verb}</cmd>"
    done
    body="${body}</tx>"
    command -v curl >/dev/null 2>&1 || return 1
    # Plain-HTTP goform endpoint: no TLS args, and a longer max-time than the
    # shared _denon_curl wrapper so the larger batched response isn't truncated
    # mid-stream (GetChLevel alone is ~2 KB).
    _denon_debug "udash appcommand batch ($# verbs)"
    curl -sS --connect-timeout "${DENON_CURL_CONNECT_TIMEOUT:-2}" \
      --max-time "${DENON_UDASH_CURL_MAX_TIME:-10}" \
      -X POST -H 'Content-Type: text/xml' --data-binary "$body" \
      "http://${IP}:8080/goform/AppCommand.xml" 2>/dev/null
  }

  _denon_udash_appcmd_block() {
    # Extract the Nth top-level <cmd>/<error> response block (1-based).
    # Responses carry no verb echo, so position must match the request order.
    local xml="$1"
    local want="$2"

    printf '%s\n' "$xml" | awk -v want="$want" '
      /^[[:space:]]*<cmd>/ { idx++ }
      /^[[:space:]]*<error>/ { idx++ }
      idx == want { print }
      /^[[:space:]]*<\/cmd>/ { if (idx == want) exit }
    '
  }

  _denon_udash_appcmd_tail() {
    # Strip the first N top-level <cmd>/<error> blocks from a response so the
    # remainder can be parsed positionally starting from index 1.
    local xml="$1"
    local skip="$2"

    printf '%s\n' "$xml" | awk -v skip="$skip" '
      /^[[:space:]]*<cmd>/ { idx++ }
      /^[[:space:]]*<error>/ { idx++ }
      idx > skip { print }
    '
  }

  _denon_udash_zone_block() {
    local xml="$1"
    local zone="$2"

    printf '%s\n' "$xml" | awk -v open="<${zone}>" -v close_tag="</${zone}>" '
      index($0, open) { inblk = 1 }
      inblk { print }
      index($0, close_tag) { if (inblk) exit }
    '
  }

  _denon_udash_chlevel_rows() {
    # Emit "name<TAB>level" for every configured channel in a GetChLevel block.
    printf '%s\n' "$1" | awk '
      /<ch>/ { name = ""; status = ""; level = "" }
      /<name>/ { gsub(/.*<name>|<\/name>.*/, ""); name = $0 }
      /<status>/ { if (name != "") { gsub(/.*<status>|<\/status>.*/, ""); status = $0 } }
      /<level>/ { gsub(/.*<level>|<\/level>.*/, ""); level = $0 }
      /<\/ch>/ { if (name != "" && status == "1") printf "%s\t%s\n", name, level }
    '
  }

  _denon_udash_power_label() {
    case "$(_denon_lower "$(_denon_trim "$1")")" in
      on) echo "On" ;;
      off) echo "Off" ;;
      standby) echo "Standby" ;;
      "") echo "Unknown" ;;
      *) _denon_trim "$1" ;;
    esac
  }

  _denon_udash_sleep_label() {
    local value
    value=$(_denon_trim "$1")
    case "$(_denon_lower "$value")" in
      "") echo "Unknown" ;;
      off) echo "Off" ;;
      *)
        if [[ "$value" =~ ^[0-9]+$ ]]; then
          printf '%s min\n' "$(printf '%s' "$value" | sed 's/^0*\([0-9]\)/\1/')"
        else
          printf '%s\n' "$value"
        fi
        ;;
    esac
  }

  _denon_udash_tone_db() {
    # PSBAS/PSTRE raw values are centered on 50 (50 = 0 dB).
    local raw
    raw=$(_denon_trim "$1")
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      awk -v v="$raw" 'BEGIN { printf "%+g dB", v - 50 }'
    else
      printf 'Unknown'
    fi
  }

  _denon_udash_eco_label() {
    case "$(_denon_lower "$(_denon_trim "$1")")" in
      on) echo "On" ;;
      auto) echo "Auto" ;;
      off) echo "Off" ;;
      "") echo "Unknown" ;;
      *) _denon_trim "$1" ;;
    esac
  }

  _denon_udash_dimmer_label() {
    case "$(_denon_lower "$(_denon_trim "$1")")" in
      bri) echo "Bright" ;;
      dim) echo "Dim" ;;
      dar) echo "Dark" ;;
      off) echo "Off" ;;
      "") echo "Unknown" ;;
      *) _denon_trim "$1" ;;
    esac
  }

  _denon_udash_signal_label() {
    # SSINFAISSIG input-signal codes (only proven mappings; others stay raw).
    case "$(_denon_trim "$1")" in
      01) echo "Analog" ;;
      02) echo "PCM" ;;
      "") echo "Unknown" ;;
      *) printf 'code %s\n' "$(_denon_trim "$1")" ;;
    esac
  }

  _denon_udash_sample_rate_label() {
    local value
    value=$(_denon_trim "$1")
    if [[ -z "$value" ]]; then
      echo "Unknown"
    else
      printf '%s\n' "$value" | sed 's/K$/ kHz/'
    fi
  }

  _denon_udash_titlecase_onoff() {
    case "$(_denon_lower "$(_denon_trim "$1")")" in
      on) echo "On" ;;
      off) echo "Off" ;;
      "") echo "Unknown" ;;
      *) _denon_trim "$1" ;;
    esac
  }

  _denon_udash_lfe_label() {
    # PSLFE raw values are attenuation steps: 00 = 0 dB, 05 = -5 dB.
    local raw
    raw=$(_denon_trim "$1")
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      awk -v v="$raw" 'BEGIN { printf "%d dB", -v }'
    else
      printf 'Unknown'
    fi
  }

  _denon_udash_telnet_pipeline() {
    # One nc session carrying all telnet queries; replies are prefix-tagged so
    # they can be demuxed afterwards. MS? also emits SYSMI/SYSDA/OPINF/PS*
    # bonus events on this firmware.
    local cmd
    command -v nc >/dev/null 2>&1 || return 1
    {
      for cmd in 'MS?' 'SSINFAISSIG ?' 'SSINFAISFSV ?' 'SLP?' 'Z2SLP?' 'PSBAS ?' 'PSTRE ?' 'ECO?' 'DIM ?'; do
        printf '%s\r' "$cmd"
        sleep 0.15
      done
      sleep 0.4
    } | nc -w 3 "$IP" 23 2>/dev/null
  }

  _denon_udash_parse_telnet() {
    local text="$1"
    local line value

    text=${text//$'\r'/$'\n'}
    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      case "$line" in
        SYSMI*)
          value=$(_denon_trim "${line#SYSMI}")
          [[ -n "$value" ]] && dash_sound_mode="$value"
          ;;
        SYSDA*)
          value=$(_denon_trim "${line#SYSDA}")
          [[ -n "$value" ]] && dash_u_signal="$value"
          ;;
        SSINFAISSIG*) dash_u_signal_code=$(_denon_trim "${line#SSINFAISSIG}") ;;
        SSINFAISFSV*) dash_u_sample_rate=$(_denon_trim "${line#SSINFAISFSV}") ;;
        Z2SLP*) dash_u_sleep_zone2=$(_denon_trim "${line#Z2SLP}") ;;
        SLP*) dash_u_sleep_main=$(_denon_trim "${line#SLP}") ;;
        "PSTONE CTRL"*) dash_u_tone_ctrl=$(_denon_trim "${line#PSTONE CTRL}") ;;
        PSBAS*) dash_u_bass_raw=$(_denon_trim "${line#PSBAS}") ;;
        PSTRE*) dash_u_treble_raw=$(_denon_trim "${line#PSTRE}") ;;
        PSDRC*) dash_u_drc=$(_denon_trim "${line#PSDRC}") ;;
        PSLFE*) dash_u_lfe=$(_denon_trim "${line#PSLFE}") ;;
        ECO*) dash_u_eco=$(_denon_trim "${line#ECO}") ;;
        DIM*) dash_u_dimmer=$(_denon_trim "${line#DIM}") ;;
        MS*)
          if [[ "$dash_sound_mode" == "Unknown" ]]; then
            value=$(_denon_trim "${line#MS}")
            [[ -n "$value" ]] && dash_sound_mode="$value"
          fi
          ;;
      esac
    done <<<"$text"
  }

  _denon_udash_parse_appcmd1() {
    # Request order: GetAllZonePowerStatus GetAllZoneSource GetAllZoneVolume
    #                GetAllZoneMuteStatus GetSurroundModeStatus GetAutoStandby
    #                GetZoneName
    local resp="$1"
    local block zb value

    block=$(_denon_udash_appcmd_block "$resp" 1)
    value=$(_denon_dashboard_xml_value "$block" "zone1")
    [[ -n "$value" ]] && dash_main_power=$(_denon_udash_power_label "$value")
    value=$(_denon_dashboard_xml_value "$block" "zone2")
    [[ -n "$value" ]] && dash_zone2_power=$(_denon_udash_power_label "$value")

    block=$(_denon_udash_appcmd_block "$resp" 2)
    zb=$(_denon_udash_zone_block "$block" "zone1")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "source")")
    [[ -n "$value" ]] && dash_main_source=$(_denon_clean_source_name "$value")
    zb=$(_denon_udash_zone_block "$block" "zone2")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "source")")
    [[ -n "$value" ]] && dash_zone2_source=$(_denon_clean_source_name "$value")

    block=$(_denon_udash_appcmd_block "$resp" 3)
    zb=$(_denon_udash_zone_block "$block" "zone1")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "volume")")
    [[ -n "$value" ]] && dash_main_volume="$value"
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "limit")")
    case "$(_denon_lower "$value")" in
      ""|off) dash_main_max_volume_db="" ;;
      *) dash_main_max_volume_db="$value" ;;
    esac
    zb=$(_denon_udash_zone_block "$block" "zone2")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "volume")")
    [[ -n "$value" ]] && dash_zone2_volume_db="$value"
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "dispvalue")")
    [[ -n "$value" ]] && dash_zone2_volume_raw="$value"
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$zb" "limit")")
    case "$(_denon_lower "$value")" in
      ""|off) dash_u_zone2_limit="" ;;
      *) dash_u_zone2_limit="$value" ;;
    esac

    block=$(_denon_udash_appcmd_block "$resp" 4)
    value=$(_denon_dashboard_xml_value "$block" "zone1")
    [[ -n "$value" ]] && dash_main_muted=$(_denon_normalize_mute "$value")
    value=$(_denon_dashboard_xml_value "$block" "zone2")
    [[ -n "$value" ]] && dash_zone2_muted=$(_denon_normalize_mute "$value")

    block=$(_denon_udash_appcmd_block "$resp" 5)
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "surround")")
    [[ -n "$value" ]] && dash_sound_mode="$value"

    block=$(_denon_udash_appcmd_block "$resp" 6)
    if [[ -n "$block" && "$block" != *"<error>"* ]]; then
      value=$(printf '%s\n' "$block" | awk '
        /<zone>/ { gsub(/.*<zone>|<\/zone>.*/, ""); zone = $0 }
        /<value>/ {
          gsub(/.*<value>|<\/value>.*/, "")
          label = ($0 == "0" ? "Off" : "Lv " $0)
          out = out (out == "" ? "" : " / ") zone " " label
        }
        END { print out }')
      [[ -n "$value" ]] && dash_u_standby="$value"
    fi

    block=$(_denon_udash_appcmd_block "$resp" 7)
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "zone1")")
    [[ -n "$value" ]] && dash_main_zone_name="$value"
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "zone2")")
    [[ -n "$value" ]] && dash_zone2_name="$value"
  }

  _denon_udash_parse_appcmd2() {
    # Request order: GetToneControl GetDialogLevel GetSubwooferLevel
    #                GetChLevel GetAllZoneStereo
    local resp="$1"
    local block value status
    local ch_rows ch_name ch_level part1 part2 idx active_count sw_active

    block=$(_denon_udash_appcmd_block "$resp" 1)
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "status")")
    case "$value" in
      0) dash_u_tone_status="Off" ;;
      1) dash_u_tone_status="On" ;;
    esac

    block=$(_denon_udash_appcmd_block "$resp" 2)
    status=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "status")")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "level")")
    if [[ "$status" == "1" && -n "$value" ]]; then
      dash_u_dialog=$(printf '%s\n' "$value" | sed 's/dB$/ dB/')
    elif [[ "$status" == "0" ]]; then
      dash_u_dialog="Off"
    fi

    block=$(_denon_udash_appcmd_block "$resp" 3)
    status=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "status")")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "sw1level")")
    if [[ "$status" == "0" ]]; then
      dash_u_sub="None"
    elif [[ -n "$value" ]]; then
      dash_u_sub=$(printf '%s\n' "$value" | sed 's/dB$/ dB/')
    fi

    block=$(_denon_udash_appcmd_block "$resp" 4)
    if [[ -n "$block" && "$block" != *"<error>"* ]]; then
      ch_rows=$(_denon_udash_chlevel_rows "$block")
      part1=""
      part2=""
      idx=0
      active_count=0
      sw_active=0
      while IFS=$'\t' read -r ch_name ch_level; do
        [[ -n "$ch_name" ]] || continue
        ch_level=${ch_level%dB}
        if [[ "$ch_name" == SW* ]]; then
          sw_active=1
        else
          active_count=$((active_count + 1))
        fi
        idx=$((idx + 1))
        if (( idx <= 3 )); then
          part1="${part1}${part1:+  }${ch_name} ${ch_level}"
        else
          part2="${part2}${part2:+  }${ch_name} ${ch_level}"
        fi
      done <<<"$ch_rows"
      if (( idx > 0 )); then
        dash_u_chlevels_line1="$part1"
        dash_u_chlevels_line2="$part2"
        dash_u_speaker_config="${active_count}.${sw_active}"
      fi
    fi

    block=$(_denon_udash_appcmd_block "$resp" 5)
    status=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "status")")
    value=$(_denon_trim "$(_denon_dashboard_xml_value "$block" "value")")
    if [[ -n "$status" ]]; then
      case "$value" in
        0) dash_u_azs="Off" ;;
        1) dash_u_azs="On" ;;
      esac
    fi
  }

  _denon_udash_tv_output_label() {
    # webOS getSoundOutput codes -> readable labels. The value is whatever
    # the TV itself reports; unknown codes pass through raw.
    case "$(_denon_trim "$1")" in
      tv_speaker) echo "TV Speaker" ;;
      tv_external_speaker) echo "TV Speaker + External" ;;
      external_arc) echo "HDMI ARC" ;;
      external_optical) echo "Optical" ;;
      external_speaker) echo "External Speaker" ;;
      bt_soundbar|soundbar) echo "Soundbar" ;;
      lineout) echo "Line Out" ;;
      headphone) echo "Headphone" ;;
      "") echo "Unknown" ;;
      *) _denon_trim "$1" ;;
    esac
  }

  _denon_udash_tv_probe() {
    # Prints three pre-parsed lines: power, volume, audio output.
    local power_line vol_line out_line

    power_line=$(timeout 4 lgtv power status 2>/dev/null | sed -n '1p')
    case "$power_line" in
      *"is ON"*) power_line="On" ;;
      *"is OFF"*) power_line="Off" ;;
      "") power_line="Unreachable" ;;
    esac
    vol_line=$(timeout 4 lgtv volume status 2>/dev/null | sed -n 's/^Volume: //p' | sed -n '1p')
    out_line=$(timeout 4 lgtv audio status 2>/dev/null | sed -n "s/.*<AudioOutputSource '\([^']*\)'>.*/\1/p" | sed -n '1p')
    if [[ -z "$out_line" ]]; then
      out_line=$(timeout 4 lgtv info current 2>/dev/null | sed -n "s/.*AudioOutputSource '\([^']*\)'.*/\1/p" | sed -n '1p')
    fi
    out_line=$(_denon_udash_tv_output_label "$out_line")
    printf '%s\n%s\n%s\n' "$power_line" "${vol_line:-Unknown}" "$out_line"
  }

  _denon_udash_starred_source() {
    # Print "index<TAB>name" for the starred (active) entry of a sources
    # listing. The renamed label here is what the stable dashboard displays
    # (e.g. "TV Audio"), unlike the raw appcommand id ("TV").
    local text="$1"
    local line idx name

    while IFS= read -r line; do
      line=$(_denon_trim "$line")
      [[ "${line:0:1}" == "*" ]] || continue
      line=$(_denon_trim "${line:1}")
      idx=${line%%[[:space:]]*}
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      name=$(_denon_clean_source_name "${line#"$idx"}")
      [[ -n "$name" ]] || continue
      printf '%s\t%s\n' "$idx" "$name"
      return 0
    done <<<"$text"
    return 1
  }

  _denon_udash_collect_fallback() {
    # AppCommand path failed: reuse the stable dashboard's proven fetchers
    # (info JSON / pretty status / get_config) so the core zone fields still
    # show the same data `denon dashboard` displays.
    # shellcheck disable=SC2034 # info_ok is read/written by the shared fetch helper.
    local info_ok=0
    local zone_names_xml vol_xml raw_mute mute_from_vol

    _denon_dashboard_fetch_core_status

    zone_names_xml=$(_denon_get_config 6 2>/dev/null)
    [[ -n "$zone_names_xml" ]] && _denon_dashboard_parse_zone_names "$zone_names_xml"

    vol_xml=$(_denon_get_vol_xml 2>/dev/null)
    if [[ -n "$vol_xml" ]]; then
      _denon_dashboard_parse_volume_details "$vol_xml"
      raw_mute=$(_denon_resolve_main_mute "$(_denon_extract_main_mute "$vol_xml")")
      mute_from_vol=$(_denon_normalize_mute "$raw_mute")
      [[ "$mute_from_vol" != "Unknown" ]] && dash_main_muted="$mute_from_vol"
    fi
  }

  _denon_udash_copy_data_field() {
    local group="$1"
    local field="$2"
    local var="$3"
    local value

    value=$(_denon_data_record_value "$group" "$field" 2>/dev/null || printf '')
    [[ -n "$value" ]] || return 0
    printf -v "$var" '%s' "$value"
  }

  _denon_udash_collect_data_fields() {
    # The summary collector fires ~39 telnet one-shot probes, each waiting out
    # the full avr_send reply window (default 1s). The AVR answers well under
    # 0.3s, so scope a shorter window to these probes via dynamic scoping.
    # An explicit DENON_UDASH_SEND_TIMEOUT or DENON_SEND_TIMEOUT still wins;
    # other CLI commands keep the safer 1s default.
    local DENON_SEND_TIMEOUT="${DENON_UDASH_SEND_TIMEOUT:-${DENON_SEND_TIMEOUT:-0.3}}"
    _denon_data_collect_summary >/dev/null 2>&1 || return 1

    _denon_udash_copy_data_field "tone_audyssey" "dynamic_eq" "dash_u_dynamic_eq"
    _denon_udash_copy_data_field "tone_audyssey" "dynamic_volume" "dash_u_dynamic_volume"
    _denon_udash_copy_data_field "tone_audyssey" "multeq" "dash_u_multeq"
    _denon_udash_copy_data_field "tone_audyssey" "cinema_eq" "dash_u_cinema_eq"
    _denon_udash_copy_data_field "tone_audyssey" "loudness_management" "dash_u_loudness_management"
    _denon_udash_copy_data_field "tone_audyssey" "subwoofer_level_db" "dash_u_subwoofer_level_db"
    _denon_udash_copy_data_field "network_heos" "heos_volume_level" "dash_u_heos_volume_level"
    _denon_udash_copy_data_field "receiver" "brand_code" "dash_u_brand_code"
    _denon_udash_copy_data_field "receiver" "model_type" "dash_u_model_type"
    _denon_udash_copy_data_field "main_zone" "volume_scale" "dash_u_main_volume_scale"
    _denon_udash_copy_data_field "main_zone" "volume_limit_raw" "dash_u_main_volume_limit_raw"
    _denon_udash_copy_data_field "zone2" "volume_scale" "dash_u_zone2_volume_scale"
    _denon_udash_copy_data_field "zone2" "volume_limit_raw" "dash_u_zone2_volume_limit_raw"
    _denon_udash_copy_data_field "upnp" "aios_firmware" "dash_u_aios_firmware"
    _denon_udash_copy_data_field "upnp" "serial_number" "dash_u_serial_number"
    _denon_udash_copy_data_field "upnp" "upnp_mac" "dash_u_upnp_mac"
    _denon_udash_copy_data_field "upnp" "comm_api_vers" "dash_u_comm_api_vers"
    _denon_udash_copy_data_field "upnp" "device_zones" "dash_u_device_zones"
    _denon_udash_copy_data_field "upnp" "upnp_model" "dash_u_upnp_model"
    _denon_udash_copy_data_field "upnp" "udn" "dash_u_udn"
    _denon_udash_copy_data_field "upnp" "pending_upgrade_version" "dash_u_pending_upgrade_version"
    _denon_udash_copy_data_field "system" "setup_lock" "dash_u_setup_lock"
    _denon_udash_copy_data_field "system" "menu_lock" "dash_u_menu_lock"
    _denon_udash_copy_data_field "system" "advanced_mode" "dash_u_advanced_mode"
    _denon_udash_copy_data_field "system" "ci_mode" "dash_u_ci_mode"
    _denon_udash_copy_data_field "system" "gui_type" "dash_u_gui_type"
    _denon_udash_copy_data_field "system" "webui_type" "dash_u_webui_type"
    _denon_udash_copy_data_field "system" "heos_sign_in" "dash_u_heos_sign_in"
    _denon_udash_copy_data_field "system" "speaker_preset" "dash_u_speaker_preset"
    _denon_udash_copy_data_field "system" "product_type" "dash_u_product_type"
    _denon_udash_copy_data_field "system" "bt_headphones_single_used" "dash_u_bt_headphones_single_used"
  }

  _denon_udash_collect() {
    local resp1 resp2 telnet_text telnet_file telnet_pid tv_file tv_pid
    local identity_xml now_text now_rc sources_text zone2_sources_text heos_text value vol_xml

    dash_receiver="Unknown"
    dash_ip="${IP:-Unknown}"
    dash_main_zone_name="Main Zone"
    dash_main_power="Unknown"
    dash_main_source="Unknown"
    dash_main_source_index=""
    dash_main_volume="Unknown"
    dash_main_max_volume_db=""
    dash_main_muted="Unknown"
    dash_sound_mode="Unknown"
    dash_transport_state=""
    dash_heos_pid=""
    dash_heos_model=""
    dash_heos_version=""
    dash_heos_network=""
    dash_zone2_name="Zone 2"
    dash_zone2_power="Unknown"
    dash_zone2_source="Unknown"
    dash_zone2_source_index=""
    dash_zone2_volume="Unknown"
    dash_zone2_volume_db=""
    dash_zone2_volume_raw=""
    dash_zone2_muted="Unknown"
    dash_now_message=$(_denon_display_empty_message no-metadata)
    dash_now_title=""
    dash_now_artist=""
    dash_now_album=""
    dash_now_station=""
    dash_now_service=""
    # shellcheck disable=SC2034 # Kept with the now-playing state vector for render helpers.
    dash_now_type=""
    dash_now_available=0
    dash_errors=""
    dash_main_sources=$(_denon_display_empty_message no-sources)

    dash_u_signal=""
    dash_u_signal_code=""
    dash_u_sample_rate=""
    dash_u_sleep_main=""
    dash_u_sleep_zone2=""
    dash_u_bass_raw=""
    dash_u_treble_raw=""
    dash_u_drc=""
    dash_u_lfe=""
    dash_u_tone_ctrl=""
    dash_u_eco=""
    dash_u_dimmer=""
    dash_u_tone_status=""
    dash_u_dialog="Unknown"
    dash_u_sub="Unknown"
    dash_u_chlevels_line1=""
    dash_u_chlevels_line2=""
    dash_u_speaker_config=""
    dash_u_azs="Unknown"
    dash_u_standby="Unknown"
    dash_u_zone2_limit=""
    dash_u_dynamic_eq=""
    dash_u_dynamic_volume=""
    dash_u_multeq=""
    dash_u_cinema_eq=""
    dash_u_loudness_management=""
    dash_u_subwoofer_level_db=""
    dash_u_heos_volume_level=""
    dash_u_brand_code=""
    dash_u_model_type=""
    dash_u_main_volume_scale=""
    dash_u_main_volume_limit_raw=""
    dash_u_zone2_volume_scale=""
    dash_u_zone2_volume_limit_raw=""
    dash_u_aios_firmware=""
    dash_u_serial_number=""
    dash_u_upnp_mac=""
    dash_u_comm_api_vers=""
    dash_u_device_zones=""
    dash_u_upnp_model=""
    dash_u_udn=""
    dash_u_pending_upgrade_version=""
    dash_u_setup_lock=""
    dash_u_menu_lock=""
    dash_u_advanced_mode=""
    dash_u_ci_mode=""
    dash_u_gui_type=""
    dash_u_webui_type=""
    dash_u_heos_sign_in=""
    dash_u_speaker_preset=""
    dash_u_product_type=""
    dash_u_bt_headphones_single_used=""
    udash_tv_body=""

    telnet_pid=""
    telnet_file=$(mktemp "${TMPDIR:-/tmp}/denon-udash-telnet.XXXXXX" 2>/dev/null) || telnet_file=""
    if [[ -n "$telnet_file" ]]; then
      _denon_udash_telnet_pipeline >"$telnet_file" 2>/dev/null &
      telnet_pid=$!
    fi

    tv_pid=""
    tv_file=""
    if [[ "${udash_tv:-0}" == "1" ]] && command -v lgtv >/dev/null 2>&1; then
      tv_file=$(mktemp "${TMPDIR:-/tmp}/denon-udash-tv.XXXXXX" 2>/dev/null) || tv_file=""
      if [[ -n "$tv_file" ]]; then
        _denon_udash_tv_probe >"$tv_file" 2>/dev/null &
        tv_pid=$!
      fi
    fi

    # The goform daemon accepts at most five <cmd> entries per AppCommand
    # POST: six answer <error>1</error> and seven or more wedge the daemon
    # (connection refused for ~50s), which is what blanked every appcommand
    # field in watch mode. Send three small batches in the original verb
    # order and join the responses so the positional parsers still see the
    # 12-block layout; a failed batch is padded with one <error> line per
    # verb to keep later block positions aligned.
    local batch batch_resp pad verb ok_batches=0 core_ok=0
    resp1=""
    for batch in \
      'GetAllZonePowerStatus GetAllZoneSource GetAllZoneVolume GetAllZoneMuteStatus' \
      'GetSurroundModeStatus GetAutoStandby GetZoneName GetToneControl' \
      'GetDialogLevel GetSubwooferLevel GetChLevel GetAllZoneStereo'; do
      [[ -n "$resp1" ]] && sleep 0.2
      # shellcheck disable=SC2086 # batch is a deliberate space-separated verb list
      batch_resp=$(_denon_udash_appcommand_batch $batch)
      if [[ "$batch_resp" == *"<rx>"* ]]; then
        ok_batches=$((ok_batches + 1))
        [[ "$batch" == GetAllZonePowerStatus* ]] && core_ok=1
        resp1="${resp1}"$'\n'"${batch_resp}"
      else
        pad=""
        for verb in $batch; do pad="${pad}<error>9</error>"$'\n'; done
        resp1="${resp1}"$'\n'"${pad}"
      fi
    done
    if (( ok_batches > 0 )); then
      _denon_udash_parse_appcmd1 "$resp1"
      resp2=$(_denon_udash_appcmd_tail "$resp1" 7)
      _denon_udash_parse_appcmd2 "$resp2"
    fi
    if (( ! core_ok )); then
      if (( ok_batches > 0 )); then
        dash_errors="${dash_errors}appcommand status partial (fallback used); "
      else
        dash_errors="${dash_errors}appcommand status unavailable (fallback used); "
      fi
      _denon_udash_collect_fallback
    else
      # Volume details (main max, zone2 raw 0-98 scale) come from the same
      # XML the stable dashboard uses so both dashboards show identical
      # numbers; appcommand only reports the limit and the display value.
      vol_xml=$(_denon_get_vol_xml 2>/dev/null)
      [[ -n "$vol_xml" ]] && _denon_dashboard_parse_volume_details "$vol_xml"
    fi

    identity_xml=$(_denon_get_identity_xml 2>/dev/null)
    value=$(printf '%s' "$identity_xml" | sed -n 's:.*<FriendlyName>\([^<]*\)</FriendlyName>.*:\1:p' | sed -n '1p')
    [[ -n "$value" ]] && dash_receiver="$value"

    sources_text=$(_denon_sources 1 2>/dev/null)
    if [[ -n "$sources_text" ]]; then
      dash_main_sources=$(_denon_dashboard_sources_body "$sources_text")
      [[ -n "$(_denon_trim "$dash_main_sources")" ]] || dash_main_sources=$(_denon_display_empty_message no-sources)
      if value=$(_denon_udash_starred_source "$sources_text"); then
        dash_main_source_index=${value%%$'\t'*}
        dash_main_source=${value#*$'\t'}
      fi
    else
      dash_errors="${dash_errors}main sources unavailable; "
    fi

    zone2_sources_text=$(_denon_sources 2 2>/dev/null)
    if [[ -n "$zone2_sources_text" ]] && value=$(_denon_udash_starred_source "$zone2_sources_text"); then
      dash_zone2_source_index=${value%%$'\t'*}
      dash_zone2_source=${value#*$'\t'}
    fi

    now_text=$(_denon_track 2>&1)
    now_rc=$?
    _denon_dashboard_parse_now "$now_rc" "$now_text"

    if _denon_dashboard_is_heos_source; then
      heos_text=$(_denon_dashboard_heos_status)
    else
      heos_text=$(_denon_dashboard_heos_status players-only)
    fi
    [[ -n "$heos_text" ]] && _denon_dashboard_parse_heos_status "$heos_text"
    _denon_udash_collect_data_fields || dash_errors="${dash_errors}extended data unavailable; "

    if [[ -n "$telnet_pid" ]]; then
      wait "$telnet_pid" 2>/dev/null || true
      telnet_text=$(cat "$telnet_file" 2>/dev/null)
      rm -f "$telnet_file" 2>/dev/null
      [[ -n "$telnet_text" ]] && _denon_udash_parse_telnet "$telnet_text"
    fi

    if [[ -n "$tv_pid" ]]; then
      wait "$tv_pid" 2>/dev/null || true
      udash_tv_body=$(awk 'NR == 1 { printf "Power:   %s\n", $0 }
        NR == 2 { printf "Volume:  %s\n", $0 }
        NR == 3 { printf "Output:  %s\n", $0 }' "$tv_file" 2>/dev/null)
      rm -f "$tv_file" 2>/dev/null
    fi
    if [[ "${udash_tv:-0}" == "1" && -z "$udash_tv_body" ]]; then
      udash_tv_body="TV unreachable"
    fi
  }

  _denon_udash_two_col() {
    # Fold a single-column body into two columns of width $2 each.
    local body="$1"
    local colw="$2"

    printf '%s\n' "$body" | awk -v colw="$colw" '
      { lines[NR] = $0 }
      END {
        half = int((NR + 1) / 2)
        for (i = 1; i <= half; i++) {
          left = lines[i]
          right = (i + half <= NR) ? lines[i + half] : ""
          if (right == "") printf "%s\n", left
          else printf "%-*s  %s\n", colw, left, right
        }
      }'
  }

  _denon_udash_flow_columns() {
    # Flow a single-column body into $2 columns, column-major (column 1 holds
    # the first ceil(n/ncols) entries, column 2 the next, ...), padding every
    # non-final column on a row to width $3 with a two-space gutter. This is the
    # generalised form of _denon_udash_two_col: with ncols=1 the body is emitted
    # unchanged. Used to fill a finite-list panel's width instead of stacking
    # every entry in one tall column.
    local body="$1"
    local ncols="$2"
    local colw="$3"

    printf '%s\n' "$body" | awk -v ncols="$ncols" -v colw="$colw" '
      { lines[NR] = $0 }
      END {
        if (ncols < 1) ncols = 1
        rows = int((NR + ncols - 1) / ncols)
        if (rows < 1) rows = 1
        for (r = 1; r <= rows; r++) {
          lastc = -1
          for (c = 0; c < ncols; c++) if (c * rows + r <= NR) lastc = c
          out = ""
          for (c = 0; c <= lastc; c++) {
            idx = c * rows + r
            cell = (idx <= NR) ? lines[idx] : ""
            if (c < lastc) out = out sprintf("%-*s  ", colw, cell)
            else out = out cell
          }
          print out
        }
      }'
  }

  _denon_udash_field_tiers() {
    cat <<'EOF'
main|0|Power|dash_main_power
main|0|Source|dash_main_source
main|0|Volume|dash_u_main_volume_label
main|0|Muted|dash_u_main_muted_label
main|1|Mode|dash_sound_mode
main|1|Sleep|dash_u_sleep_main_label
main|1|Zone|dash_main_zone_name
zone2|0|Power|dash_zone2_power
zone2|0|Source|dash_zone2_source
zone2|0|Volume|dash_u_zone2_volume_label
zone2|1|Muted|dash_u_zone2_muted_label
zone2|1|Sleep|dash_u_sleep_zone2_label
audio|1|Signal|dash_u_signal_label
audio|1|Sample|dash_u_sample_rate_label
audio|1|Mode|dash_sound_mode
audio|1|LFE|dash_u_lfe_label
audio|2|Speakers|dash_u_speaker_config_label
audio|2|All-Zone|dash_u_azs
audio|2|DRC|dash_u_drc_label
tone|1|Bass|dash_u_bass_label
tone|1|Treble|dash_u_treble_label
tone|1|Sub|dash_u_sub
tone|1|Levels|dash_u_chlevels_line1
tone|1||dash_u_chlevels_line2
tone|2|Tone|dash_u_tone_status_label
tone|2|Dialog|dash_u_dialog
receiver|0|Receiver|dash_receiver
receiver|0|IP|dash_ip
receiver|0|Update|dash_u_pending_upgrade_alert
receiver|1|HEOS|dash_u_heos_label
receiver|1|Eco|dash_u_eco_label
receiver|1|Dimmer|dash_u_dimmer_label
receiver|1|Standby|dash_u_standby
receiver|3|Brand|dash_u_brand_code
receiver|3|Model Type|dash_u_model_type
receiver|3|Vol Scale|dash_u_main_volume_scale
now|0|Now|dash_u_now_parts
now|0|State|dash_u_state_label
now|1|Service|dash_now_service
now|1|Station|dash_now_station
now|2|Artist|dash_now_artist
now|2|Album|dash_now_album
dsp|2|Dynamic EQ|dash_u_dynamic_eq
dsp|2|Dynamic Vol|dash_u_dynamic_volume
dsp|2|MultEQ|dash_u_multeq
dsp|2|Cinema EQ|dash_u_cinema_eq
dsp|2|Loudness|dash_u_loudness_management
dsp|2|Subwoofer|dash_u_subwoofer_level_db
dsp|2|HEOS Vol|dash_u_heos_volume_level
firmware|3|AIOS FW|dash_u_aios_firmware
firmware|3|Serial|dash_u_serial_number
firmware|3|UPnP MAC|dash_u_upnp_mac
firmware|3|API|dash_u_comm_api_vers
firmware|3|Zones|dash_u_device_zones
firmware|3|Model|dash_u_upnp_model
firmware|3|UDN|dash_u_udn
firmware|3|Upgrade|dash_u_pending_upgrade_version
system|3|Setup Lock|dash_u_setup_lock
system|3|Menu Lock|dash_u_menu_lock
system|3|Advanced|dash_u_advanced_mode
system|3|CI Mode|dash_u_ci_mode
system|3|GUI|dash_u_gui_type
system|3|Web UI|dash_u_webui_type
system|3|HEOS Sign|dash_u_heos_sign_in
system|3|Preset|dash_u_speaker_preset
system|3|Product|dash_u_product_type
system|3|BT Phones|dash_u_bt_headphones_single_used
tv|1|Power|dash_u_tv_power
tv|1|Volume|dash_u_tv_volume
tv|1|Output|dash_u_tv_output
EOF
  }

  # System/Locks was retired from the layout. Recent Events is the full-width
  # growable bottom band at wide widths (cols >= 100) and is skipped from the
  # grid there (see _denon_udash_build_band); on narrow terminals there is no
  # band, so it stays a must-keep grid panel. Device/Firmware is an ordinary
  # fixed grid panel and keeps its natural height.
  _denon_udash_panel_tiers() {
    cat <<'EOF'
main|0|udash_main_title
zone2|0|udash_zone2_title
now|0|Now Playing
events|0|Recent Events
receiver|0|Receiver / Network
audio|1|Audio Signal
tone|1|Tone / Levels
sources|1|Sources (Main)
tv|1|TV (lgtv)
dsp|2|DSP / Audyssey
firmware|3|Device / Firmware
EOF
  }

  _denon_udash_label_line() {
    # Pad "label:" to $1 so every value in the panel starts at the same
    # column; an empty label is a continuation row and indents to that column.
    local width="$1"
    local label="$2"
    local value="$3"

    value=$(_denon_display_unknown "$value")
    if [[ -z "$label" ]]; then
      printf '%*s %s\n' "$width" '' "$value"
    else
      printf '%-*s %s\n' "$width" "${label}:" "$value"
    fi
  }

  _denon_udash_build_tier_body() {
    local panel="$1"
    local max_tier="$2"
    local max_body_lines="$3"
    local body="" line p tier label var value count=0 labelw=0 i
    local -a row_labels=() row_values=()

    # Pass 1: select the rows this panel will show and find the widest label,
    # so pass 2 can align every value to one per-panel column.
    while IFS='|' read -r p tier label var; do
      [[ "$p" == "$panel" ]] || continue
      (( tier <= max_tier )) || continue
      value="${!var:-}"
      [[ "$var" == "dash_u_pending_upgrade_alert" && -z "$value" ]] && continue
      row_labels+=("$label")
      row_values+=("$value")
      (( ${#label} + 1 > labelw )) && labelw=$(( ${#label} + 1 ))
      count=$((count + 1))
      (( count >= max_body_lines )) && break
    done < <(_denon_udash_field_tiers)

    for ((i = 0; i < count; i++)); do
      line=$(_denon_udash_label_line "$labelw" "${row_labels[$i]}" "${row_values[$i]}")
      body="${body}${body:+$'\n'}${line%$'\n'}"
    done

    printf '%s\n' "$body"
  }

  _denon_udash_compose_sources_body() {
    local width="$1"
    local max_body_lines="${2:-20}"
    local gutter=2
    local colw count=0 maxw=0 line linew content_w ncols rows_needed keep more i trunc
    local idxw=0 body=""
    local entry_re='^([* ])[[:space:]]*([0-9]+)[[:space:]]+(.*)$'
    local -a lines raw

    # Normalize "marker index name" entries so the marker keeps its own fixed
    # column and indices right-align: single- and double-digit indices must not
    # shift the names within a column.
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      raw+=("$line")
      if [[ "$line" =~ $entry_re ]]; then
        (( ${#BASH_REMATCH[2]} > idxw )) && idxw=${#BASH_REMATCH[2]}
      fi
    done <<<"$dash_main_sources"

    for line in "${raw[@]}"; do
      if [[ "$line" =~ $entry_re ]]; then
        line=$(printf '%s %*s %s' "${BASH_REMATCH[1]}" "$idxw" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
      fi
      lines+=("$line")
      body="${body}${body:+$'\n'}${line}"
      count=$((count + 1))
      linew=$(_denon_dashboard_display_width "$line")
      (( linew > maxw )) && maxw="$linew"
    done

    (( count > 0 )) || return 0
    (( max_body_lines < 1 )) && max_body_lines=1
    (( maxw < 1 )) && maxw=1

    # Sources is a FINITE list: never stack it in one tall column that wastes the
    # panel width and forces "+N more". Pick as many columns as the panel width
    # admits (longest entry + gutter), then flow column-major so the whole list
    # is shown in the fewest rows. This drives the panel's content-based minimum
    # height; the planner sizes the row to it before any slack is distributed.
    content_w=$((width - 4))
    (( content_w < maxw )) && content_w="$maxw"
    ncols=$(( (content_w + gutter) / (maxw + gutter) ))
    (( ncols < 1 )) && ncols=1
    (( ncols > count )) && ncols="$count"
    colw=$(( (content_w - gutter * (ncols - 1)) / ncols ))
    (( colw < maxw )) && colw="$maxw"

    rows_needed=$(( (count + ncols - 1) / ncols ))
    if (( rows_needed <= max_body_lines )); then
      _denon_udash_flow_columns "$body" "$ncols" "$colw"
      return 0
    fi

    # Genuinely forced (smallest grid): even at full column count the list does
    # not fit the available rows. Show as many entries as the grid holds,
    # reserving the final cell for the "+N more" marker, still multi-column.
    keep=$(( max_body_lines * ncols - 1 ))
    (( keep < 0 )) && keep=0
    (( keep > count )) && keep="$count"
    more=$(( count - keep ))
    trunc=""
    for ((i = 0; i < keep; i++)); do
      trunc="${trunc}${lines[$i]}"$'\n'
    done
    (( more > 0 )) && trunc="${trunc}+${more} more"
    trunc="${trunc%$'\n'}"
    _denon_udash_flow_columns "$trunc" "$ncols" "$colw"
  }

  _denon_udash_compose_events_body() {
    local max_body_lines="$1"

    (( max_body_lines < 5 )) && max_body_lines=5
    if [[ -n "$dashboard_events" ]]; then
      printf '%s\n' "$dashboard_events" | head -n "$max_body_lines"
    else
      printf '%s\n\n\n\n' "$(_denon_display_empty_message no-state-changes)"
    fi
  }

  _denon_udash_column_count() {
    local cols="$1"
    local columns

    if (( cols >= 240 )); then
      columns=5
    elif (( cols >= 170 )); then
      columns=4
    elif (( cols >= 115 )); then
      columns=3
    elif (( cols >= 80 )); then
      columns=3
    elif (( cols >= 54 )); then
      columns=2
    else
      columns=1
    fi
    while (( columns > 1 && (cols - (columns - 1) * 2) / columns < 24 )); do
      columns=$((columns - 1))
    done
    printf '%s\n' "$columns"
  }

  _denon_udash_group_widths() {
    local cols="$1"
    local count="$2"
    local avail base extra i width

    avail=$((cols - (count - 1) * 2))
    base=$((avail / count))
    extra=$((avail - base * count))
    for ((i = 1; i <= count; i++)); do
      width="$base"
      (( i == count )) && width=$((width + extra))
      printf '%s\n' "$width"
    done
  }

  _denon_udash_prepare_values() {
    local state_label now_parts network_label heos_label tv_lines pending_lower value

    udash_main_title=$(_denon_display_zone_label "${dash_main_zone_name:-Main Zone}")
    [[ "$udash_main_title" != "Main Zone" ]] && udash_main_title="$udash_main_title (Main)"
    udash_zone2_title=$(_denon_display_zone_label "${dash_zone2_name:-Zone 2}")
    [[ "$udash_zone2_title" != "Zone 2" ]] && udash_zone2_title="$udash_zone2_title (Zone 2)"

    dash_u_main_volume_label="${dash_main_volume:-Unknown} dB"
    [[ -n "$dash_main_max_volume_db" ]] && dash_u_main_volume_label="$dash_u_main_volume_label (max ${dash_main_max_volume_db} dB)"
    dash_u_main_muted_label=$(_denon_mute_display_name "$dash_main_muted")
    dash_u_sleep_main_label=$(_denon_udash_sleep_label "$dash_u_sleep_main")

    if [[ -n "$dash_zone2_volume_db" ]]; then
      dash_u_zone2_volume_label="${dash_zone2_volume_db} dB"
      [[ -n "$dash_zone2_volume_raw" ]] && dash_u_zone2_volume_label="$dash_u_zone2_volume_label (raw ${dash_zone2_volume_raw})"
      [[ -n "$dash_u_zone2_limit" ]] && dash_u_zone2_volume_label="$dash_u_zone2_volume_label, lim ${dash_u_zone2_limit}"
    else
      dash_u_zone2_volume_label="${dash_zone2_volume:-Unknown}"
    fi
    dash_u_zone2_muted_label=$(_denon_mute_display_name "$dash_zone2_muted")
    dash_u_sleep_zone2_label=$(_denon_udash_sleep_label "$dash_u_sleep_zone2")

    dash_u_signal_label="$dash_u_signal"
    [[ -n "$dash_u_signal_label" ]] || dash_u_signal_label=$(_denon_udash_signal_label "$dash_u_signal_code")
    dash_u_sample_rate_label=$(_denon_udash_sample_rate_label "$dash_u_sample_rate")
    dash_u_speaker_config_label=$(_denon_display_unknown "$dash_u_speaker_config")
    dash_u_drc_label=$(_denon_udash_titlecase_onoff "$dash_u_drc")
    dash_u_lfe_label=$(_denon_udash_lfe_label "$dash_u_lfe")

    dash_u_tone_status_label="${dash_u_tone_status:-}"
    [[ -z "$dash_u_tone_status_label" && -n "$dash_u_tone_ctrl" ]] && dash_u_tone_status_label=$(_denon_udash_titlecase_onoff "$dash_u_tone_ctrl")
    [[ -n "$dash_u_tone_status_label" ]] || dash_u_tone_status_label="Unknown"
    dash_u_bass_label=$(_denon_udash_tone_db "$dash_u_bass_raw")
    dash_u_treble_label=$(_denon_udash_tone_db "$dash_u_treble_raw")

    network_label=$(_denon_display_network_label "$dash_heos_network")
    heos_label="${dash_heos_version:-Unknown}"
    [[ "$network_label" != "Unknown" ]] && heos_label="$heos_label ($network_label)"
    dash_u_heos_label="$heos_label"
    dash_u_eco_label=$(_denon_udash_eco_label "$dash_u_eco")
    dash_u_dimmer_label=$(_denon_udash_dimmer_label "$dash_u_dimmer")

    pending_lower=$(_denon_lower "$(_denon_trim "${dash_u_pending_upgrade_version:-}")")
    dash_u_pending_upgrade_alert=""
    case "$pending_lower" in
      ""|00|0|unknown|null) ;;
      *) dash_u_pending_upgrade_alert="$dash_u_pending_upgrade_version" ;;
    esac

    state_label=$(_denon_dashboard_transport_name "${dash_transport_state:-}") || state_label="Unknown"
    [[ -n "$state_label" ]] || state_label="Unknown"
    dash_u_state_label="$state_label"
    now_parts=""
    [[ -n "$(_denon_dashboard_clean_field "$dash_now_title")" ]] && now_parts="$dash_now_title"
    [[ -n "$(_denon_dashboard_clean_field "$dash_now_artist")" ]] && now_parts="${now_parts}${now_parts:+ — }${dash_now_artist}"
    [[ -n "$(_denon_dashboard_clean_field "$dash_now_album")" ]] && now_parts="${now_parts}${now_parts:+ — }${dash_now_album}"
    [[ -n "$now_parts" ]] || now_parts="${dash_now_message:-Unknown}"
    dash_u_now_parts="$now_parts"

    dash_u_tv_power=""
    dash_u_tv_volume=""
    dash_u_tv_output=""
    if [[ -n "${udash_tv_body:-}" ]]; then
      tv_lines=$(printf '%s\n' "$udash_tv_body")
      value=$(printf '%s\n' "$tv_lines" | sed -n 's/^Power:[[:space:]]*//p' | sed -n '1p'); dash_u_tv_power="$value"
      value=$(printf '%s\n' "$tv_lines" | sed -n 's/^Volume:[[:space:]]*//p' | sed -n '1p'); dash_u_tv_volume="$value"
      value=$(printf '%s\n' "$tv_lines" | sed -n 's/^Output:[[:space:]]*//p' | sed -n '1p'); dash_u_tv_output="$value"
      [[ -n "$dash_u_tv_power$dash_u_tv_volume$dash_u_tv_output" ]] || dash_u_tv_power="$udash_tv_body"
    fi
  }

  _denon_udash_build_panel_body() {
    local key="$1"
    local max_tier="$2"
    local max_body_lines="$3"
    local width="${4:-80}"

    case "$key" in
      sources) _denon_udash_compose_sources_body "$width" "$max_body_lines" ;;
      events) _denon_udash_compose_events_body "$max_body_lines" ;;
      *) _denon_udash_build_tier_body "$key" "$max_tier" "$max_body_lines" ;;
    esac
  }

  # The must-keep panels are the only ones whose loss should fail a layout: the
  # user-facing core plus Recent Events. Receiver/Network and every optional
  # panel are allowed to shed first so Recent Events never disappears while a
  # lower-priority panel still occupies space.
  _denon_udash_required_panel() {
    case "$1" in
      main|zone2|now|events) return 0 ;;
      *) return 1 ;;
    esac
  }

  # required_only=1 builds a degraded best-effort plan containing just the
  # must-keep panels (Receiver/Network and optional panels are excluded) and
  # publishes whatever fits, so a terminal too small for the full tier-0 set
  # still renders the core panels (incl. Recent Events) instead of blanking.
  _denon_udash_make_plan() {
    local cols="$1"
    local rows="$2"
    local max_tier="$3"
    local required_only="${4:-0}"
    local columns footer_height=1 available panel_lines="" rendered_rows=0
    local current_count=0 current_height=0 current_lines="" key tier title_ref title title_value
    local widths width body body_lines height group_count line row_height skipped_required=0

    [[ "${dashboard_keyboard_active:-0}" == "1" ]] && footer_height=2
    columns=$(_denon_udash_column_count "$cols")
    available=$((rows - footer_height))
    (( available < 1 )) && available=1

    while IFS='|' read -r key tier title_ref; do
      (( tier <= max_tier )) || continue
      [[ "$key" == "tv" && "${udash_tv:-0}" != "1" ]] && continue
      # At wide widths Recent Events is the bottom band and Now Playing is the
      # full-width top band, so keep both out of the grid; on narrow terminals
      # they stay grid panels.
      [[ "$key" == "events" ]] && (( cols >= 100 )) && continue
      [[ "$key" == "now" ]] && (( cols >= 100 )) && continue
      (( required_only )) && ! _denon_udash_required_panel "$key" && continue

      group_count=$((current_count + 1))
      widths=$(_denon_udash_group_widths "$cols" "$group_count")
      width=$(printf '%s\n' "$widths" | tail -n 1)
      body=$(_denon_udash_build_panel_body "$key" "$max_tier" 20 "$width")
      body_lines=$(_denon_dashboard_line_count "$body")
      [[ "$key" == "events" && "$body_lines" -lt 5 ]] && body_lines=5
      height=$((body_lines + 4))
      (( height < 4 )) && height=4

      row_height="$current_height"
      (( height > row_height )) && row_height="$height"
      if (( current_count > 0 && current_count >= columns )); then
        rendered_rows=$((rendered_rows + current_height + (rendered_rows > 0 ? 1 : 0)))
        panel_lines="${panel_lines}${current_lines}"
        current_count=0
        current_height=0
        current_lines=""
      elif (( current_count > 0 && rendered_rows + row_height + (rendered_rows > 0 ? 1 : 0) > available )); then
        rendered_rows=$((rendered_rows + current_height + (rendered_rows > 0 ? 1 : 0)))
        panel_lines="${panel_lines}${current_lines}"
        current_count=0
        current_height=0
        current_lines=""
      fi

      group_count=$((current_count + 1))
      widths=$(_denon_udash_group_widths "$cols" "$group_count")
      width=$(printf '%s\n' "$widths" | tail -n 1)
      body=$(_denon_udash_build_panel_body "$key" "$max_tier" 20 "$width")
      body_lines=$(_denon_dashboard_line_count "$body")
      [[ "$key" == "events" && "$body_lines" -lt 5 ]] && body_lines=5
      height=$((body_lines + 4))
      (( height < 4 )) && height=4

      if (( current_count == 0 && rendered_rows + height + (rendered_rows > 0 ? 1 : 0) > available )); then
        _denon_udash_required_panel "$key" && skipped_required=1
        continue
      fi

      if [[ "$title_ref" == udash_* ]]; then
        title_value="${!title_ref:-}"
      else
        title_value="$title_ref"
      fi
      title="$title_value"
      current_lines="${current_lines}${key}"$'\t'"${title}"$'\t'"${body//$'\n'/\\n}"$'\t'"${height}"$'\n'
      current_count=$((current_count + 1))
      (( height > current_height )) && current_height="$height"
    done < <(_denon_udash_panel_tiers)

    if (( current_count > 0 )); then
      rendered_rows=$((rendered_rows + current_height + (rendered_rows > 0 ? 1 : 0)))
      panel_lines="${panel_lines}${current_lines}"
    fi

    # Best-effort degraded mode always publishes what fit so the dashboard
    # never blanks; callers use it only after every full tier failed.
    if (( required_only )); then
      udash_plan="$panel_lines"
      udash_plan_columns="$columns"
      return 0
    fi

    (( skipped_required == 0 )) || return 1
    (( rendered_rows <= available )) || return 1
    udash_plan="$panel_lines"
    udash_plan_columns="$columns"
    return 0
  }

  _denon_udash_layout() {
    local cols="$1"
    local rows="$2"
    local tier grid_rows

    udash_width="$cols"
    if (( cols >= 200 )); then
      udash_mode="ultra"
    elif (( cols >= 120 )); then
      udash_mode="mid"
    else
      udash_mode="narrow"
    fi

    _denon_udash_prepare_values

    # Reserve vertical space for the full-width Now Playing top band and the
    # Recent Events bottom band (each plus one separator row) so the adaptive
    # grid between them never overruns. On narrow terminals there are no bands
    # and the grid uses every row.
    _denon_udash_build_now_band "$cols"
    _denon_udash_build_band "$cols"
    grid_rows="$rows"
    (( udash_nowband_height > 0 )) && grid_rows=$(( grid_rows - udash_nowband_height - 1 ))
    (( udash_band_height > 0 )) && grid_rows=$(( grid_rows - udash_band_height - 1 ))
    (( grid_rows < 1 )) && grid_rows=1

    if (( cols < 100 )); then
      _denon_udash_make_plan "$cols" "$grid_rows" 0 \
        || _denon_udash_make_plan "$cols" "$grid_rows" 0 1
      udash_max_tier=0
      return 0
    fi

    for tier in 3 2 1 0; do
      if _denon_udash_make_plan "$cols" "$grid_rows" "$tier"; then
        udash_max_tier="$tier"
        return 0
      fi
    done
    # No tier could fit every required panel. Rather than blanking the whole
    # grid, fall back to a degraded plan that keeps the must-keep panels,
    # shedding Receiver/Network and the optional panels first.
    _denon_udash_make_plan "$cols" "$grid_rows" 0 1
    udash_max_tier=0
  }

  _denon_udash_render_plan_row() {
    local cols="$1"
    local row_lines="$2"
    local height="$3"
    local count="$4"
    local widths
    local -a titles bodies panel_widths
    local idx=0 line key title body encoded panel_height width row body_budget

    widths=$(_denon_udash_group_widths "$cols" "$count")
    while IFS= read -r width; do
      panel_widths+=("$width")
    done <<<"$widths"

    while IFS=$'\t' read -r key title encoded panel_height; do
      [[ -n "$key" ]] || continue
      titles+=("$title")
      body=${encoded//\\n/$'\n'}
      # Growable panels re-render their body against the (possibly slack-grown)
      # row height so they fill the box with real content instead of truncating.
      if [[ "$key" == "sources" ]]; then
        body_budget=$((height - 4))
        (( body_budget < 1 )) && body_budget=1
        body=$(_denon_udash_compose_sources_body "${panel_widths[$idx]}" "$body_budget")
      elif [[ "$key" == "events" ]]; then
        body_budget=$((height - 4))
        (( body_budget < 1 )) && body_budget=1
        body=$(_denon_udash_compose_events_body "$body_budget")
      fi
      bodies+=("$body")
      idx=$((idx + 1))
    done <<<"$row_lines"

    for ((row = 0; row < height; row++)); do
      for ((idx = 0; idx < count; idx++)); do
        (( idx > 0 )) && printf '  '
        _denon_dashboard_render_card_line "${titles[$idx]}" "${bodies[$idx]}" "${panel_widths[$idx]}" "$height" "$row"
      done
      printf '\n'
    done
  }

  # Slack-distribution pass: after placement, the grid + band sit at their
  # natural (minimum) heights, often leaving a dead band above the footer.
  # Finite-list panels (Sources) are already placed at their multi-column
  # full-content minimum, so the only growable elastic is the unbounded Recent
  # Events box, which absorbs whatever rows are left so the layout reaches the
  # footer with no dead band. When there is no slack (small grids), it is a
  # no-op and the tier-shedding placement stands.
  _denon_udash_distribute_slack() {
    local cols="$1"
    local rows="$2"
    local footer_height=1 key title body height
    local rc=0 colc=0 cur_h=0 cur_ev=0 i
    local grid_total=0 band_total=0 band_sep=0 now_total=0 now_sep=0 target used slack
    local -a rh has_ev

    udash_row_heights=""
    [[ "${dashboard_keyboard_active:-0}" == "1" ]] && footer_height=2

    # Group the plan into rows exactly as _denon_udash_render_adaptive does.
    while IFS=$'\t' read -r key title body height; do
      [[ -n "$key" ]] || continue
      if (( colc > 0 && colc >= udash_plan_columns )); then
        rh[rc]="$cur_h"; has_ev[rc]="$cur_ev"
        rc=$((rc + 1)); colc=0; cur_h=0; cur_ev=0
      fi
      (( height > cur_h )) && cur_h="$height"
      [[ "$key" == "events" ]] && cur_ev=1
      colc=$((colc + 1))
    done <<<"$udash_plan"
    if (( colc > 0 )); then
      rh[rc]="$cur_h"; has_ev[rc]="$cur_ev"
      rc=$((rc + 1))
    fi
    (( rc == 0 )) && return 0

    for ((i = 0; i < rc; i++)); do grid_total=$((grid_total + rh[i])); done
    grid_total=$((grid_total + rc - 1))            # inter-row separators
    if (( udash_band_height > 0 )); then
      band_total="$udash_band_height"; band_sep=1
    fi
    if (( udash_nowband_height > 0 )); then
      now_total="$udash_nowband_height"; now_sep=1
    fi

    target=$((rows - footer_height))
    used=$((now_total + now_sep + grid_total + band_total + band_sep))
    slack=$((target - used))

    if (( slack > 0 )); then
      # Finite-list panels (Sources) are already placed at their multi-column
      # full-content minimum height by the planner — every entry is visible, so
      # they need no extra rows. Growing them here would only pad blank rows and
      # re-introduce the wasted band the column layout removed. Hand all slack to
      # the unbounded Recent Events panel so the grid still reaches the footer
      # with no dead band.
      if (( udash_band_height > 0 )); then
        udash_band_height=$((udash_band_height + slack)); slack=0
      else
        for ((i = rc - 1; i >= 0 && slack > 0; i--)); do
          if (( has_ev[i] == 1 )); then
            rh[i]=$((rh[i] + slack)); slack=0
          fi
        done
        (( slack > 0 )) && { rh[rc-1]=$((rh[rc-1] + slack)); slack=0; }
      fi
    fi

    for ((i = 0; i < rc; i++)); do
      udash_row_heights="${udash_row_heights}${rh[i]}"$'\n'
    done
  }

  _denon_udash_render_adaptive() {
    local cols="$1"
    local line key title body height h
    local row_lines="" row_count=0 row_height=0 ri=0
    local -a rowh

    while IFS= read -r h; do
      [[ -n "$h" ]] && rowh+=("$h")
    done <<<"$udash_row_heights"

    while IFS=$'\t' read -r key title body height; do
      [[ -n "$key" ]] || continue
      if (( row_count > 0 && row_count >= udash_plan_columns )); then
        _denon_udash_render_plan_row "$cols" "$row_lines" "${rowh[ri]:-$row_height}" "$row_count"
        printf '\n'
        ri=$((ri + 1))
        row_lines=""
        row_count=0
        row_height=0
      fi
      row_lines="${row_lines}${key}"$'\t'"${title}"$'\t'"${body}"$'\t'"${height}"$'\n'
      row_count=$((row_count + 1))
      (( height > row_height )) && row_height="$height"
    done <<<"$udash_plan"

    if (( row_count > 0 )); then
      _denon_udash_render_plan_row "$cols" "$row_lines" "${rowh[ri]:-$row_height}" "$row_count"
    fi
  }

  # Build the pinned bottom band: a single full-width Recent Events panel. It
  # is the growable elastic that absorbs leftover vertical slack (see
  # _denon_udash_distribute_slack) so the layout reaches the footer. Only used
  # at wide widths; on narrow terminals Recent Events stays a grid panel.
  _denon_udash_build_band() {
    local cols="$1"
    local ev_body ev_h

    udash_band_lines=""
    udash_band_count=0
    udash_band_height=0

    (( cols >= 100 )) || return 0

    ev_body=$(_denon_udash_compose_events_body 20)
    ev_h=$(( $(_denon_dashboard_line_count "$ev_body") + 4 ))
    (( ev_h < 9 )) && ev_h=9

    udash_band_lines="events"$'\t'"Recent Events"$'\t'"${ev_body//$'\n'/\\n}"$'\t'"${ev_h}"$'\n'
    udash_band_count=1
    udash_band_height="$ev_h"
  }

  _denon_udash_render_band() {
    local cols="$1"

    [[ -n "$udash_band_lines" ]] || return 0
    printf '\n'
    _denon_udash_render_plan_row "$cols" "$udash_band_lines" "$udash_band_height" "$udash_band_count"
  }

  # Compose the Now Playing body for the full-width top band: keep the (often
  # long) "Now:" line on its own full-width row, then fold the remaining fields
  # into two columns so the band uses the horizontal space and stays compact.
  _denon_udash_compose_now_band_body() {
    local cols="$1"
    local full now_line rest colw

    full=$(_denon_udash_build_panel_body now 2 20 "$cols")
    now_line=$(printf '%s\n' "$full" | sed -n '1p')
    rest=$(printf '%s\n' "$full" | sed -n '2,$p')
    colw=$(( (cols - 6) / 2 ))

    if (( cols >= 100 && colw >= 24 )) && [[ -n "$rest" ]]; then
      printf '%s\n' "$now_line"
      _denon_udash_two_col "$rest" "$colw"
    else
      printf '%s\n' "$full"
    fi
  }

  # Build the full-width Now Playing top band so long track titles (and the
  # Service / Station / Artist / Album fields) get the whole viewport width
  # instead of a cramped grid column. Fixed height; only used at wide widths.
  _denon_udash_build_now_band() {
    local cols="$1"
    local now_body now_h

    udash_nowband_lines=""
    udash_nowband_count=0
    udash_nowband_height=0

    (( cols >= 100 )) || return 0

    now_body=$(_denon_udash_compose_now_band_body "$cols")
    now_h=$(( $(_denon_dashboard_line_count "$now_body") + 4 ))
    (( now_h < 4 )) && now_h=4

    udash_nowband_lines="now"$'\t'"Now Playing"$'\t'"${now_body//$'\n'/\\n}"$'\t'"${now_h}"$'\n'
    udash_nowband_count=1
    udash_nowband_height="$now_h"
  }

  _denon_udash_render_now_band() {
    local cols="$1"

    [[ -n "$udash_nowband_lines" ]] || return 0
    _denon_udash_render_plan_row "$cols" "$udash_nowband_lines" "$udash_nowband_height" "$udash_nowband_count"
    printf '\n'
  }

  _denon_udash_render() {
    local width height

    width=$(_denon_dashboard_width)
    height=$(_denon_dashboard_height)
    _denon_dashboard_setup_color
    _denon_dashboard_set_borders
    _denon_udash_layout "$width" "$height"
    _denon_udash_distribute_slack "$width" "$height"
    _denon_udash_render_now_band "$width"
    _denon_udash_render_adaptive "$width"
    _denon_udash_render_band "$width"
    _denon_dashboard_render_footer "$width"
  }

  _denon_udash_redraw() {
    local rendered

    rendered=$(_denon_udash_render)
    printf '\033[H\033[J%s' "$rendered"
  }

  # Keyboard handling is shared with the stable dashboard: the caller sets
  # dashboard_redraw_cmd=_denon_udash_redraw so redraws use the ultra
  # renderer. The shared sleep helper also polls keys when a slow collect
  # consumed the whole interval (remaining <= 0) — without that, quit and
  # every other binding went dead whenever collection ran long.
  _denon_udash_handle_key() {
    _denon_dashboard_handle_key "$@"
  }

  _denon_udash_poll_key() {
    _denon_dashboard_poll_key "$@"
  }

  _denon_udash_sleep_or_resize() {
    _denon_dashboard_sleep_or_resize "$@"
  }

  # Responsive refresh: keys (notably q/Q quit and [r] redraw) must stay live
  # while a tick gathers data. _denon_udash_collect can take several seconds
  # (AppCommand batches, telnet, HEOS, HTTP), and it is synchronous, so polling
  # only after it returns makes quit feel dead for the whole refresh. Here the
  # *unchanged* collect runs in a background subshell while we poll the keyboard;
  # when it finishes we import the gathered dash_*/udash_tv_body state so the
  # rendered values are byte-identical to a synchronous collect. Non-interactive
  # callers (tests, pipes) fall back to a plain synchronous collect.
  _denon_udash_collect_responsive() {
    if [[ "${dashboard_keyboard_active:-0}" != "1" ]] || [[ ! -t 0 ]]; then
      _denon_udash_collect
      return 0
    fi

    local state_file collect_pid
    state_file=$(mktemp "${TMPDIR:-/tmp}/denon-udash-state.XXXXXX" 2>/dev/null) || {
      _denon_udash_collect
      return 0
    }

    (
      _denon_udash_collect
      # Serialize only the collected display state. ^dash_ excludes dashboard_*
      # (loop/flow flags like dashboard_stop_pending stay owned by the foreground
      # so a key pressed mid-collect is never clobbered). Rewrite the `declare --`
      # prefix to `declare -g --` so sourcing the file back *inside this function*
      # restores the values as globals (plain `declare` in a function = locals,
      # which would vanish on return and blank every field).
      declare -p $(compgen -v | grep -E '^(dash_|udash_tv_body$)') 2>/dev/null \
        | sed 's/^declare -/declare -g -/'
    ) >"$state_file" 2>/dev/null &
    collect_pid=$!

    while kill -0 "$collect_pid" 2>/dev/null; do
      _denon_dashboard_poll_key 0.1 || true
      if [[ "${dashboard_stop_pending:-0}" == "1" ]]; then
        kill "$collect_pid" 2>/dev/null || true
        wait "$collect_pid" 2>/dev/null || true
        rm -f "$state_file" 2>/dev/null
        return 0
      fi
      if [[ "${dashboard_resize_pending:-0}" == "1" ]]; then
        dashboard_resize_pending=0
        _denon_udash_redraw
      fi
    done
    wait "$collect_pid" 2>/dev/null || true

    [[ -s "$state_file" ]] && source "$state_file" 2>/dev/null
    rm -f "$state_file" 2>/dev/null
  }

  _denon_dashboard_ultra() {
    local watch=0
    local interval=5
    local arg
    local dashboard_initialized=0
    # shellcheck disable=SC2034 # Retained with the event state block for dashboard state tracking.
    local previous_dashboard_key=""
    local dashboard_events=""
    local last_dashboard_event=""
    # shellcheck disable=SC2034 # Previous-state fields are used by the shared event tracker.
    local prev_main_power="" prev_main_source="" prev_main_source_index="" prev_main_muted="" prev_main_volume=""
    local prev_sound_mode=""
    # shellcheck disable=SC2034 # Previous-state fields are used by the shared event tracker.
    local prev_zone2_power="" prev_zone2_source="" prev_zone2_source_index="" prev_zone2_muted="" prev_now_title=""
    local prev_transport_state=""
    # shellcheck disable=SC2034 # Previous-state fields are used by the shared event tracker.
    local prev_zone2_volume_db="" prev_now_artist="" prev_now_album="" prev_now_station="" prev_now_service=""
    local dashboard_color_mode="auto"
    local dashboard_use_color=0
    local dash_c_reset="" dash_c_dim="" dash_c_green="" dash_c_yellow="" dash_c_red=""
    local dashboard_resize_pending=0
    local dashboard_stop_pending=0
    local dashboard_exit_status=0
    local dashboard_saved_stty=""
    local dashboard_terminal_active=0
    local dashboard_keyboard_active=0
    local dashboard_control_target="Main"
    local dashboard_last_command_ms=""
    local dashboard_command_throttle_ms=200
    local dashboard_numeric_buffer=""
    local dashboard_numeric_deadline_ms=""
    local dashboard_numeric_timeout_ms=750
    # Route shared key-handler redraws through the ultra renderer.
    # shellcheck disable=SC2034 # Read indirectly by the shared dashboard key handler.
    local dashboard_redraw_cmd="_denon_udash_redraw"
    local udash_tv=0
    local usage="Usage: denon dashboard-ultra [--watch] [--interval seconds] [--tv] [--ascii|--unicode] [--color auto|always|never]"

    dashboard_ascii=0
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *UTF-8*|*utf8*|*UTF8*) dashboard_ascii=0 ;;
      *) dashboard_ascii=1 ;;
    esac
    [[ "${DENON_DASHBOARD_ASCII:-0}" == "1" ]] && dashboard_ascii=1

    while [[ $# -gt 0 ]]; do
      arg="$1"
      case "$arg" in
        watch|--watch|-w)
          watch=1
          shift
          if [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            interval="$1"
            shift
          fi
          ;;
        once|--once)
          watch=0
          shift
          ;;
        --interval|-n)
          if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "$usage" >&2
            return 1
          fi
          watch=1
          interval="$2"
          shift 2
          ;;
        --tv)
          udash_tv=1
          shift
          ;;
        --ascii)
          dashboard_ascii=1
          shift
          ;;
        --unicode)
          dashboard_ascii=0
          shift
          ;;
        --color)
          case "$(_denon_lower "${2:-}")" in
            auto|always|never)
              dashboard_color_mode=$(_denon_lower "$2")
              shift 2
              ;;
            *)
              echo "$usage" >&2
              return 1
              ;;
          esac
          ;;
        [0-9]*)
          watch=1
          interval="$arg"
          shift
          ;;
        *)
          echo "$usage" >&2
          return 1
          ;;
      esac
    done

    if [[ "$watch" == "1" ]]; then
      trap 'dashboard_resize_pending=1' WINCH
      trap 'dashboard_stop_pending=1; dashboard_exit_status=130; _denon_dashboard_restore_terminal' INT TERM HUP
      if [[ -t 0 ]]; then
        dashboard_saved_stty=$(stty -g 2>/dev/null || printf '')
        if [[ -n "$dashboard_saved_stty" ]]; then
          if stty -echo -icanon min 0 time 0 2>/dev/null; then
            dashboard_terminal_active=1
            dashboard_keyboard_active=1
          fi
        fi
      fi
      printf '\033[?25l'
      while [[ "$dashboard_stop_pending" != "1" ]]; do
        local poll_start poll_end poll_elapsed poll_sleep
        poll_start=$(date +%s)
        _denon_udash_collect_responsive
        [[ "$dashboard_stop_pending" == "1" ]] && break
        _denon_dashboard_update_events
        dashboard_resize_pending=0
        _denon_udash_redraw
        poll_end=$(date +%s)
        poll_elapsed=$((poll_end - poll_start))
        poll_sleep=$(awk -v interval="$interval" -v elapsed="$poll_elapsed" 'BEGIN { s = interval - elapsed; if (s < 0) s = 0; printf "%.3f", s }')
        _denon_udash_sleep_or_resize "$poll_sleep"
      done
      _denon_dashboard_restore_terminal
      trap - WINCH INT TERM HUP
      return "$dashboard_exit_status"
    fi

    _denon_udash_collect
    _denon_dashboard_update_events
    _denon_udash_render
  }

  # ── presets ───────────────────────────────────────────────────────────────

  _denon_preset_dir() {
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/denon/presets"
  }

  _denon_preset_cmd() {
    local subcmd="${1:-}"
    local preset_dir
    preset_dir=$(_denon_preset_dir)

    case "$subcmd" in
      save)
        local name="${2:-}"
        if [[ -z "$name" ]]; then
          echo "Usage: denon preset save <name>" >&2
          return 1
        fi
        _denon_validate_stored_name "preset" "$name" || return 1
        local power_xml source_xml vol_xml
        power_xml=$(_denon_get_power_xml) || return 1
        source_xml=$(_denon_get_source_xml) || return 1
        vol_xml=$(_denon_get_vol_xml) || return 1

        local main_power main_src main_vol main_mute
        local z2_power z2_src z2_vol z2_mute
        main_power=$(_denon_extract_main_power "$power_xml")
        z2_power=$(_denon_extract_zone2_power "$power_xml")
        main_src=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="1" index="\([0-9]\+\)".*:\1:p')
        z2_src=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="2" index="\([0-9]\+\)".*:\1:p')
        main_vol=$(_denon_extract_main_volume_raw "$vol_xml")
        z2_vol=$(_denon_extract_zone2_volume_raw "$vol_xml")
        main_mute=$(_denon_extract_main_mute "$vol_xml")
        z2_mute=$(_denon_extract_zone2_mute "$vol_xml")

        mkdir -p "$preset_dir"
        local preset_file="$preset_dir/$name"
        printf '# denon-preset v1\n' >"$preset_file"
        printf '# saved: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$preset_file"
        printf 'main_power=%s\n' "${main_power:-3}" >>"$preset_file"
        printf 'main_source=%s\n' "${main_src:-}" >>"$preset_file"
        printf 'main_volume=%s\n' "${main_vol:-}" >>"$preset_file"
        printf 'main_mute=%s\n' "${main_mute:-2}" >>"$preset_file"
        printf 'zone2_power=%s\n' "${z2_power:-3}" >>"$preset_file"
        printf 'zone2_source=%s\n' "${z2_src:-}" >>"$preset_file"
        printf 'zone2_volume=%s\n' "${z2_vol:-}" >>"$preset_file"
        printf 'zone2_mute=%s\n' "${z2_mute:-2}" >>"$preset_file"

        local db_label=""
        [[ -n "$main_vol" ]] && db_label=" ($(_denon_raw_to_db "$main_vol") dB)"
        echo "Preset '$name' saved"
        printf '  Main: power=%s source=%s vol=%s%s mute=%s\n' \
          "$(_denon_power_name "${main_power:-}")" "${main_src:-?}" "${main_vol:-?}" "$db_label" "$(_denon_mute_display_name "$main_mute")"
        printf '  Zone 2: power=%s source=%s vol=%s mute=%s\n' \
          "$(_denon_power_name "${z2_power:-}")" "${z2_src:-?}" "${z2_vol:-?}" "$(_denon_mute_display_name "$z2_mute")"
        return 0
        ;;

      load)
        local name="${2:-}"
        if [[ -z "$name" ]]; then
          echo "Usage: denon preset load <name>" >&2
          return 1
        fi
        _denon_validate_stored_name "preset" "$name" || return 1
        local preset_file="$preset_dir/$name"
        if [[ ! -f "$preset_file" ]]; then
          echo "Error: preset '$name' not found (${preset_file})" >&2
          return 1
        fi

        local main_power="" main_source="" main_volume="" main_mute=""
        local zone2_power="" zone2_source="" zone2_volume="" zone2_mute=""
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
          line="${line%%#*}"
          [[ -z "${line// }" ]] && continue
          key="${line%%=*}"; val="${line#*=}"
          [[ "$key" == "$val" ]] && continue
          case "$key" in
            main_power)   main_power="$val" ;;
            main_source)  main_source="$val" ;;
            main_volume)  main_volume="$val" ;;
            main_mute)    main_mute="$val" ;;
            zone2_power)  zone2_power="$val" ;;
            zone2_source) zone2_source="$val" ;;
            zone2_volume) zone2_volume="$val" ;;
            zone2_mute)   zone2_mute="$val" ;;
          esac
        done <"$preset_file"

        echo "Loading preset '$name'..."

        local restore_failed=0
        local -a restore_failures=()
        local step_desc

        if [[ "$main_power" == "1" ]]; then
          if ! _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>'; then
            restore_failed=1
            restore_failures+=("main power on")
          fi
          sleep 1
        fi
        if [[ -n "$main_source" ]]; then
          if [[ "$(_denon_current_source_idx 1)" != "$main_source" ]]; then
            if ! _denon_set_source_index 1 "$main_source" && ! _denon_wait_for_source 1 "$main_source" 20; then
              restore_failed=1
              restore_failures+=("main source ${main_source}")
            fi
          fi
        fi
        if [[ -n "$main_volume" ]]; then
          if ! _denon_set_config 12 "<MainZone><Volume>${main_volume}</Volume></MainZone>"; then
            restore_failed=1
            restore_failures+=("main volume ${main_volume}")
          fi
        fi
        if [[ -n "$main_mute" ]]; then
          if ! _denon_set_config 12 "<MainZone><Mute>${main_mute}</Mute></MainZone>"; then
            restore_failed=1
            restore_failures+=("main mute ${main_mute}")
          fi
        fi

        if [[ "$zone2_power" == "1" ]]; then
          if ! _denon_set_config 4 '<Zone2><Power>1</Power></Zone2>'; then
            restore_failed=1
            restore_failures+=("zone2 power on")
          fi
          sleep 0.5
        fi
        if [[ "$zone2_power" == "1" ]]; then
          if [[ -n "$zone2_source" ]]; then
            if [[ "$(_denon_current_source_idx 2)" != "$zone2_source" ]]; then
              if ! _denon_set_source_index 2 "$zone2_source" && ! _denon_wait_for_source 2 "$zone2_source" 20; then
                restore_failed=1
                restore_failures+=("zone2 source ${zone2_source}")
              fi
            fi
          fi
          if [[ -n "$zone2_volume" ]]; then
            if ! _denon_set_config 12 "<Zone2><Volume>${zone2_volume}</Volume></Zone2>"; then
              restore_failed=1
              restore_failures+=("zone2 volume ${zone2_volume}")
            fi
          fi
          if [[ -n "$zone2_mute" ]]; then
            if ! _denon_set_config 12 "<Zone2><Mute>${zone2_mute}</Mute></Zone2>"; then
              restore_failed=1
              restore_failures+=("zone2 mute ${zone2_mute}")
            fi
          fi
        fi

        if [[ "$zone2_power" == "3" || "$zone2_power" == "2" ]]; then
          if ! _denon_set_config 4 "<Zone2><Power>${zone2_power}</Power></Zone2>"; then
            restore_failed=1
            restore_failures+=("zone2 power ${zone2_power}")
          fi
        fi

        if [[ "$main_power" == "3" || "$main_power" == "2" ]]; then
          if ! _denon_set_config 4 "<MainZone><Power>${main_power}</Power></MainZone>"; then
            restore_failed=1
            restore_failures+=("main power ${main_power}")
          fi
        fi

        printf 'Target main: power=%s source=%s volume=%s mute=%s\n' \
          "$(_denon_power_name "${main_power:-}")" "${main_source:-unset}" "${main_volume:-unset}" "${main_mute:-unset}"
        printf 'Target Zone 2: power=%s source=%s volume=%s mute=%s\n' \
          "$(_denon_power_name "${zone2_power:-}")" "${zone2_source:-unset}" "${zone2_volume:-unset}" "${zone2_mute:-unset}"
        _denon_status_pretty
        if (( restore_failed )); then
          echo "Preset '$name' loaded with partial failures:" >&2
          for step_desc in "${restore_failures[@]}"; do
            echo "  - $step_desc" >&2
          done
          return 1
        fi
        echo "Preset '$name' loaded successfully"
        return 0
        ;;

      list)
        if [[ ! -d "$preset_dir" ]] || [[ -z "$(ls -A "$preset_dir" 2>/dev/null)" ]]; then
          echo "No presets saved. Use: denon preset save <name>"
          return 0
        fi
        printf '%-20s %s\n' "PRESET" "SAVED"
        printf '%-20s %s\n' "------" "-----"
        local f
        for f in "$preset_dir"/*; do
          [[ -f "$f" ]] || continue
          local saved_date=""
          saved_date=$(grep '^# saved:' "$f" | head -1 | sed 's/^# saved: //')
          printf '%-20s %s\n' "$(basename "$f")" "${saved_date:-unknown}"
        done
        return 0
        ;;

      delete|rm)
        local name="${2:-}"
        if [[ -z "$name" ]]; then
          echo "Usage: denon preset delete <name>" >&2
          return 1
        fi
        _denon_validate_stored_name "preset" "$name" || return 1
        local preset_file="$preset_dir/$name"
        if [[ ! -f "$preset_file" ]]; then
          echo "Error: preset '$name' not found" >&2
          return 1
        fi
        rm "$preset_file"
        echo "Preset '$name' deleted"
        return 0
        ;;

      show)
        local name="${2:-}"
        if [[ -z "$name" ]]; then
          echo "Usage: denon preset show <name>" >&2
          return 1
        fi
        _denon_validate_stored_name "preset" "$name" || return 1
        local preset_file="$preset_dir/$name"
        if [[ ! -f "$preset_file" ]]; then
          echo "Error: preset '$name' not found" >&2
          return 1
        fi
        cat "$preset_file"
        return 0
        ;;

      "")
        echo "Usage: denon preset <save|load|list|show|delete> [name]" >&2
        return 1
        ;;

      *)
        echo "Unknown preset subcommand '$subcmd'. Usage: denon preset <save|load|list|show|delete> [name]" >&2
        return 1
        ;;
    esac
  }

  # ── watch-event ───────────────────────────────────────────────────────────

  _denon_watch_event() {
    local condition="${1:-}"
    local user_cmd="${2:-}"
    if [[ -z "$condition" || -z "$user_cmd" ]]; then
      echo "Usage: denon watch-event <condition> <command> [--interval secs] [--once] [--timeout secs]" >&2
      echo "  Conditions: source=tv  power=on  mute=off  vol<-30  vol>=-35" >&2
      return 1
    fi
    shift 2

    local interval=5 once=0 timeout_secs=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --interval) interval="$2"; shift 2 ;;
        --once)     once=1; shift ;;
        --timeout)  timeout_secs="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; return 1 ;;
      esac
    done

    local cond_key cond_op cond_val
    if [[ "$condition" =~ ^([a-zA-Z_]+)([\<\>\!]?=|[\<\>])(.+)$ ]]; then
      cond_key="${BASH_REMATCH[1]}"
      cond_op="${BASH_REMATCH[2]}"
      cond_val="${BASH_REMATCH[3]}"
    else
      echo "Error: cannot parse condition '$condition'" >&2
      echo "Examples: source=tv  power=on  mute=off  vol<-30  vol>=-35" >&2
      return 1
    fi
    cond_key=$(_denon_lower "$cond_key")
    cond_val=$(_denon_lower "$cond_val")

    echo "Watching: $condition (every ${interval}s, Ctrl-C to stop)"
    local start_time
    start_time=$(date +%s)

    while true; do
      if (( timeout_secs > 0 )); then
        local now
        now=$(date +%s)
        if (( now - start_time >= timeout_secs )); then
          echo "Timeout after ${timeout_secs}s — condition never met" >&2
          return 1
        fi
      fi

      local met=0
      case "$cond_key" in
        source)
          local source_xml actual_idx target_idx
          source_xml=$(_denon_get_source_xml 2>/dev/null) || { sleep "$interval"; continue; }
          actual_idx=$(printf '%s' "$source_xml" | sed -n 's:.*<Zone zone="1" index="\([0-9]\+\)".*:\1:p')
          if [[ "$cond_val" =~ ^[0-9]+$ ]]; then
            target_idx="$cond_val"
          else
            target_idx=$(_denon_resolve_source_index "$cond_val" 1 2>/dev/null) || target_idx=""
          fi
          case "$cond_op" in
            =|==) [[ "$actual_idx" == "$target_idx" ]] && met=1 ;;
            !=)   [[ "$actual_idx" != "$target_idx" ]] && met=1 ;;
          esac
          ;;
        power)
          local power_xml power_code power_str
          power_xml=$(_denon_get_power_xml 2>/dev/null) || { sleep "$interval"; continue; }
          power_code=$(_denon_extract_main_power "$power_xml")
          case "$power_code" in
            1) power_str="on" ;;
            2) power_str="standby" ;;
            *) power_str="off" ;;
          esac
          case "$cond_op" in
            =|==) [[ "$power_str" == "$cond_val" ]] && met=1 ;;
            !=)   [[ "$power_str" != "$cond_val" ]] && met=1 ;;
          esac
          ;;
        mute)
          local mute_xml mute_code mute_str cv
          mute_xml=$(_denon_get_vol_xml 2>/dev/null) || { sleep "$interval"; continue; }
          mute_code=$(_denon_extract_main_mute "$mute_xml")
          [[ "$mute_code" == "1" ]] && mute_str="on" || mute_str="off"
          cv="$cond_val"
          [[ "$cv" == "1" ]] && cv="on"
          [[ "$cv" == "0" ]] && cv="off"
          case "$cond_op" in
            =|==) [[ "$mute_str" == "$cv" ]] && met=1 ;;
            !=)   [[ "$mute_str" != "$cv" ]] && met=1 ;;
          esac
          ;;
        vol|volume)
          local vol_xml raw_vol actual_db
          vol_xml=$(_denon_get_vol_xml 2>/dev/null) || { sleep "$interval"; continue; }
          raw_vol=$(_denon_extract_main_volume_raw "$vol_xml")
          [[ -z "$raw_vol" ]] && { sleep "$interval"; continue; }
          actual_db=$(awk -v r="$raw_vol" 'BEGIN { printf "%.1f", r/10 - 80 }')
          met=$(awk -v a="$actual_db" -v b="$cond_val" -v op="$cond_op" 'BEGIN {
            if      (op == "=" || op == "==") { print (a+0 == b+0) ? 1 : 0 }
            else if (op == "<")               { print (a+0 <  b+0) ? 1 : 0 }
            else if (op == ">")               { print (a+0 >  b+0) ? 1 : 0 }
            else if (op == "<=")              { print (a+0 <= b+0) ? 1 : 0 }
            else if (op == ">=")              { print (a+0 >= b+0) ? 1 : 0 }
            else if (op == "!=")              { print (a+0 != b+0) ? 1 : 0 }
            else                              { print 0 }
          }')
          ;;
        *)
          echo "Error: unsupported condition key '$cond_key'" >&2
          echo "Supported: source, power, mute, vol" >&2
          return 1
          ;;
      esac

      if (( met )); then
        printf '[%s] Condition met: %s\n' "$(date '+%H:%M:%S')" "$condition"
        bash -c "$user_cmd"
        (( once )) && return 0
      fi

      sleep "$interval"
    done
  }

  # ── Config file ───────────────────────────────────────────────────────────

  _denon_config_path() {
    printf '%s' "${DENON_CONFIG:-$HOME/.config/denon/config}"
  }

  _denon_profile_dir() {
    printf '%s' "$(dirname "$(_denon_config_path)")/profiles"
  }

  _denon_load_config() {
    local cfg="${1:-$(_denon_config_path)}"
    [[ -f "$cfg" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      key="${line%%=*}"
      val="${line#*=}"
      [[ "$key" == "$val" ]] && continue
      case "$key" in
        DENON_IP|DENON_DEFAULT_IP|DENON_SCAN_LAN|DENON_MAX_VOLUME_DB|\
        DENON_VOLUME_STEP_DB|DENON_SOURCE_ALIASES|DENON_CURL_CONNECT_TIMEOUT|\
        DENON_CURL_MAX_TIME|DENON_CURL_INSECURE|DENON_CURL_CACERT|\
        DENON_CURL_PINNEDPUBKEY|DENON_SSDP_TIMEOUT|DENON_SSDP_MX|DENON_HEOS_PID|\
        DENON_HEOS_GID|DENON_HEOS_HELPER|DENON_DASHBOARD_ALT_HELPER|DENON_HEOS_TIMEOUT|DENON_DEBUG|\
        DENON_CACHE_TTL_SECONDS|NO_COLOR)
          if [[ -z "${!key+set}" ]]; then
            export "$key"="$val"
          fi
          ;;
      esac
    done <"$cfg"
  }

  _denon_profile_cmd() {
    local subcmd="${1:-}"
    local profile_dir
    profile_dir=$(_denon_profile_dir)
    local known_keys="DENON_IP DENON_DEFAULT_IP DENON_SCAN_LAN DENON_MAX_VOLUME_DB \
DENON_VOLUME_STEP_DB DENON_SOURCE_ALIASES DENON_CURL_CONNECT_TIMEOUT \
DENON_CURL_MAX_TIME DENON_CURL_INSECURE DENON_CURL_CACERT \
DENON_CURL_PINNEDPUBKEY DENON_SSDP_TIMEOUT DENON_SSDP_MX DENON_HEOS_PID \
DENON_HEOS_GID DENON_HEOS_HELPER DENON_DASHBOARD_ALT_HELPER DENON_HEOS_TIMEOUT DENON_DEBUG \
DENON_CACHE_TTL_SECONDS NO_COLOR"

    case "$subcmd" in
      list)
        printf 'Profiles dir: %s\n\n' "$profile_dir"
        if [[ ! -d "$profile_dir" ]] || [[ -z "$(ls -A "$profile_dir" 2>/dev/null)" ]]; then
          echo "No profiles found. Create one at: ${profile_dir}/<name>"
          return 0
        fi
        local active="${DENON_PROFILE:-}"
        local f
        for f in "$profile_dir"/*; do
          [[ -f "$f" ]] || continue
          local n; n=$(basename "$f")
          if [[ "$n" == "$active" ]]; then
            printf '* %s (active)\n' "$n"
          else
            printf '  %s\n' "$n"
          fi
        done
        return 0
        ;;

      show)
        local name="${2:-${DENON_PROFILE:-}}"
        if [[ -z "$name" ]]; then
          echo "Usage: denon profile show <name>" >&2
          echo "  (or set DENON_PROFILE to show the active profile)" >&2
          return 1
        fi
        _denon_validate_stored_name "profile" "$name" || return 1
        local pfile="$profile_dir/$name"
        if [[ ! -f "$pfile" ]]; then
          echo "Error: profile '$name' not found (${pfile})" >&2
          return 1
        fi
        printf 'Profile: %s\n\n' "$name"
        printf '%-32s %s\n' "KEY" "VALUE"
        printf '%-32s %s\n' "---" "-----"
        local k
        for k in $known_keys; do
          local fval=""
          fval=$(grep "^${k}=" "$pfile" 2>/dev/null | tail -1 | cut -d= -f2-)
          [[ -n "$fval" ]] && printf '%-32s %s\n' "$k" "$fval"
        done
        return 0
        ;;

      path)
        local name="${2:-${DENON_PROFILE:-}}"
        if [[ -z "$name" ]]; then
          echo "Usage: denon profile path <name>" >&2
          return 1
        fi
        _denon_validate_stored_name "profile" "$name" || return 1
        printf '%s\n' "$profile_dir/$name"
        return 0
        ;;

      set)
        local name="${2:-}" key="${3:-}" val="${*:4}"
        if [[ -z "$name" || -z "$key" || -z "$val" ]]; then
          echo "Usage: denon profile set <name> KEY VALUE..." >&2
          return 1
        fi
        _denon_validate_stored_name "profile" "$name" || return 1
        local ok=0
        for k in $known_keys; do [[ "$k" == "$key" ]] && ok=1 && break; done
        if (( ! ok )); then
          echo "Error: unknown key '$key'" >&2
          return 1
        fi
        mkdir -p "$profile_dir"
        local pfile="$profile_dir/$name"
        if [[ -f "$pfile" ]] && grep -q "^${key}=" "$pfile"; then
          local tmp; tmp=$(mktemp)
          grep -v "^${key}=" "$pfile" >"$tmp"
          mv "$tmp" "$pfile"
        fi
        printf '%s=%s\n' "$key" "$val" >>"$pfile"
        echo "Set $key=$val in profile '$name' (${pfile})"
        return 0
        ;;

      unset)
        local name="${2:-}" key="${3:-}"
        if [[ -z "$name" || -z "$key" ]]; then
          echo "Usage: denon profile unset <name> KEY" >&2
          return 1
        fi
        _denon_validate_stored_name "profile" "$name" || return 1
        local pfile="$profile_dir/$name"
        if [[ ! -f "$pfile" ]] || ! grep -q "^${key}=" "$pfile"; then
          echo "$key not set in profile '$name'"
          return 0
        fi
        local tmp; tmp=$(mktemp)
        grep -v "^${key}=" "$pfile" >"$tmp"
        mv "$tmp" "$pfile"
        echo "Removed $key from profile '$name'"
        return 0
        ;;

      active|"")
        if [[ -n "${DENON_PROFILE:-}" ]]; then
          printf 'Active profile: %s\n' "$DENON_PROFILE"
          _denon_profile_cmd show "$DENON_PROFILE"
        else
          echo "No active profile. Set DENON_PROFILE=<name> or run: denon profile list"
        fi
        return 0
        ;;

      *)
        echo "Usage: denon profile <list|show|path|set|unset|active> [args]" >&2
        return 1
        ;;
    esac
  }

  _denon_config_cmd() {
    local subcmd="${1:-}"
    local cfg
    cfg=$(_denon_config_path)
    local known_keys="DENON_IP DENON_DEFAULT_IP DENON_SCAN_LAN DENON_MAX_VOLUME_DB \
DENON_VOLUME_STEP_DB DENON_SOURCE_ALIASES DENON_CURL_CONNECT_TIMEOUT \
DENON_CURL_MAX_TIME DENON_CURL_INSECURE DENON_CURL_CACERT \
DENON_CURL_PINNEDPUBKEY DENON_SSDP_TIMEOUT DENON_SSDP_MX DENON_HEOS_PID \
DENON_HEOS_GID DENON_HEOS_HELPER DENON_DASHBOARD_ALT_HELPER DENON_HEOS_TIMEOUT DENON_DEBUG \
DENON_CACHE_TTL_SECONDS NO_COLOR"

    case "$subcmd" in
      path)
        echo "$cfg"
        return 0
        ;;
      set)
        local key="$2" val="${*:3}"
        if [[ -z "$key" || -z "$val" ]]; then
          echo "Usage: denon config set KEY VALUE..." >&2
          return 1
        fi
        local ok=0
        for k in $known_keys; do [[ "$k" == "$key" ]] && ok=1 && break; done
        if (( ! ok )); then
          echo "Error: unknown config key '$key'. Allowed keys: $known_keys" >&2
          return 1
        fi
        mkdir -p "$(dirname "$cfg")"
        if [[ -f "$cfg" ]] && grep -q "^${key}=" "$cfg"; then
          local tmp
          tmp=$(mktemp)
          grep -v "^${key}=" "$cfg" >"$tmp"
          mv "$tmp" "$cfg"
        fi
        printf '%s=%s\n' "$key" "$val" >>"$cfg"
        echo "Set $key=$val in $cfg"
        return 0
        ;;
      unset)
        local key="$2"
        if [[ -z "$key" ]]; then
          echo "Usage: denon config unset KEY" >&2
          return 1
        fi
        if [[ ! -f "$cfg" ]] || ! grep -q "^${key}=" "$cfg"; then
          echo "$key not set in $cfg"
          return 0
        fi
        local tmp
        tmp=$(mktemp)
        grep -v "^${key}=" "$cfg" >"$tmp"
        mv "$tmp" "$cfg"
        echo "Removed $key from $cfg"
        return 0
        ;;
      "")
        printf 'Config file: %s\n\n' "$cfg"
        printf '%-32s %-20s %s\n' "KEY" "EFFECTIVE VALUE" "SOURCE"
        printf '%-32s %-20s %s\n' "---" "---------------" "------"
        local k
        for k in $known_keys; do
          local file_val="" env_src="env" file_src="file" effective="" source_lbl=""
          if [[ -f "$cfg" ]]; then
            file_val=$(grep "^${k}=" "$cfg" | tail -1 | cut -d= -f2-)
          fi
          if [[ -n "${!k+set}" ]]; then
            effective="${!k}"
            if [[ -n "$file_val" && "${!k}" == "$file_val" ]]; then
              source_lbl="$file_src"
            else
              source_lbl="$env_src"
            fi
          elif [[ -n "$file_val" ]]; then
            effective="$file_val"
            source_lbl="$file_src"
          else
            effective="(unset)"
            source_lbl=""
          fi
          printf '%-32s %-20s %s\n' "$k" "$effective" "$source_lbl"
        done
        return 0
        ;;
      *)
        echo "Usage: denon config [set KEY VALUE | unset KEY | path]" >&2
        return 1
        ;;
    esac
  }

  _denon_completion_usage() {
    cat <<'EOF'
Usage: denon completion <command>

Generate or install shell completion scripts.

Commands:
  denon completion bash
  denon completion zsh
  denon completion fish
  denon completion install
EOF
  }

  _denon_completion_source_path() {
    local shell="$1"
    local script_path script_dir name path
    script_path=$(_denon_script_path 2>/dev/null || printf '')
    script_dir=""
    [[ -n "$script_path" ]] && script_dir=$(cd "$(dirname "$script_path")" 2>/dev/null && pwd -P)

    case "$shell" in
      bash) name="completions/bash/denon" ;;
      zsh) name="completions/zsh/_denon" ;;
      fish) name="completions/fish/denon.fish" ;;
      *) return 1 ;;
    esac

    if [[ -n "$script_dir" && -r "$script_dir/$name" ]]; then
      printf '%s\n' "$script_dir/$name"
      return 0
    fi

    case "$shell" in
      bash)
        for path in /usr/local/share/bash-completion/completions/denon /usr/share/bash-completion/completions/denon; do
          [[ -r "$path" ]] && { printf '%s\n' "$path"; return 0; }
        done
        ;;
      zsh)
        for path in /usr/local/share/zsh/site-functions/_denon /usr/share/zsh/site-functions/_denon; do
          [[ -r "$path" ]] && { printf '%s\n' "$path"; return 0; }
        done
        ;;
      fish)
        for path in /usr/local/share/fish/vendor_completions.d/denon.fish /usr/share/fish/vendor_completions.d/denon.fish; do
          [[ -r "$path" ]] && { printf '%s\n' "$path"; return 0; }
        done
        ;;
    esac

    return 1
  }

  _denon_completion_fallback() {
    local shell="$1"
    case "$shell" in
      bash)
        cat <<'EOF'
# bash completion for denon-avr-controller
_denon_complete() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  local top_cmds="status info data rawstatus raw signal-debug snapshot diff dashboard dashboard-alt dashboard-ultra on off vol up down mute unmute toggle source sources rename-source source-names clear-source-name zone2 heos movie game music night mode dyn-eq dyn-vol cinema-eq multeq bass treble play pause stop next prev previous track now sleep qs preset watch-event discover setip doctor config profile completion version help xbox xfinity bluray tv phono"
  case "$prev" in
    denon) COMPREPLY=( $(compgen -W "$top_cmds" -- "$cur") ); return ;;
    completion) COMPREPLY=( $(compgen -W "bash zsh fish install" -- "$cur") ); return ;;
    install) COMPREPLY=( $(compgen -W "--shell --force" -- "$cur") ); return ;;
    --shell) COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") ); return ;;
  esac
}
complete -F _denon_complete denon
EOF
        ;;
      zsh)
        cat <<'EOF'
#compdef denon
_denon() {
  local -a top_cmds completion_cmds install_opts shells
  top_cmds=(status info data rawstatus raw signal-debug snapshot diff dashboard dashboard-alt dashboard-ultra on off vol up down mute unmute toggle source sources rename-source source-names clear-source-name zone2 heos movie game music night mode dyn-eq dyn-vol cinema-eq multeq bass treble play pause stop next prev previous track now sleep qs preset watch-event discover setip doctor config profile completion version help xbox xfinity bluray tv phono)
  completion_cmds=(bash zsh fish install)
  install_opts=(--shell --force)
  shells=(bash zsh fish)
  if (( CURRENT == 2 )); then
    compadd -- "${top_cmds[@]}"
  elif [[ ${words[2]} == completion && $CURRENT == 3 ]]; then
    compadd -- "${completion_cmds[@]}"
  elif [[ ${words[2]} == completion && ${words[3]} == install && ${words[CURRENT-1]} == --shell ]]; then
    compadd -- "${shells[@]}"
  elif [[ ${words[2]} == completion && ${words[3]} == install ]]; then
    compadd -- "${install_opts[@]}"
  fi
}
_denon "$@"
EOF
        ;;
      fish)
        cat <<'EOF'
# fish completion for denon-avr-controller
set -l denon_commands status info data rawstatus raw signal-debug snapshot diff dashboard dashboard-alt dashboard-ultra on off vol up down mute unmute toggle source sources rename-source source-names clear-source-name zone2 heos movie game music night mode dyn-eq dyn-vol cinema-eq multeq bass treble play pause stop next prev previous track now sleep qs preset watch-event discover setip doctor config profile completion version help xbox xfinity bluray tv phono
complete -c denon -f
complete -c denon -n "__fish_use_subcommand" -a "$denon_commands"
complete -c denon -n "__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish install" -a "bash zsh fish install"
complete -c denon -n "__fish_seen_subcommand_from completion; and __fish_seen_subcommand_from install" -l shell -xa "bash zsh fish"
complete -c denon -n "__fish_seen_subcommand_from completion; and __fish_seen_subcommand_from install" -l force
EOF
        ;;
      *) return 1 ;;
    esac
  }

  _denon_completion_print() {
    local shell="$1"
    local path
    path=$(_denon_completion_source_path "$shell" 2>/dev/null || printf '')
    if [[ -n "$path" ]]; then
      cat "$path"
    else
      _denon_completion_fallback "$shell"
    fi
  }

  _denon_completion_detect_shell() {
    local explicit="$1"
    local shell_name parent_name

    if [[ -n "$explicit" ]]; then
      case "$explicit" in
        bash|zsh|fish) printf '%s\n' "$explicit"; return 0 ;;
        *) echo "Error: unsupported shell '$explicit' (expected bash, zsh, or fish)" >&2; return 1 ;;
      esac
    fi

    shell_name=$(basename "${SHELL:-}" 2>/dev/null || printf '')
    case "$shell_name" in
      bash|zsh|fish) printf '%s\n' "$shell_name"; return 0 ;;
    esac

    if command -v ps >/dev/null 2>&1; then
      parent_name=$(ps -p "${PPID:-0}" -o comm= 2>/dev/null | awk '{print $1}' | xargs basename 2>/dev/null || printf '')
      case "$parent_name" in
        bash|zsh|fish) printf '%s\n' "$parent_name"; return 0 ;;
      esac
    fi

    echo "Error: could not detect shell; rerun with --shell bash, --shell zsh, or --shell fish" >&2
    return 1
  }

  _denon_completion_install_path() {
    local shell="$1"
    case "$shell" in
      bash) printf '%s/.local/share/bash-completion/completions/denon\n' "$HOME" ;;
      zsh) printf '%s/.local/share/zsh/site-functions/_denon\n' "$HOME" ;;
      fish) printf '%s/.config/fish/completions/denon.fish\n' "$HOME" ;;
      *) return 1 ;;
    esac
  }

  _denon_completion_reload_note() {
    local shell="$1"
    local path="$2"
    case "$shell" in
      bash) printf 'Restart your shell, or run: source %s\n' "$path" ;;
      zsh)
        printf 'Restart your shell, or run: autoload -Uz compinit && compinit\n'
        printf 'Note: ensure %s is in your zsh fpath.\n' "$(dirname "$path")"
        ;;
      fish) printf 'Restart fish, or run: source %s\n' "$path" ;;
    esac
  }

  _denon_completion_install() {
    local shell="" force=0 arg target tmp
    while (($#)); do
      arg="$1"
      case "$arg" in
        --shell)
          if [[ -z "${2:-}" ]]; then
            echo "Error: --shell requires bash, zsh, or fish" >&2
            return 2
          fi
          shell="$2"
          shift 2
          ;;
        --shell=*)
          shell="${arg#--shell=}"
          shift
          ;;
        --force)
          force=1
          shift
          ;;
        -h|--help|help)
          cat <<'EOF'
Usage: denon completion install [--shell bash|zsh|fish] [--force]

Install shell completion for the current user.
EOF
          return 0
          ;;
        *)
          echo "Error: unknown completion install option: $arg" >&2
          return 2
          ;;
      esac
    done

    shell=$(_denon_completion_detect_shell "$shell") || return 1
    target=$(_denon_completion_install_path "$shell") || return 1
    mkdir -p "$(dirname "$target")" || return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/denon-completion.XXXXXX") || return 1
    _denon_completion_print "$shell" >"$tmp" || { rm -f "$tmp"; return 1; }

    if [[ -e "$target" ]]; then
      if cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        printf 'Completion already installed: %s\n' "$target"
        _denon_completion_reload_note "$shell" "$target"
        return 0
      fi
      if (( ! force )); then
        rm -f "$tmp"
        printf 'Completion file already exists and differs: %s\n' "$target" >&2
        printf 'Rerun with --force to overwrite it.\n' >&2
        return 1
      fi
    fi

    mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$target" 2>/dev/null || true
    printf 'Installed %s completion: %s\n' "$shell" "$target"
    _denon_completion_reload_note "$shell" "$target"
  }

  _denon_completion_cmd() {
    local subcmd
    subcmd=$(_denon_lower "${1:-}")
    case "$subcmd" in
      ""|-h|--help|help)
        _denon_completion_usage
        ;;
      bash|zsh|fish)
        _denon_completion_print "$subcmd"
        ;;
      install)
        _denon_completion_install "${@:2}"
        ;;
      *)
        _denon_completion_usage >&2
        return 1
        ;;
    esac
  }

  # ── Init ──────────────────────────────────────────────────────────────────

  if [[ -n "${DENON_PROFILE:-}" ]]; then
    _denon_validate_stored_name "profile" "$DENON_PROFILE" || return 1
    _denon_load_config "$(_denon_profile_dir)/${DENON_PROFILE}"
  fi
  _denon_load_config

  local _arg _quiet=0 _silent=0 _no_verify="${DENON_NO_VERIFY_ACTIVE:-0}" DENON_NO_VERIFY_ACTIVE
  local -a _quiet_args=()
  for _arg in "$@"; do
    case "$_arg" in
      --quiet|-q) _quiet=1 ;;
      --silent) _silent=1 ;;
      --no-verify) _no_verify=1 ;;
      *) _quiet_args+=("$_arg") ;;
    esac
  done
  if (( _silent )); then
    DENON_NO_VERIFY_ACTIVE="$_no_verify" denon "${_quiet_args[@]+"${_quiet_args[@]}"}" >/dev/null 2>&1
    return $?
  fi
  if (( _quiet )); then
    DENON_NO_VERIFY_ACTIVE="$_no_verify" denon "${_quiet_args[@]+"${_quiet_args[@]}"}" >/dev/null
    return $?
  fi
  DENON_NO_VERIFY_ACTIVE="$_no_verify"
  set -- "${_quiet_args[@]+"${_quiet_args[@]}"}"

  if declare -F denon_v2_global_flags >/dev/null 2>&1; then
    denon_v2_global_flags "$@" || return $?
    set -- "${DENON_V2_ARGS[@]+"${DENON_V2_ARGS[@]}"}"
  fi

  local cmd
  cmd=$(_denon_lower "$1")

  case "$cmd" in
    ""|-h|--help|help)
      _denon_usage
      return 0
      ;;
    version|--version|-V)
      printf '%s\n' "${DENON_CONTROLLER_VERSION:-unknown}"
      return 0
      ;;
    setip)
      if [[ -z "$2" ]] || ! _denon_is_ipv4 "$2"; then
        echo "Error: setip requires an IPv4 address, for example: denon setip 192.0.2.10" >&2
        return 1
      fi
      mkdir -p "$HOME/.cache"
      local cache
      cache=$(_denon_ip_cache_path) || return 1
      printf '%s' "$2" >"$cache"
      if _denon_is_receiver "$2"; then
        echo "Saved receiver IP: $2"
      else
        echo "Saved receiver IP: $2"
        echo "Warning: $2 did not respond as a Denon receiver right now" >&2
      fi
      return 0
      ;;
    doctor)
      _denon_doctor
      return $?
      ;;
    diff)
      _denon_snapshot_diff "$2" "$3"
      return $?
      ;;
    config)
      _denon_config_cmd "${@:2}"
      return $?
      ;;
    completion)
      _denon_completion_cmd "${@:2}"
      return $?
      ;;
    profile)
      _denon_profile_cmd "${@:2}"
      return $?
      ;;
    dashboard-alt)
      _denon_dashboard_alt "${@:2}"
      return $?
      ;;
    dashboard-ultra)
      ;;
    discover)
      local cache
      cache=$(_denon_ip_cache_path) || return 1
      rm -f "$cache"
      local new_ip
      new_ip=$(_denon_discover)
      if [[ -n "$new_ip" ]]; then
        echo "Found receiver at $new_ip"
      else
        echo "No receiver found" >&2
        return 1
      fi
      return 0
      ;;
    info|data|status|signal-debug|rawstatus|raw|snapshot|dashboard|sources|source|rename-source|source-names|clear-source-name|sleep|qs|on|off|xbox|xfinity|bluray|tv|phono|heos|vol|up|down|mute|unmute|toggle|movie|game|night|music|mode|dyn-eq|dyn-vol|cinema-eq|multeq|bass|treble|play|pause|stop|next|prev|previous|track|now|zone2|watch-event|preset)
      ;;
    *)
      _denon_usage
      return 1
      ;;
  esac

  if declare -F denon_v2_handles >/dev/null 2>&1 && denon_v2_handles "$cmd" "${@:2}"; then
    denon_v2_dispatch "$cmd" "${@:2}"
    return $?
  fi

  if [[ "$cmd" == "raw" ]]; then
    case "$(_denon_lower "${2:-}")" in
      types)
        _denon_raw_types
        return $?
        ;;
      help|-h|--help|"")
        echo "Usage: denon raw {get <type>|set <type> <xml payload>|dump [type ...]|types|<protocol command> [--http]}" >&2
        return 0
        ;;
    esac
  fi

  local IP="" BASE=""
  if [[ "$cmd" == "data" ]] && _denon_data_requires_receiver "${@:2}"; then
    IP=$(_denon_data_target_ip) || return 1
    BASE="https://$IP:10443"
  elif [[ "$cmd" != "data" ]]; then
    IP=$(_denon_discover)
    if [[ -z "$IP" ]]; then
      echo "Error: Could not find Denon receiver on network" >&2
      return 1
    fi
    BASE="https://$IP:10443"
  fi

  local _write_lock_active=0
  if _denon_write_command_requires_lock "$cmd" "${@:2}"; then
    _denon_acquire_write_lock
    local _lock_status=$?
    if (( _lock_status != 0 )); then
      return "$_lock_status"
    fi
    [[ -n "${DENON_WRITE_LOCK_FD:-}" ]] && _write_lock_active=1
  fi

  # ── Commands ──────────────────────────────────────────────────────────────

  case "$cmd" in
    info)
      _denon_info "$2"
      ;;

    data)
      _denon_data_cmd "${@:2}"
      ;;

    status)
      if [[ "$(_denon_lower "$2")" == "--json" || "$(_denon_lower "$2")" == "json" ]]; then
        _denon_status_json
      else
        _denon_status_pretty
      fi
      ;;

    signal-debug)
      _denon_signal_debug
      ;;

    rawstatus)
      _denon_get_power_xml; echo
      _denon_get_source_xml; echo
      _denon_get_vol_xml; echo
      ;;

    raw)
      local raw_cmd
      raw_cmd=$(_denon_lower "$2")
      case "$raw_cmd" in
        get) _denon_raw_get "$3" ;;
        set) _denon_raw_set "$3" "${*:4}" ;;
        dump) _denon_raw_dump "${@:3}" ;;
        types) _denon_raw_types ;;
        *) echo "Usage: denon raw {get <type>|set <type> <xml payload>|dump [type ...]|types}" >&2; return 1 ;;
      esac
      ;;

    snapshot)
      _denon_snapshot "$2"
      ;;

    dashboard)
      _denon_dashboard "${@:2}"
      ;;

    dashboard-ultra)
      _denon_dashboard_ultra "${@:2}"
      ;;

    sources)
      _denon_sources "${@:2}"
      ;;

    source)
      _denon_set_source "$2" "1" "${@:3}"
      ;;

    sleep)
      _denon_sleep_timer 1 "$2"
      ;;

    qs|quick|quick-select)
      _denon_quick_select "$2" "$3"
      ;;

    rename-source)
      local new_name="${*:3}"
      _denon_set_source_alias "1" "$2" "$new_name"
      ;;
    source-names)
      _denon_source_aliases
      ;;
    clear-source-name)
      _denon_clear_source_alias "1" "$2"
      ;;

    on)
      _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>' || return 1
      _denon_status_pretty
      ;;
    off)
      _denon_set_config 4 '<MainZone><Power>3</Power></MainZone>' || return 1
      _denon_status_pretty
      ;;

    xbox) _denon_set_source "xbox" "1" ;;
    xfinity) _denon_set_source "xfinity x1" "1" ;;
    bluray) _denon_set_source "blu-ray" "1" ;;
    tv) _denon_set_source "tv audio" "1" ;;
    phono) _denon_set_source "phono" "1" ;;
    heos)
      if [[ -z "${2:-}" ]]; then
        _denon_set_source "heos music" "1"
      else
        _denon_heos_helper "${@:2}" || return 1
      fi
      ;;

    vol)
      if [[ -z "$2" ]]; then
        local xml raw_vol mute db mute_str
        xml=$(_denon_get_vol_xml) || return 1
        raw_vol=$(_denon_extract_main_volume_raw "$xml")
        mute=$(_denon_extract_main_mute "$xml")
        if [[ -n "$raw_vol" ]]; then
          db=$(_denon_raw_to_db "$raw_vol")
        else
          db="Unknown"
        fi
        mute_str=$([[ "$mute" == "1" ]] && echo " [MUTED]" || echo "")
        printf 'Volume: %s dB%s\n' "$db" "$mute_str"
      elif [[ "$2" == "--fade" || "$2" == "fade" ]]; then
        _denon_fade_volume "${@:3}"
      else
        if _denon_is_signed_step "$2" && [[ "$2" == +* ]]; then
          _denon_change_volume "$2" "${@:3}"
        else
          _denon_set_volume_db "$2" "${@:3}"
        fi
      fi
      ;;

    up)
      local step="${2:-${DENON_VOLUME_STEP_DB:-1}}"
      step="${step#[-+]}"
      _denon_change_volume "$step" "${@:3}"
      ;;
    down)
      local step="${2:-${DENON_VOLUME_STEP_DB:-1}}"
      step="${step#[-+]}"
      _denon_change_volume "-$step" "${@:3}"
      ;;

    mute)
      _denon_set_config 12 '<MainZone><Mute>1</Mute></MainZone>' || return 1
      echo "Muted"
      ;;
    unmute)
      _denon_set_config 12 '<MainZone><Mute>2</Mute></MainZone>' || return 1
      echo "Unmuted"
      ;;
    toggle)
      _denon_toggle "$2"
      ;;

    movie)
      _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>' || return 1
      _denon_set_source "${DENON_MOVIE_SOURCE:-tv audio}" "1" >/dev/null || return 1
      _denon_set_volume_db "${DENON_MOVIE_VOLUME_DB:--32}" || return 1
      _denon_sound_mode "${DENON_MOVIE_MODE:-movie}" >/dev/null || true
      _denon_status_pretty
      ;;
    game)
      _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>' || return 1
      _denon_set_source "${DENON_GAME_SOURCE:-xbox}" "1" >/dev/null || return 1
      _denon_set_volume_db "${DENON_GAME_VOLUME_DB:--30}" || return 1
      _denon_sound_mode "${DENON_GAME_MODE:-game}" >/dev/null || true
      _denon_status_pretty
      ;;
    night)
      _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>' || return 1
      _denon_set_source "${DENON_NIGHT_SOURCE:-tv audio}" "1" >/dev/null || return 1
      _denon_set_volume_db "${DENON_NIGHT_VOLUME_DB:--45}" || return 1
      _denon_status_pretty
      ;;
    music)
      _denon_set_config 4 '<MainZone><Power>1</Power></MainZone>' || return 1
      _denon_set_source "${DENON_MUSIC_SOURCE:-heos music}" "1" >/dev/null || return 1
      _denon_set_volume_db "${DENON_MUSIC_VOLUME_DB:--35}" || return 1
      _denon_sound_mode "${DENON_MUSIC_MODE:-music}" >/dev/null || true
      _denon_status_pretty
      ;;

    mode)
      _denon_sound_mode "$2" "${@:3}"
      ;;
    dyn-eq)
      _denon_audyssey_toggle "Dynamic EQ" "$2" "PSDYNEQ"
      ;;
    dyn-vol)
      _denon_dynamic_volume "$2"
      ;;
    cinema-eq)
      _denon_cinema_eq "$2"
      ;;
    multeq)
      _denon_multeq "$2"
      ;;
    bass)
      _denon_tone_control bass "$2"
      ;;
    treble)
      _denon_tone_control treble "$2"
      ;;
    play|pause|stop|next|prev|previous)
      _denon_heos_control "$cmd"
      ;;
    track|now)
      _denon_track
      ;;

    zone2)
      local zone2_cmd
      zone2_cmd=$(_denon_lower "$2")
      case "$zone2_cmd" in
        status)
          _denon_zone_status_pretty 2
          ;;
        sources)
          _denon_sources "2"
          ;;
        source)
          _denon_set_source "$3" "2" "${@:4}"
          ;;
        rename-source)
          local zn="${*:4}"
          _denon_set_source_alias "2" "$3" "$zn"
          ;;
        clear-source-name)
          _denon_clear_source_alias "2" "$3"
          ;;
        on)
          _denon_set_config 4 '<Zone2><Power>1</Power></Zone2>' || return 1
          _denon_zone_status_pretty 2
          ;;
        off)
          _denon_set_config 4 '<Zone2><Power>3</Power></Zone2>' || return 1
          _denon_zone_status_pretty 2
          ;;
        mute)
          _denon_set_config 12 '<Zone2><Mute>1</Mute></Zone2>' || return 1
          echo "Zone 2 muted"
          ;;
        unmute)
          _denon_set_config 12 '<Zone2><Mute>2</Mute></Zone2>' || return 1
          echo "Zone 2 unmuted"
          ;;
        vol|volume)
          if [[ -z "$3" ]]; then
            echo "Error: zone2 vol requires the raw Zone 2 volume value, for example: denon zone2 vol 650" >&2
            return 1
          fi
          _denon_set_zone2_volume_raw "$3" || return 1
          _denon_zone_status_pretty 2
          ;;
        up)
          local step="${3:-${DENON_VOLUME_STEP_DB:-1}}"
          step="${step#[-+]}"
          _denon_zone2_change_volume "$step"
          ;;
        down)
          local step="${3:-${DENON_VOLUME_STEP_DB:-1}}"
          step="${step#[-+]}"
          _denon_zone2_change_volume "-$step"
          ;;
        sleep)
          _denon_sleep_timer 2 "$3"
          ;;
        *)
          echo "Usage: denon zone2 {status|sources|source <id|name>|rename-source <id|name> <new name>|clear-source-name <id|name>|on|off|mute|unmute|vol <raw>|volume <raw>|up [dB]|down [dB]|sleep [minutes|off]}" >&2
          return 1
          ;;
      esac
      ;;

    watch-event)
      _denon_watch_event "$2" "$3" "${@:4}"
      ;;

    preset)
      _denon_preset_cmd "$2" "$3"
      ;;

    *)
      _denon_usage
      if (( _write_lock_active )); then
        _denon_release_write_lock
      fi
      return 1
      ;;
  esac
  local _cmd_status=$?

  if (( _write_lock_active )); then
    _denon_release_write_lock
  fi
  return "$_cmd_status"
}

# shellcheck disable=SC2034,SC2153,SC2154
_denon_completion() {
  local -a commands modes zone2_commands raw_commands json_flags global_flags zones heos_commands onoff dyn_volumes multeq_modes tone_commands repeat_modes
  commands=(
    info data status signal-debug rawstatus raw snapshot diff sources source rename-source source-names clear-source-name
    sleep qs quick quick-select
    on off xbox xfinity bluray tv phono heos vol up down mute unmute toggle movie game night music mode
    dyn-eq dyn-vol cinema-eq multeq bass treble
    play pause stop next prev previous track now dashboard dashboard-alt zone2 preset watch-event discover doctor setip config profile completion help
  )
  modes=(stereo direct pure movie music game auto)
  zone2_commands=(status sources source rename-source clear-source-name on off mute unmute vol volume up down sleep)
  raw_commands=(get set dump types)
  json_flags=(--json)
  global_flags=(--quiet --silent --no-verify)
  zones=(1 2)
  heos_commands=(now play pause stop next prev queue groups group browse search play-stream repeat shuffle update)
  onoff=(on off)
  dyn_volumes=(off light medium heavy)
  multeq_modes=(reference bypass-lr flat manual off)
  tone_commands=(up down)
  repeat_modes=(off all one)

  if (( CURRENT == 2 )); then
    _describe -t commands 'denon command' commands
    _describe -t global-flags 'global flag' global_flags
    return
  fi

  case "${words[2]}" in
    info|status)
      _describe -t json-flags 'json flag' json_flags
      return
      ;;
    data)
      if (( CURRENT == 3 )); then
        _values 'data subcommand' fields dump discover capabilities discover-capabilities verbs summary
        return
      fi
      case "${words[3]}" in
        fields)
          _values 'data fields mode' --all --available
          return
          ;;
        dump)
          _values 'data dump mode' --readable --all --json --raw
          return
          ;;
        discover)
          _values 'data discover mode' --json
          return
          ;;
        capabilities|discover-capabilities|verbs)
          _values 'data capabilities options' --json --source --probe-safe --help
          return
          ;;
        summary)
          _values 'data summary options' --json
          return
          ;;
      esac
      ;;
    mode)
      _describe -t modes 'sound mode' modes
      return
      ;;
    dyn-eq|cinema-eq|shuffle)
      _describe -t onoff 'state' onoff
      return
      ;;
    dyn-vol)
      _describe -t dynamic-volumes 'dynamic volume' dyn_volumes
      return
      ;;
    multeq)
      _describe -t multeq-modes 'MultEQ mode' multeq_modes
      return
      ;;
    bass|treble)
      _describe -t tone-commands 'tone command' tone_commands
      return
      ;;
    repeat)
      _describe -t repeat-modes 'repeat mode' repeat_modes
      return
      ;;
    heos)
      if (( CURRENT == 3 )); then
        _describe -t heos-commands 'HEOS command' heos_commands
        return
      fi
      ;;
    zone2)
      if (( CURRENT == 3 )); then
        _describe -t zone2-commands 'zone2 command' zone2_commands
        return
      fi
      ;;
    raw)
      if (( CURRENT == 3 )); then
        _describe -t raw-commands 'raw command' raw_commands
        return
      fi
      ;;
    completion)
      if (( CURRENT == 3 )); then
        _values 'completion command' bash zsh fish install
        return
      fi
      if [[ "${words[3]}" == "install" ]]; then
        if [[ "${words[CURRENT-1]}" == "--shell" ]]; then
          _values 'shell' bash zsh fish
        else
          _values 'completion install option' --shell --force
        fi
        return
      fi
      ;;
    sources)
      _describe -t zones 'zone' zones
      return
      ;;
    vol|up|down)
      _message 'dB value'
      return
      ;;
    setip)
      _message 'receiver IPv4 address'
      return
      ;;
  esac

  return 1
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  compdef _denon_completion denon 2>/dev/null || true
fi

_denon_is_sourced() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    [[ "${ZSH_EVAL_CONTEXT:-}" == *:file || "${ZSH_EVAL_CONTEXT:-}" == *:file:* ]]
    return
  fi
  [[ "${BASH_SOURCE[0]:-}" != "$0" ]]
}

# When DENON_UNIT_TEST=1 the script is sourced by pytest. Calling denon() with
# no arguments causes all nested helper functions to be registered in global
# scope (Bash promotes nested function definitions once the outer function runs)
# and exits via the help branch — no network I/O occurs.
if [[ -n "${DENON_UNIT_TEST:-}" ]]; then
  denon >/dev/null 2>&1 || true
fi

if ! _denon_is_sourced; then
  denon "$@"
fi
