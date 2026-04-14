#!/usr/bin/env bash
# denon_release_candidate.sh — Denon AVR controller
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
      local cached_ip
      cached_ip=$(<"$cache")
      if _denon_is_receiver "$cached_ip"; then
        printf '%s' "$cached_ip"
        return 0
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
  denon rawstatus            Print raw XML returned by the AVR
  denon raw get <type>       Fetch a raw get_config type, for example 3, 4, 7, 12
  denon raw set <type> '<xml>'
                             Send a raw set_config payload
  denon snapshot [dir]       Save core XML responses to a timestamped directory
  denon doctor               Check dependencies, route, cache, and receiver reachability

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

Power and mute:
  denon on                   Turn main zone on
  denon off                  Turn main zone off
  denon mute                 Mute main zone
  denon unmute               Unmute main zone

Volume:
  denon vol                  Show current main zone volume
  denon vol -35              Set absolute volume to -35 dB
  denon vol +2               Raise volume by 2 dB
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
  denon play
  denon pause
  denon next
  denon prev
  denon track
  denon now

Zone 2:
  denon zone2 status
  denon zone2 sources
  denon zone2 source <id|name>
  denon zone2 rename-source <id|name> "<new name>"
  denon zone2 clear-source-name <id|name>
  denon zone2 on
  denon zone2 off
  denon zone2 vol <raw>

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
  DENON_SSDP_TIMEOUT
  DENON_SSDP_MX
  DENON_DEBUG=1

Notes:
  Commands are case-insensitive.
  Source display names are local aliases; they do not rename sources inside the receiver.
  The script can be run directly or sourced from bash/zsh.
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
    sed 's/\\/\\\\/g; s/"/\\"/g'
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

  _denon_heos_control() {
    local action="$1" code
    case "$action" in
      play) code="NS9A" ;;
      pause) code="NS9B" ;;
      next) code="NS9D" ;;
      prev|previous) code="NS9E" ;;
      *) return 1 ;;
    esac
    _denon_telnet "$code" && echo "Sent $action"
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
    local zone="${1:-1}"
    local source_idx
    source_idx=$(_denon_current_source_idx "$zone")
    if [[ -z "$source_idx" ]]; then
      echo "Error: could not read source list for zone $zone from receiver" >&2
      return 1
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

  _denon_probe_candidate() {
    local label="$1" candidate="$2" xml model
    [[ -n "$candidate" ]] || return 1
    printf '%-18s %s ... ' "$label" "$candidate"
    xml=$(_denon_curl -G "https://$candidate:10443/ajax/globals/get_config" \
      --data-urlencode "type=3" 2>/dev/null)
    if printf '%s' "$xml" | grep -q "Denon"; then
      model=$(printf '%s' "$xml" | sed -n 's:.*<FriendlyName>\([^<]*\)</FriendlyName>.*:\1:p')
      echo "OK (${model:-Denon receiver})"
      return 0
    fi
    echo "no Denon response"
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
    local known_hosts
    known_hosts=$(_denon_known_hosts | tr '\n' ' ')
    echo "  ${known_hosts:-none}"
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

  # ── Init ──────────────────────────────────────────────────────────────────

  local cmd
  cmd=$(_denon_lower "$1")

  case "$cmd" in
    ""|-h|--help|help)
      _denon_usage
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
    info|status|rawstatus|raw|snapshot|sources|source|rename-source|source-names|clear-source-name|on|off|xbox|xfinity|bluray|tv|phono|heos|vol|up|down|mute|unmute|movie|game|night|music|mode|play|pause|next|prev|previous|track|now|zone2)
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

    sources)
      _denon_sources "${2:-1}"
      ;;

    source)
      _denon_set_source "$2" "1"
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
    heos) _denon_set_source "heos music" "1" ;;

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
    play|pause|next|prev|previous)
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
        vol)
          if [[ -z "$3" ]] || ! _denon_is_unsigned_integer "$3"; then
            echo "Error: zone2 vol requires the raw Zone 2 volume value, for example: denon zone2 vol 650" >&2
            return 1
          fi
          _denon_set_config 12 "<Zone2><Volume>${3}</Volume></Zone2>" || return 1
          _denon_zone_status_pretty 2
          ;;
        *)
          echo "Usage: denon zone2 {status|sources|source <id|name>|rename-source <id|name> <new name>|clear-source-name <id|name>|on|off|vol <raw>}" >&2
          return 1
          ;;
      esac
      ;;

    *)
      _denon_usage
      return 1
      ;;
  esac
}

# shellcheck disable=SC2034,SC2153,SC2154
_denon_completion() {
  local -a commands modes zone2_commands raw_commands json_flags zones
  commands=(
    info status rawstatus raw snapshot sources source rename-source source-names clear-source-name
    on off xbox xfinity bluray tv phono heos vol up down mute unmute movie game night music mode
    play pause next prev previous track now zone2 discover doctor setip help
  )
  modes=(stereo direct pure movie music game auto)
  zone2_commands=(status sources source rename-source clear-source-name on off vol)
  raw_commands=(get set)
  json_flags=(--json)
  zones=(1 2)

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
