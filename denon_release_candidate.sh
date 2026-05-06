#!/usr/bin/env bash
# denon_release_candidate.sh — Denon AVR controller
# Version: 1.0.0
# Source this from ~/.zshrc or ~/.bashrc:
#   source ~/denon_release_candidate.sh
#
# Or run it directly:
#   ./denon_release_candidate.sh status
#
# For testing without discovery:
#   export DENON_IP=192.168.1.162

_denon_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
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

  _denon_discover() {
    local cache="$HOME/.cache/denon_ip"
    local default_ip="${DENON_DEFAULT_IP:-}"
    local ip=""

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
        if _denon_is_receiver "$cached_ip"; then
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

  _denon_is_number() {
    printf '%s' "$1" | awk '/^-?[0-9]+([.][0-9]+)?$/ { found=1 } END { exit found ? 0 : 1 }'
  }

  _denon_is_signed_step() {
    printf '%s' "$1" | awk '/^[+-][0-9]+([.][0-9]+)?$/ { found=1 } END { exit found ? 0 : 1 }'
  }

  _denon_usage() {
    cat <<'EOF'
Denon AVR controller

Usage:
  denon <command> [arguments]
  denon_release_candidate.sh <command> [arguments]

Receiver status:
  denon info                 Show receiver name, IP, main zone, Zone 2, and sources
  denon info --json          Print detailed receiver information as JSON
  denon status               Show main zone power, source, volume, and mute state
  denon status --json        Print main zone status as JSON
  denon signal-debug         Show raw input/signal diagnostics without guessing a decoder
  denon rawstatus            Print raw XML returned by the AVR
  denon raw get <type>       Fetch a raw get_config type, for example 3, 4, 7, 12
  denon raw set <type> '<xml>'
                             Send a raw set_config payload
  denon snapshot [dir]       Save core XML responses to a timestamped directory
  denon diff <snap-a> <snap-b>
                             Compare two snapshot directories
  denon doctor               Check dependencies, route, cache, and receiver reachability
  denon dashboard [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]
                             Show a one-shot or live receiver dashboard

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

Configuration:
  DENON_IP
  DENON_DEFAULT_IP
  DENON_SCAN_LAN=1
  DENON_MAX_VOLUME_DB
  DENON_VOLUME_STEP_DB
  DENON_SOURCE_ALIASES
  DENON_CURL_CONNECT_TIMEOUT
  DENON_CURL_MAX_TIME
  DENON_CACHE_TTL_SECONDS
  DENON_SSDP_TIMEOUT
  DENON_SSDP_MX
  DENON_HEOS_PID
  DENON_HEOS_GID
  DENON_HEOS_HELPER
  DENON_HEOS_TIMEOUT
  DENON_DEBUG=1

Notes:
  Commands are case-insensitive.
  Source display names are local aliases; they do not rename sources inside the receiver.
  The script can be run directly or sourced from bash/zsh.
  Pass --quiet or -q before or after any command to suppress stdout output.
  Pass --silent before or after any command to suppress both stdout and stderr.
EOF
  }

  # ── Internal helpers ──────────────────────────────────────────────────────

  _denon_debug() {
    [[ "${DENON_DEBUG:-0}" == "1" ]] || return 0
    printf '[denon] %s\n' "$*" >&2
  }

  _denon_curl() {
    local connect_timeout="${DENON_CURL_CONNECT_TIMEOUT:-2}"
    local max_time="${DENON_CURL_MAX_TIME:-4}"
    _denon_debug "curl $*"
    curl -ksS --connect-timeout "$connect_timeout" --max-time "$max_time" "$@"
  }

  _denon_get_config() {
    local type="$1"
    _denon_curl -G "$BASE/ajax/globals/get_config" --data-urlencode "type=$type"
  }

  _denon_set_config() {
    local type="$1"
    local data="$2"
    _denon_debug "set_config type=$type data=$data"
    _denon_curl -G "$BASE/ajax/globals/set_config" \
      --data-urlencode "type=$type" \
      --data-urlencode "data=$data" >/dev/null
  }

  _denon_get_power_xml() { _denon_get_config 4; }
  _denon_get_source_xml() { _denon_get_config 7; }
  _denon_get_vol_xml() { _denon_get_config 12; }
  _denon_get_identity_xml() { _denon_get_config 3; }

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
        gsub(backslash, backslash backslash)
        gsub(quote, backslash quote)
        gsub(tab, "\\t")
        gsub(carriage_return, "")
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
    printf '%s' "$1" | sed -n 's:.*<MainZone>.*<Mute>\([0-9]*\)</Mute>.*</MainZone>.*:\1:p'
  }

  _denon_extract_zone2_mute() {
    printf '%s' "$1" | sed -n 's:.*<Zone2>.*<Mute>\([0-9]*\)</Mute>.*</Zone2>.*:\1:p'
  }

  _denon_main_volume_raw() {
    _denon_extract_main_volume_raw "$(_denon_get_vol_xml)"
  }

  _denon_source_rows() {
    local zone="${1:-1}"
    _denon_get_source_xml |
      sed 's/></>\n</g' |
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

  _denon_alias_file() {
    printf '%s\n' "${DENON_SOURCE_ALIASES:-$HOME/.config/denon/source_aliases}"
  }

  _denon_source_rows_with_aliases() {
    local zone="${1:-1}"
    local alias_file
    alias_file=$(_denon_alias_file)
    [[ -r "$alias_file" ]] || alias_file="/dev/null"

    _denon_source_rows "$zone" |
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
    _denon_get_source_xml |
      sed 's/></>\n</g' |
      awk -v zone="$zone" -v idx="$source_idx" '
        $0 ~ "<Zone zone=\"" zone "\" " { in_zone=1; next }
        in_zone && /<\/Zone>/ { in_zone=0 }
        in_zone && $0 ~ "<Source index=\"" idx "\">" { in_src=1; next }
        in_zone && in_src && /<Name>/ {
          sub(/^.*<Name>/, "")
          sub(/<\/Name>.*$/, "")
          print
          exit
        }
        in_zone && in_src && /<\/Source>/ { in_src=0 }
      '
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
    local source_idx current_idx source_name

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

    if ! _denon_wait_for_source "$zone" "$source_idx" 20; then
      echo "Error: source change to zone $zone source $source_idx was not confirmed" >&2
      return 1
    fi

    source_name=$(_denon_alias_for_source "$zone" "$source_idx" || _denon_source_name_by_idx "$zone" "$source_idx" || printf '%s' "$source_idx")
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
    local raw verified_raw

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

    verified_raw=$(_denon_main_volume_raw)
    if [[ "$verified_raw" != "$raw" ]]; then
      echo "Warning: requested volume ${db} dB, but receiver now reports raw=${verified_raw:-unknown}" >&2
    fi

    printf 'Volume set to %s dB\n' "$db"
  }

  _denon_fade_volume() {
    local target="" duration=10 arg
    while [[ $# -gt 0 ]]; do
      arg="$1"
      case "$arg" in
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
    echo "Volume faded to ${target} dB"
  }

  _denon_change_volume() {
    local delta="$1"
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
    _denon_set_volume_db "$target_db"
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
    new_raw=$(awk -v db="$target_db" 'BEGIN { raw=int((db+80)*10+0.5); if(raw<0)raw=0; if(raw>980)raw=980; print raw }')
    _denon_set_config 12 "<Zone2><Volume>${new_raw}</Volume></Zone2>" || return 1
    _denon_zone_status_pretty 2
  }

  _denon_telnet() {
    local command="$1"
    if command -v nc >/dev/null 2>&1; then
      _denon_debug "telnet $IP:23 $command"
      printf '%s\r' "$command" | nc -w 2 "$IP" 23 >/dev/null
      return $?
    fi
    echo "Error: nc is required for this command" >&2
    return 1
  }

  _denon_telnet_query() {
    local command="$1"
    command -v nc >/dev/null 2>&1 || {
      echo "Error: nc is required for this command" >&2
      return 1
    }
    _denon_debug "telnet query $IP:23 $command"
    {
      printf '%s\r' "$command"
      sleep 0.15
    } | nc -w 2 "$IP" 23 2>/dev/null
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
    local mode code
    mode=$(_denon_lower "$1")
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
    _denon_telnet "$code" && echo "Sound mode set to $mode"
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
    local action="$1" code
    case "$action" in
      play) code="NS9A" ;;
      pause) code="NS9B" ;;
      stop) code="NS9C" ;;
      next) code="NS9D" ;;
      prev|previous) code="NS9E" ;;
      *) return 1 ;;
    esac
    _denon_telnet "$code" && echo "Sent $action"
  }

  _denon_heos_helper() {
    local helper script_path script_dir
    script_path=$(_denon_script_path) || script_path="$PWD/denon_release_candidate.sh"
    script_dir=$(cd "$(dirname "$script_path")" 2>/dev/null && pwd)
    helper="${DENON_HEOS_HELPER:-${script_dir:-$PWD}/denon_heos_helper.py}"
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
    [[ "$1" == "1" ]] && echo "yes" || echo "no"
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
    muted=$(_denon_bool_name "$mute")
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
    local pretty_db json_db friendly_json main_source_json zone2_source_json

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
    mute=$(_denon_extract_main_mute "$vol_xml")
    zone2_mute=$(_denon_extract_zone2_mute "$vol_xml")

    main_source_name=$(_denon_alias_for_source "1" "$main_source_idx" || _denon_source_name_by_idx "1" "$main_source_idx")
    zone2_source_name=$(_denon_alias_for_source "2" "$zone2_source_idx" || _denon_source_name_by_idx "2" "$zone2_source_idx")

    power=$(_denon_power_name "$power_code")
    zone2_power=$(_denon_power_name "$zone2_power_code")
    muted=$(_denon_bool_name "$mute")
    zone2_muted=$(_denon_bool_name "$zone2_mute")

    if [[ -n "$raw_vol" ]]; then
      pretty_db=$(_denon_raw_to_db "$raw_vol")
      json_db="$pretty_db"
    else
      pretty_db="Unknown"
      json_db="null"
    fi

    if [[ "$format" == "--json" || "$format" == "json" ]]; then
      friendly_json=$(printf '%s' "${friendly_name:-Unknown}" | _denon_json_escape)
      main_source_json=$(printf '%s' "${main_source_name:-Unknown}" | _denon_json_escape)
      zone2_source_json=$(printf '%s' "${zone2_source_name:-Unknown}" | _denon_json_escape)
      printf '{"receiver":"%s","ip":"%s","mainZone":{"power":"%s","sourceIndex":%s,"sourceName":"%s","volumeDb":%s,"muted":%s},"zone2":{"power":"%s","sourceIndex":%s,"sourceName":"%s","volumeRaw":%s,"muted":%s}}\n' \
        "$friendly_json" "$IP" "$power" "${main_source_idx:-null}" "$main_source_json" "$json_db" "$([[ "$muted" == "yes" ]] && echo true || echo false)" \
        "$zone2_power" "${zone2_source_idx:-null}" "$zone2_source_json" "${raw_zone2_vol:-null}" "$([[ "$zone2_muted" == "yes" ]] && echo true || echo false)"
      return 0
    fi

    echo "Receiver: ${friendly_name:-Unknown}"
    echo "IP: $IP"
    echo "Main Zone Power: $power"
    echo "Main Zone Source: ${main_source_name:-Unknown} (${main_source_idx:-unknown})"
    echo "Main Zone Volume: $pretty_db dB"
    echo "Main Zone Muted: $muted"
    echo "Zone 2 Power: $zone2_power"
    echo "Zone 2 Source: ${zone2_source_name:-Unknown} (${zone2_source_idx:-unknown})"
    echo "Zone 2 Volume Raw: ${raw_zone2_vol:-Unknown}"
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
    mute=$(_denon_extract_main_mute "$vol_xml")
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
    mute_str=$([[ "$mute" == "1" ]] && echo " [MUTED]" || echo "")

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
    mute=$(_denon_extract_main_mute "$vol_xml")
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

    muted_json=$([[ "$mute" == "1" ]] && echo "true" || echo "false")
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
    _denon_set_config "$type" "$data"
    echo "Sent raw set_config type=$type"
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
      echo "generated_at=$(date -Is 2>/dev/null || date)"
    } >"$outdir/metadata.txt"
    echo "Snapshot saved to $outdir"
  }

  _denon_normalize_xml() {
    sed 's/></>\n</g' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
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

  _denon_ms_now() {
    date +%s%3N 2>/dev/null || echo 0
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
    local cache="$HOME/.cache/denon_ip"
    local default_ip="${DENON_DEFAULT_IP:-}"
    local cached_ip=""
    local route_target=""
    local exit_status=0

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
    echo "  DENON_SSDP_TIMEOUT:    ${DENON_SSDP_TIMEOUT:-2}"
    echo "  DENON_SSDP_MX:         ${DENON_SSDP_MX:-1}"
    if [[ -f "$cache" ]]; then
      cached_ip=$(<"$cache")
      echo "  Cache:                 $cache -> $cached_ip"
    else
      echo "  Cache:                 $cache -> missing"
    fi
    echo

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
        Receiver) dash_receiver="$value" ;;
        IP) dash_ip="$value" ;;
        "Main Zone Power") dash_main_power="$value" ;;
        "Main Zone Source")
          dash_main_source=$(_denon_clean_source_name "$value")
          dash_main_source_index=$(printf '%s' "$value" | sed -n 's/^.*(\([0-9][0-9]*\))[[:space:]]*$/\1/p')
          ;;
        "Main Zone Volume") dash_main_volume=${value% dB} ;;
        "Main Zone Muted") dash_main_muted="$value" ;;
        "Zone 2 Power") dash_zone2_power="$value" ;;
        "Zone 2 Source")
          dash_zone2_source=$(_denon_clean_source_name "$value")
          dash_zone2_source_index=$(printf '%s' "$value" | sed -n 's/^.*(\([0-9][0-9]*\))[[:space:]]*$/\1/p')
          ;;
        "Zone 2 Volume Raw") dash_zone2_volume="$value" ;;
        "Zone 2 Muted") dash_zone2_muted="$value" ;;
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
      dash_main_muted="no"
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
    dash_zone2_muted=$(_denon_trim "$value")
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
    command -v nc >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1

    printf 'MS?\r' | timeout 2 nc "$IP" 23 2>/dev/null
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
    local players pid

    players=$(_denon_dashboard_heos_command 'heos://player/get_players')
    printf '%s\n' "$players"
    [[ "${1:-}" == "players-only" ]] && return 0
    pid=$(_denon_dashboard_json_scalar "$players" "pid")
    [[ -n "$pid" ]] || return 0

    _denon_dashboard_heos_command "heos://player/get_now_playing_media?pid=$pid"
    _denon_dashboard_heos_command "heos://player/get_play_state?pid=$pid"
  }

  _denon_dashboard_parse_heos_status() {
    local text="$1"
    local line value sid mid service

    while IFS= read -r line; do
      case "$line" in
        *'"command": "player/get_players"'*)
          value=$(_denon_dashboard_json_scalar "$line" "pid"); [[ -n "$value" ]] && dash_heos_pid="$value"
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
      dash_now_message="HEOS stopped"
    fi
  }

  _denon_dashboard_parse_now() {
    local status="$1"
    local text="$2"
    local line label value

    dash_now_title=""
    dash_now_artist=""
    dash_now_album=""
    dash_now_station=""
    dash_now_service=""
    dash_now_type=""
    dash_now_available=0

    if [[ "$status" != "0" ]]; then
      if printf '%s' "$text" | grep -qiE 'unavailable|not available|no metadata|Track info unavailable'; then
        dash_now_message="No metadata for current source"
      else
        dash_now_message=$(_denon_trim "${text:-now-playing unavailable}")
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
      dash_now_message="No metadata for current source"
    fi
  }

  _denon_dashboard_collect() {
    local info_json info_rc info_ok=0 info_text status_text zone2_text sources_text zone2_sources_text now_text now_rc
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
    dash_now_message="No metadata for current source"
    dash_now_title=""
    dash_now_artist=""
    dash_now_album=""
    dash_now_station=""
    dash_now_service=""
    # shellcheck disable=SC2034 # Parsed for dashboard diagnostics/future display; not rendered today.
    dash_now_type=""
    dash_now_available=0
    dash_errors=""
    dash_main_sources="Sources unavailable"

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
      case "$value" in true) dash_main_muted="yes" ;; false) dash_main_muted="no" ;; esac
      value=$(_denon_dashboard_json_value "$info_json" "zone2.power"); [[ -n "$value" ]] && dash_zone2_power="$value"
      value=$(_denon_dashboard_json_value "$info_json" "zone2.sourceIndex"); [[ -n "$value" ]] && dash_zone2_source_index="$value"
      value=$(_denon_dashboard_json_value "$info_json" "zone2.sourceName"); [[ -n "$value" ]] && dash_zone2_source=$(_denon_clean_source_name "$value")
      value=$(_denon_dashboard_json_value "$info_json" "zone2.volumeRaw"); [[ -n "$value" ]] && dash_zone2_volume="$value"
      value=$(_denon_dashboard_json_value "$info_json" "zone2.muted")
      case "$value" in true) dash_zone2_muted="yes" ;; false) dash_zone2_muted="no" ;; esac
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

    sources_text=$(_denon_sources 1 2>/dev/null)
    if [[ -n "$sources_text" ]]; then
      _denon_dashboard_parse_sources "1" "$sources_text"
      dash_main_sources=$(_denon_dashboard_sources_body "$sources_text")
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
  }

  _denon_dashboard_event_key() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$dash_main_power" "$dash_main_source_index:$dash_main_source" "$dash_main_muted" "$dash_main_volume" "$dash_sound_mode" \
      "$dash_zone2_power" "$dash_zone2_source_index:$dash_zone2_source" "$dash_zone2_muted" "$dash_transport_state" \
      "$dash_now_title" "$dash_now_artist"
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
    dashboard_events=$(printf '%s\n' "$dashboard_events" | sed '/^[[:space:]]*$/d' | awk 'NR <= 8')
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
    dashboard_events=$(printf '%s\n' "$dashboard_events" | sed '/^[[:space:]]*$/d' | awk 'NR <= 8')
  }

  _denon_dashboard_update_events() {
    local current_key cycle_events zone2_parts zone2_changed source_changed
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
      prev_transport_state="$dash_transport_state"
      prev_now_title="$dash_now_title"
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
      _denon_dashboard_queue_event "HEOS: ${prev_transport_state} -> ${dash_transport_state}"
    fi

    if _denon_dashboard_event_changed_known "$prev_now_title" "$dash_now_title"; then
      _denon_dashboard_queue_event "Title: ${dash_now_title}"
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
      _denon_dashboard_queue_event "Zone2: $zone2_parts"
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
    prev_transport_state="$dash_transport_state"
    prev_now_title="$dash_now_title"
  }

  _denon_dashboard_fit() {
    local text="$1"
    local width="$2"
    local max=$((width - 3))

    (( width > 0 )) || return 0
    text=${text//$'\n'/ }
    text=${text//$'\r'/ }
    if (( ${#text} > width && width > 3 )); then
      text="${text:0:max}..."
    elif (( ${#text} > width )); then
      text="${text:0:width}"
    fi
    printf "%-${width}s" "$text"
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

    if [[ -n "$dash_errors" && "$label" == "Notes" ]]; then
      echo "red"
      return
    fi

    case "$lower" in
      on|playing|play|ok|success|wired|wifi) echo "green"; return ;;
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

    if (( cols < 76 )); then
      printf '72'
    elif [[ -n "${DENON_DASHBOARD_WIDTH:-}" ]]; then
      printf '%s' "$cols"
    else
      printf '%s' $((cols - 1))
    fi
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

    if (( row == 0 )); then
      _denon_dashboard_c dim "$dash_tl"
      _denon_dashboard_c dim "$(_denon_dashboard_repeat "$dash_h" $((width - 2)))"
      _denon_dashboard_c dim "$dash_tr"
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
    elif (( row == height - 1 )); then
      _denon_dashboard_c dim "$dash_bl"
      _denon_dashboard_c dim "$(_denon_dashboard_repeat "$dash_h" $((width - 2)))"
      _denon_dashboard_c dim "$dash_br"
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

  _denon_dashboard_build_bodies() {
    dash_source_label="$dash_main_source"
    dash_zone2_source_label="$dash_zone2_source"

    if [[ -n "$dash_main_max_volume_db" ]]; then
      dash_main_volume_label="${dash_main_volume} dB / max ${dash_main_max_volume_db} dB"
    else
      dash_main_volume_label="${dash_main_volume} dB"
    fi
    dash_main_body=$(printf 'Zone:   %s\nPower:  %s\nSource: %s\nMode:   %s\nVolume: %s\nMuted:  %s' \
      "$dash_main_zone_name" "$dash_main_power" "$dash_source_label" "$dash_sound_mode" "$dash_main_volume_label" "$dash_main_muted")

    if [[ "$dash_now_available" == "1" ]]; then
      dash_now_body=$(printf 'Title:   %s\nArtist:  %s\nAlbum:   %s\nStation: %s\nService: %s\nState:   %s' \
        "${dash_now_title:-Unknown}" "${dash_now_artist:-Unknown}" "${dash_now_album:-Unknown}" \
        "${dash_now_station:-}" "${dash_now_service:-Unknown}" "${dash_transport_state:-Unknown}")
    else
      dash_now_body=$(printf '%s\nAudio metadata is unavailable for this source.' "$dash_now_message")
    fi

    if [[ -n "$dash_zone2_volume_db" && -n "$dash_zone2_volume_raw" ]]; then
      dash_zone2_volume_label="${dash_zone2_volume_db} dB (raw ${dash_zone2_volume_raw})"
    else
      dash_zone2_volume_label="$dash_zone2_volume"
    fi
    dash_receiver_body=$(printf 'Receiver: %s\nIP:       %s\nHEOS:     %s %s\n%s: %s\nSource:   %s\nVolume:   %s\nMuted:    %s' \
      "$dash_receiver" "$dash_ip" "${dash_heos_version:-Unknown}" "${dash_heos_network:-}" \
      "$dash_zone2_name" "$dash_zone2_power" "$dash_zone2_source_label" "$dash_zone2_volume_label" "$dash_zone2_muted")

    dash_events_body="${dashboard_events:-No state changes yet}"
  }

  _denon_dashboard_render_footer() {
    local width="$1"
    local footer

    footer="Updated $(date '+%H:%M:%S') | ${dash_receiver:-Unknown} @ ${dash_ip:-Unknown}"
    if [[ "${watch:-0}" == "1" ]]; then
      footer="$footer | [q] quit | [r] redraw"
    fi
    if [[ -n "$dash_errors" ]]; then
      footer="$footer | Notes: ${dash_errors%; }"
    fi
    _denon_dashboard_color_body_line "$(_denon_dashboard_fit "$footer" "$width")"
    printf '\n'
  }

  _denon_dashboard_render_narrow() {
    local width="$1"

    _denon_dashboard_render_card "Main Zone" "$dash_main_body" "$width" 10
    _denon_dashboard_render_card "Now Playing / Audio" "$dash_now_body" "$width" 10
    _denon_dashboard_render_card "Receiver / Zone 2" "$dash_receiver_body" "$width" 11
    _denon_dashboard_render_card "Main Zone Sources" "$dash_main_sources" "$width" 12
    _denon_dashboard_render_card "Recent Events" "$dash_events_body" "$width" 12
  }

  _denon_dashboard_render_medium() {
    local width="$1"
    local gap=2
    local left=$(((width - gap) / 2))
    local right=$((width - gap - left))

    col1_title="Main Zone"
    col1_body="$dash_main_body"
    col1_width="$left"
    col2_title="Now Playing / Audio"
    col2_body="$dash_now_body"
    col2_width="$right"
    _denon_dashboard_render_columns 2 10
    printf '\n'

    col1_title="Receiver / Zone 2"
    col1_body="$dash_receiver_body"
    col1_width="$left"
    col2_title="Recent Events"
    col2_body="$dash_events_body"
    col2_width="$right"
    _denon_dashboard_render_columns 2 13
    printf '\n'

    _denon_dashboard_render_card "Main Zone Sources" "$dash_main_sources" "$width" 12
  }

  _denon_dashboard_render_ultrawide() {
    local width="$1"
    local gap=2
    local top_available=$((width - (gap * 2)))
    local top_w1=$((top_available / 3))
    local top_w2="$top_w1"
    local top_w3=$((top_available - top_w1 - top_w2))
    local bottom_available=$((width - gap))
    local bottom_left=$(((bottom_available * 3) / 5))
    local bottom_right=$((bottom_available - bottom_left))

    col1_title="Main Zone"
    col1_body="$dash_main_body"
    col1_width="$top_w1"
    col2_title="Now Playing / Audio"
    col2_body="$dash_now_body"
    col2_width="$top_w2"
    col3_title="Receiver / Zone 2"
    col3_body="$dash_receiver_body"
    col3_width="$top_w3"
    _denon_dashboard_render_columns 3 11
    printf '\n'

    col1_title="Main Zone Sources"
    col1_body="$dash_main_sources"
    col1_width="$bottom_left"
    col2_title="Recent Events"
    col2_body="$dash_events_body"
    col2_width="$bottom_right"
    _denon_dashboard_render_columns 2 13
  }

  _denon_dashboard_render() {
    local width
    width=$(_denon_dashboard_width)
    _denon_dashboard_setup_color
    _denon_dashboard_set_borders
    _denon_dashboard_build_bodies

    if (( width >= 150 )); then
      _denon_dashboard_render_ultrawide "$width"
    elif (( width >= 100 )); then
      _denon_dashboard_render_medium "$width"
    else
      _denon_dashboard_render_narrow "$width"
    fi
    _denon_dashboard_render_footer "$width"
  }

  _denon_dashboard_redraw() {
    local rendered line
    rendered=$(_denon_dashboard_render)
    printf '\033[H'
    while IFS= read -r line; do
      printf '%s\033[K\n' "$line"
    done <<<"$rendered"
    printf '\033[J'
  }

  _denon_dashboard_sleep_or_resize() {
    local remaining="$1"
    local chunk key

    while [[ "${dashboard_stop_pending:-0}" != "1" ]] && awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; do
      if [[ "${dashboard_resize_pending:-0}" == "1" ]]; then
        dashboard_resize_pending=0
        _denon_dashboard_redraw
      fi
      chunk=$(awk -v remaining="$remaining" 'BEGIN { if (remaining < 0.2) printf "%.3f", remaining; else printf "0.200" }')
      if [[ -t 0 ]]; then
        key=""
        if read -rsn1 -t "$chunk" key 2>/dev/null; then
          case "$key" in
            q|Q)
              dashboard_stop_pending=1
              break
              ;;
            r|R)
              dashboard_resize_pending=0
              _denon_dashboard_redraw
              ;;
          esac
        fi
      else
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
            echo "Usage: denon dashboard [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]" >&2
            return 1
          fi
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
        --color)
          case "$(_denon_lower "${2:-}")" in
            auto|always|never)
              dashboard_color_mode=$(_denon_lower "$2")
              shift 2
              ;;
            *)
              echo "Usage: denon dashboard [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]" >&2
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
          echo "Usage: denon dashboard [--watch] [--interval seconds] [--ascii|--unicode] [--color auto|always|never]" >&2
          return 1
          ;;
      esac
    done

    if [[ "$watch" == "1" ]]; then
      trap 'dashboard_resize_pending=1' WINCH
      trap 'dashboard_stop_pending=1; dashboard_exit_status=130; printf "\033[?25h"' INT TERM HUP
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
      printf '\033[?25h'
      trap - WINCH INT TERM HUP
      return "$dashboard_exit_status"
    fi

    _denon_dashboard_collect
    _denon_dashboard_update_events
    _denon_dashboard_render
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
          "${main_power:-?}" "${main_src:-?}" "${main_vol:-?}" "$db_label" "${main_mute:-?}"
        printf '  Zone2: power=%s source=%s vol=%s mute=%s\n' \
          "${z2_power:-?}" "${z2_src:-?}" "${z2_vol:-?}" "${z2_mute:-?}"
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
        DENON_CURL_MAX_TIME|DENON_SSDP_TIMEOUT|DENON_SSDP_MX|DENON_HEOS_PID|\
        DENON_HEOS_GID|DENON_HEOS_HELPER|DENON_HEOS_TIMEOUT|DENON_DEBUG|\
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
DENON_CURL_MAX_TIME DENON_SSDP_TIMEOUT DENON_SSDP_MX DENON_HEOS_PID \
DENON_HEOS_GID DENON_HEOS_HELPER DENON_HEOS_TIMEOUT DENON_DEBUG \
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
DENON_CURL_MAX_TIME DENON_SSDP_TIMEOUT DENON_SSDP_MX DENON_HEOS_PID \
DENON_HEOS_GID DENON_HEOS_HELPER DENON_HEOS_TIMEOUT DENON_DEBUG \
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
  # ── Init ──────────────────────────────────────────────────────────────────

  if [[ -n "${DENON_PROFILE:-}" ]]; then
    _denon_validate_stored_name "profile" "$DENON_PROFILE" || return 1
    _denon_load_config "$(_denon_profile_dir)/${DENON_PROFILE}"
  fi
  _denon_load_config

  local _arg _quiet=0 _silent=0
  local -a _quiet_args=()
  for _arg in "$@"; do
    case "$_arg" in
      --quiet|-q) _quiet=1 ;;
      --silent) _silent=1 ;;
      *) _quiet_args+=("$_arg") ;;
    esac
  done
  if (( _silent )); then
    denon "${_quiet_args[@]+"${_quiet_args[@]}"}" >/dev/null 2>&1
    return $?
  fi
  if (( _quiet )); then
    denon "${_quiet_args[@]+"${_quiet_args[@]}"}" >/dev/null
    return $?
  fi

  local cmd
  cmd=$(_denon_lower "$1")

  case "$cmd" in
    ""|-h|--help|help)
      _denon_usage
      return 0
      ;;
    version|--version|-V)
      local script_path
      script_path=$(_denon_script_path) || {
        echo "Error: could not resolve script path for version lookup" >&2
        return 1
      }
      grep -m1 '^# Version:' "$script_path" | awk '{print $3}'
      return 0
      ;;
    setip)
      if [[ -z "$2" ]] || ! _denon_is_ipv4 "$2"; then
        echo "Error: setip requires an IPv4 address, for example: denon setip 192.168.1.23" >&2
        return 1
      fi
      mkdir -p "$HOME/.cache"
      printf '%s' "$2" >"$HOME/.cache/denon_ip"
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
    profile)
      _denon_profile_cmd "${@:2}"
      return $?
      ;;
    discover)
      rm -f "$HOME/.cache/denon_ip"
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
    info|status|signal-debug|rawstatus|raw|snapshot|dashboard|sources|source|rename-source|source-names|clear-source-name|sleep|qs|on|off|xbox|xfinity|bluray|tv|phono|heos|vol|up|down|mute|unmute|toggle|movie|game|night|music|mode|dyn-eq|dyn-vol|cinema-eq|multeq|bass|treble|play|pause|stop|next|prev|previous|track|now|zone2|watch-event|preset)
      ;;
    *)
      _denon_usage
      return 1
      ;;
  esac

  local IP
  IP=$(_denon_discover)
  if [[ -z "$IP" ]]; then
    echo "Error: Could not find Denon receiver on network" >&2
    return 1
  fi
  local BASE="https://$IP:10443"

  # ── Commands ──────────────────────────────────────────────────────────────

  case "$cmd" in
    info)
      _denon_info "$2"
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
        *) echo "Usage: denon raw {get <type>|set <type> <xml payload>}" >&2; return 1 ;;
      esac
      ;;

    snapshot)
      _denon_snapshot "$2"
      ;;

    dashboard)
      _denon_dashboard "${@:2}"
      ;;

    sources)
      _denon_sources "${@:2}"
      ;;

    source)
      _denon_set_source "$2" "1"
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
        _denon_heos_helper "${@:2}"
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
          _denon_change_volume "$2"
        else
          _denon_set_volume_db "$2"
        fi
      fi
      ;;

    up)
      local step="${2:-${DENON_VOLUME_STEP_DB:-1}}"
      step="${step#[-+]}"
      _denon_change_volume "$step"
      ;;
    down)
      local step="${2:-${DENON_VOLUME_STEP_DB:-1}}"
      step="${step#[-+]}"
      _denon_change_volume "-$step"
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
      _denon_sound_mode "$2"
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
          _denon_set_source "$3" "2"
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
          if [[ -z "$3" ]] || ! _denon_is_unsigned_integer "$3"; then
            echo "Error: zone2 vol requires the raw Zone 2 volume value, for example: denon zone2 vol 650" >&2
            return 1
          fi
          _denon_set_config 12 "<Zone2><Volume>${3}</Volume></Zone2>" || return 1
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
      return 1
      ;;
  esac
}

# shellcheck disable=SC2034,SC2153,SC2154
_denon_completion() {
  local -a commands modes zone2_commands raw_commands json_flags zones heos_commands onoff dyn_volumes multeq_modes tone_commands repeat_modes
  commands=(
    info status signal-debug rawstatus raw snapshot diff sources source rename-source source-names clear-source-name
    sleep qs quick quick-select
    on off xbox xfinity bluray tv phono heos vol up down mute unmute toggle movie game night music mode
    dyn-eq dyn-vol cinema-eq multeq bass treble
    play pause stop next prev previous track now dashboard zone2 preset watch-event discover doctor setip config profile help
  )
  modes=(stereo direct pure movie music game auto)
  zone2_commands=(status sources source rename-source clear-source-name on off mute unmute vol volume up down sleep)
  raw_commands=(get set)
  json_flags=(--json)
  zones=(1 2)
  heos_commands=(now play pause stop next prev queue groups group browse search play-stream repeat shuffle update)
  onoff=(on off)
  dyn_volumes=(off light medium heavy)
  multeq_modes=(reference bypass-lr flat manual off)
  tone_commands=(up down)
  repeat_modes=(off all one)

  if (( CURRENT == 2 )); then
    _describe -t commands 'denon command' commands
    return
  fi

  case "${words[2]}" in
    info|status)
      _describe -t json-flags 'json flag' json_flags
      return
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

if ! _denon_is_sourced; then
  denon "$@"
fi
