# shellcheck shell=bash
# lib/config.sh — v2 JSON config: load, version-check/migrate, device selection,
# source aliases. Sourced by denon.sh; requires jq.
#
# Globals set by config_load:
#   DENON_CFG_DEVICE  selected device name ("" when unconfigured)
#   DENON_CFG_HOST    device host/IP        DENON_CFG_MAC
#   DENON_CFG_MODEL                          DENON_CFG_SERIAL
#   DENON_CFG_MONITOR ondemand|always|never (default ondemand)

DENON_CONFIG_VERSION=1

denon_config_path() {
  printf '%s' "${DENON_CONFIG_JSON:-${XDG_CONFIG_HOME:-$HOME/.config}/denon/config.json}"
}

denon_legacy_config_path() {
  printf '%s' "${DENON_CONFIG:-$HOME/.config/denon/config}"
}

# Atomically write stdin to the config file.
denon_config_write() {
  local cfg tmp
  cfg=$(denon_config_path)
  mkdir -p "$(dirname "$cfg")" || return 1
  tmp="${cfg}.tmp.$$"
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; echo "denon: refusing to write invalid config JSON" >&2; return 1; }
  mv "$tmp" "$cfg"
}

# Build a v1 config from legacy artifacts (flat env-style config file and the
# discovery IP cache). Old files are left untouched. Returns 1 when there is
# nothing to migrate.
config_migrate_legacy() {
  local legacy ip="" mac="" line key val
  legacy=$(denon_legacy_config_path)
  if [[ -f "$legacy" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      key="${line%%=*}"
      val="${line#*=}"
      key="${key//[[:space:]]/}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      case "$key" in
        DENON_IP|DENON_DEFAULT_IP) [[ -n "$ip" ]] || ip="$val" ;;
      esac
    done <"$legacy"
  fi
  if [[ -z "$ip" && -f "$HOME/.cache/denon_ip" ]]; then
    ip=$(<"$HOME/.cache/denon_ip")
  fi
  [[ -n "$ip" ]] || return 1
  if command -v ip >/dev/null 2>&1; then
    mac=$(command ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="lladdr"){print $(i+1); exit}}')
  fi
  jq -n --arg host "$ip" --arg mac "$mac" '{
    version: 1,
    default: "main",
    devices: { main: { host: $host, mac: $mac, model: "", serial: "", monitor: "ondemand" } },
    aliases: {}
  }' | denon_config_write || return 1
  echo "denon: migrated legacy config to $(denon_config_path) (device 'main', host $ip)" >&2
}

# config_load [device] — populate DENON_CFG_* for the selected device.
# Unconfigured (no config.json and no legacy data) is not an error: the
# legacy discovery path still works without it.
config_load() {
  local device="${1:-${DENON_AVR:-}}" cfg version fields
  DENON_CFG_DEVICE="" DENON_CFG_HOST="" DENON_CFG_MAC=""
  DENON_CFG_MODEL="" DENON_CFG_SERIAL="" DENON_CFG_MONITOR="ondemand"
  cfg=$(denon_config_path)
  if [[ ! -f "$cfg" ]]; then
    config_migrate_legacy 2>/dev/null || return 0
  fi
  version=$(jq -r '.version // 0' "$cfg" 2>/dev/null) || {
    echo "denon: cannot parse $cfg" >&2
    return 1
  }
  if [[ "$version" != "$DENON_CONFIG_VERSION" ]]; then
    echo "denon: unsupported config version '$version' in $cfg (expected $DENON_CONFIG_VERSION)" >&2
    return 1
  fi
  fields=$(jq -r --arg dev "$device" '
    (if $dev != "" then $dev else (.default // "") end) as $name
    | .devices[$name] as $d
    | if $d == null then ""
      else [$name, ($d.host // ""), ($d.mac // ""), ($d.model // ""),
            ($d.serial // ""), ($d.monitor // "ondemand")] | join("\u0001")
      end' "$cfg" 2>/dev/null) || return 1
  # shellcheck disable=SC2034  # consumed by transport.sh and subcommands
  IFS=$'\x01' read -r DENON_CFG_DEVICE DENON_CFG_HOST DENON_CFG_MAC \
    DENON_CFG_MODEL DENON_CFG_SERIAL DENON_CFG_MONITOR <<<"$fields"
  [[ -n "$DENON_CFG_MONITOR" ]] || DENON_CFG_MONITOR="ondemand"
  if [[ -n "$device" && -z "$DENON_CFG_DEVICE" ]]; then
    echo "denon: device '$device' not found in $cfg" >&2
    return 1
  fi
  return 0
}

# config_set_device <name> <host> [mac] [model] [serial] — add or update a
# device entry (creates the config when absent). Used by `denon add`.
config_set_device() {
  local name="$1" host="$2" mac="${3:-}" model="${4:-}" serial="${5:-}" cfg
  cfg=$(denon_config_path)
  [[ -f "$cfg" ]] || printf '{"version":1,"default":"%s","devices":{},"aliases":{}}' "$name" | denon_config_write
  jq --arg n "$name" --arg h "$host" --arg mac "$mac" --arg mo "$model" --arg s "$serial" '
    .devices[$n] = ((.devices[$n] // {monitor: "ondemand"})
      + {host: $h}
      + (if $mac != "" then {mac: $mac} else {} end)
      + (if $mo  != "" then {model: $mo} else {} end)
      + (if $s   != "" then {serial: $s} else {} end))
    | if (.default // "") == "" then .default = $n else . end
  ' "$cfg" | denon_config_write
}

config_devices() {
  local cfg
  cfg=$(denon_config_path)
  [[ -f "$cfg" ]] || return 0
  jq -r '.devices | keys[]' "$cfg" 2>/dev/null
}

# alias_resolve <name> — map a user alias to its SI source code; echoes the
# input unchanged when no alias matches.
alias_resolve() {
  local name="$1" cfg out
  cfg=$(denon_config_path)
  if [[ -f "$cfg" ]]; then
    out=$(jq -r --arg a "$name" '.aliases[$a] // empty' "$cfg" 2>/dev/null)
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  printf '%s' "$name"
}

# alias_reverse <code> — first alias label pointing at the given SI code;
# empty output when none.
alias_reverse() {
  local code="$1" cfg
  cfg=$(denon_config_path)
  [[ -f "$cfg" ]] || return 0
  jq -r --arg c "$code" '.aliases | to_entries[] | select(.value == $c) | .key' \
    "$cfg" 2>/dev/null | head -1
}

# alias_set <name> <code> / alias_unset <name>
alias_set() {
  local cfg
  cfg=$(denon_config_path)
  [[ -f "$cfg" ]] || printf '{"version":1,"default":"","devices":{},"aliases":{}}' | denon_config_write
  jq --arg a "$1" --arg c "$2" '.aliases[$a] = $c' "$cfg" | denon_config_write
}

alias_unset() {
  local cfg
  cfg=$(denon_config_path)
  [[ -f "$cfg" ]] || return 0
  jq --arg a "$1" 'del(.aliases[$a])' "$cfg" | denon_config_write
}
