#!/usr/bin/env bash
# fake-avr.sh — minimal AVR-X1600H protocol simulator for offline tests.
#
# Speaks three surfaces:
#   * telnet  (Denon protocol over TCP; single client at a time, like real HW)
#   * http    (goform: formiPhoneAppDirect.xml, XmlStatusLite, NetAudio)
#   * https   (legacy ajax/globals/get_config + set_config, via ncat --ssl)
#
# Usage:
#   fake-avr.sh serve --dir DIR [--telnet-port N] [--http-port N] [--https-port N]
#   fake-avr.sh stop  --dir DIR
#
# DIR contents:
#   state        key=value device state (pre-seed before serve to set initial state)
#   telnet.log   every command received on the telnet surface (one per line)
#   http.log     every command received via formiPhoneAppDirect.xml
#   inject       FIFO: write protocol lines here to emit unsolicited telnet events
#   *.pid        listener pids
set -u

FA_SELF=$(readlink -f "${BASH_SOURCE[0]}")

fa_state_defaults() {
  cat <<'EOF'
PW=ON
MV=45
MVMAX=98
MU=OFF
SI=SAT/CBL
MS=DOLBY DIGITAL
ZM=ON
Z2=OFF
Z2VOL=65
Z2MU=OFF
Z2SI=CD
PSDYNEQ=ON
PSMULTEQ=AUDYSSEY
PSDYNVOL=MED
PSREFLEV=0
PSCINEMAEQ=OFF
PSBAS=50
PSTRE=50
SLP=OFF
SRCIDX1=3
SRCIDX2=1
NSE0=HEOS Music
NSE1=Fake Artist - Fake Track
NSE2=Fake Album
EOF
}

fa_state_load() {
  declare -gA S=()
  local k v
  while IFS='=' read -r k v; do
    [[ -n "$k" ]] && S[$k]=$v
  done <"$FA_DIR/state"
}

fa_state_save() {
  local k tmp="$FA_DIR/state.tmp.$$"
  : >"$tmp"
  for k in "${!S[@]}"; do
    printf '%s=%s\n' "$k" "${S[$k]}" >>"$tmp"
  done
  mv "$tmp" "$FA_DIR/state"
}

# Reply with a protocol line (CR-terminated, as the real AVR does).
fa_reply() {
  printf '%s\r' "$1"
}

# Apply one raw protocol command against the state table, emitting replies.
# Mirrors AVR behavior: queries answer, sets echo the resulting event,
# unknown commands are silently ignored.
fa_apply_cmd() {
  local cmd="$1"
  case "$cmd" in
    PW\?)        fa_reply "PW${S[PW]}" ;;
    PWON)        S[PW]=ON; fa_reply "PWON"; fa_reply "ZMON" ;;
    PWSTANDBY)   S[PW]=STANDBY; fa_reply "PWSTANDBY" ;;
    MV\?)        fa_reply "MV${S[MV]}"; fa_reply "MVMAX ${S[MVMAX]}" ;;
    MVUP)        S[MV]=$(( S[MV] + 1 )); fa_reply "MV${S[MV]}" ;;
    MVDOWN)      S[MV]=$(( S[MV] - 1 )); fa_reply "MV${S[MV]}" ;;
    MV[0-9]*)    S[MV]=${cmd#MV}; fa_reply "MV${S[MV]}" ;;
    MU\?)        fa_reply "MU${S[MU]}" ;;
    MUON|MUOFF)  S[MU]=${cmd#MU}; fa_reply "$cmd" ;;
    SI\?)        fa_reply "SI${S[SI]}" ;;
    SI*)         S[SI]=${cmd#SI}; fa_reply "$cmd" ;;
    MS\?)        fa_reply "MS${S[MS]}" ;;
    MS*)         S[MS]=${cmd#MS}; fa_reply "$cmd" ;;
    ZM\?)        fa_reply "ZM${S[ZM]}" ;;
    ZMON|ZMOFF)  S[ZM]=${cmd#ZM}; fa_reply "$cmd" ;;
    Z2\?)        fa_reply "Z2${S[Z2]}"; fa_reply "Z2${S[Z2VOL]}" ;;
    Z2MU\?)      fa_reply "Z2MU${S[Z2MU]}" ;;
    Z2MUON|Z2MUOFF) S[Z2MU]=${cmd#Z2MU}; fa_reply "$cmd" ;;
    Z2ON|Z2OFF)  S[Z2]=${cmd#Z2}; fa_reply "$cmd" ;;
    Z2SLP\?)     fa_reply "Z2SLP${S[Z2SLP]:-OFF}" ;;
    Z2SLP*)      S[Z2SLP]=${cmd#Z2SLP}; fa_reply "$cmd" ;;
    Z2UP)        S[Z2VOL]=$(( S[Z2VOL] + 1 )); fa_reply "Z2${S[Z2VOL]}" ;;
    Z2DOWN)      S[Z2VOL]=$(( S[Z2VOL] - 1 )); fa_reply "Z2${S[Z2VOL]}" ;;
    Z2[0-9]*)    S[Z2VOL]=${cmd#Z2}; fa_reply "Z2${S[Z2VOL]}" ;;
    Z2*)         S[Z2SI]=${cmd#Z2}; fa_reply "$cmd" ;;
    "PSDYNEQ ?")    fa_reply "PSDYNEQ ${S[PSDYNEQ]}" ;;
    "PSDYNEQ "*)    S[PSDYNEQ]=${cmd#PSDYNEQ }; fa_reply "$cmd" ;;
    "PSMULTEQ ?"|"PSMULTEQ: ?") fa_reply "PSMULTEQ:${S[PSMULTEQ]}" ;;
    PSMULTEQ:*)     S[PSMULTEQ]=${cmd#PSMULTEQ:}; fa_reply "$cmd" ;;
    "PSDYNVOL ?")   fa_reply "PSDYNVOL ${S[PSDYNVOL]}" ;;
    "PSDYNVOL "*)   S[PSDYNVOL]=${cmd#PSDYNVOL }; fa_reply "$cmd" ;;
    "PSREFLEV ?")   fa_reply "PSREFLEV ${S[PSREFLEV]}" ;;
    "PSREFLEV "*)   S[PSREFLEV]=${cmd#PSREFLEV }; fa_reply "$cmd" ;;
    "PSCINEMA EQ. ?") fa_reply "PSCINEMA EQ.${S[PSCINEMAEQ]}" ;;
    "PSCINEMA EQ."*)  S[PSCINEMAEQ]=${cmd#PSCINEMA EQ.}; fa_reply "PSCINEMA EQ.${S[PSCINEMAEQ]}" ;;
    "PSBAS ?")      fa_reply "PSBAS ${S[PSBAS]}" ;;
    "PSBAS "*)      S[PSBAS]=${cmd#PSBAS }; fa_reply "$cmd" ;;
    "PSTRE ?")      fa_reply "PSTRE ${S[PSTRE]}" ;;
    "PSTRE "*)      S[PSTRE]=${cmd#PSTRE }; fa_reply "$cmd" ;;
    SLP\?)          fa_reply "SLP${S[SLP]}" ;;
    SLP*)           S[SLP]=${cmd#SLP}; fa_reply "$cmd" ;;
    NSE)
      local i
      for i in 0 1 2 3 4 5 6 7 8; do
        fa_reply "NSE${i}${S[NSE$i]:-}"
      done
      ;;
    SSSOD\?)
      fa_reply "SSSODSAT/CBL USE"
      fa_reply "SSSODDVD USE"
      fa_reply "SSSODCD USE"
      fa_reply "SSSODTV USE"
      fa_reply "SSSOD END"
      ;;
    QUICK[0-9]*)    : ;;
    *)              : ;;   # unknown command: real AVR stays silent
  esac
}

# Run apply under an exclusive lock so concurrent surfaces stay consistent.
fa_apply_locked() {
  local cmd="$1" out
  out=$(
    flock -x 9
    fa_state_load
    fa_apply_cmd "$cmd"
    fa_state_save
  ) 9>>"$FA_DIR/state.lock"
  printf '%s' "$out"
}

fa_urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

fa_http_respond() {
  local body="$1"
  printf 'HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "${#body}" "$body"
}

fa_http_404() {
  printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
}

fa_status_lite_main() {
  fa_state_load
  local mute=off
  [[ "${S[MU]}" == "ON" ]] && mute=on
  printf '<?xml version="1.0" encoding="utf-8"?><item><Power><value>%s</value></Power><ZonePower><value>%s</value></ZonePower><InputFuncSelect><value>%s</value></InputFuncSelect><MasterVolume><value>%s</value></MasterVolume><Mute><value>%s</value></Mute></item>' \
    "${S[PW]}" "${S[ZM]}" "${S[SI]}" "${S[MV]}" "$mute"
}

fa_status_lite_zone2() {
  fa_state_load
  local mute=off
  [[ "${S[Z2MU]}" == "ON" ]] && mute=on
  printf '<?xml version="1.0" encoding="utf-8"?><item><Power><value>%s</value></Power><InputFuncSelect><value>%s</value></InputFuncSelect><MasterVolume><value>%s</value></MasterVolume><Mute><value>%s</value></Mute></item>' \
    "${S[Z2]}" "${S[Z2SI]}" "${S[Z2VOL]}" "$mute"
}

fa_netaudio_xml() {
  fa_state_load
  printf '<?xml version="1.0" encoding="utf-8"?><item><szLine><value>%s</value><value>%s</value><value>%s</value></szLine></item>' \
    "${S[NSE0]:-}" "${S[NSE1]:-}" "${S[NSE2]:-}"
}

fa_get_config_xml() {
  local type="$1"
  fa_state_load
  local pw_code=1 z2_code=3 mu_code=2 z2mu_code=2
  [[ "${S[PW]}" != "ON" ]] && pw_code=3
  [[ "${S[Z2]}" == "ON" ]] && z2_code=1
  [[ "${S[MU]}" == "ON" ]] && mu_code=1
  [[ "${S[Z2MU]}" == "ON" ]] && z2mu_code=1
  case "$type" in
    3)
      printf '<?xml version="1.0" encoding="utf-8"?><listGlobals><FriendlyName>Fake Denon AVR-X1600H</FriendlyName><ModelName>AVR-X1600H</ModelName><BrandCode>Denon</BrandCode></listGlobals>'
      ;;
    4)
      printf '<?xml version="1.0" encoding="utf-8"?><listGlobals><MainZone><Power>%s</Power></MainZone><Zone2><Power>%s</Power></Zone2></listGlobals>' \
        "$pw_code" "$z2_code"
      ;;
    7)
      printf '<?xml version="1.0" encoding="utf-8"?><listGlobals><Zone zone="1" index="%s"></Zone><Zone zone="2" index="%s"></Zone></listGlobals>' \
        "${S[SRCIDX1]}" "${S[SRCIDX2]}"
      ;;
    12)
      printf '<?xml version="1.0" encoding="utf-8"?><listGlobals><MainZone><Volume>%s0</Volume><VolumeScale>1</VolumeScale><VolumeLimit>99</VolumeLimit><Mute>%s</Mute><Max>%s0</Max></MainZone><Zone2><Volume>%s0</Volume><VolumeScale>1</VolumeScale><VolumeLimit>70</VolumeLimit><Mute>%s</Mute></Zone2></listGlobals>' \
        "${S[MV]}" "$mu_code" "${S[MVMAX]}" "${S[Z2VOL]}" "$z2mu_code"
      ;;
    *)
      printf '<?xml version="1.0" encoding="utf-8"?><listGlobals></listGlobals>'
      ;;
  esac
}

# Translate a legacy set_config payload into state mutations.
fa_set_config_apply() {
  local type="$1" data="$2" val
  (
    flock -x 9
    fa_state_load
    case "$type" in
      4)
        if [[ "$data" == *"<MainZone>"* ]]; then
          val=$(printf '%s' "$data" | sed -n 's:.*<Power>\([0-9]\)</Power>.*:\1:p')
          [[ "$val" == "1" ]] && S[PW]=ON
          [[ "$val" == "3" ]] && S[PW]=STANDBY
        elif [[ "$data" == *"<Zone2>"* ]]; then
          val=$(printf '%s' "$data" | sed -n 's:.*<Power>\([0-9]\)</Power>.*:\1:p')
          [[ "$val" == "1" ]] && S[Z2]=ON
          [[ "$val" == "3" ]] && S[Z2]=OFF
        fi
        ;;
      7)
        val=$(printf '%s' "$data" | sed -n 's:.*index="\([0-9]*\)".*:\1:p')
        local zone
        zone=$(printf '%s' "$data" | sed -n 's:.*zone="\([0-9]\)".*:\1:p')
        [[ "$zone" == "2" ]] && S[SRCIDX2]=$val || S[SRCIDX1]=$val
        ;;
      12)
        val=$(printf '%s' "$data" | sed -n 's:.*<Volume>\([0-9]*\)</Volume>.*:\1:p')
        if [[ -n "$val" ]]; then
          if [[ "$data" == *"<Zone2>"* ]]; then S[Z2VOL]=$(( val / 10 )); else S[MV]=$(( val / 10 )); fi
        fi
        val=$(printf '%s' "$data" | sed -n 's:.*<Mute>\([0-9]\)</Mute>.*:\1:p')
        if [[ -n "$val" ]]; then
          local mu=OFF
          [[ "$val" == "1" ]] && mu=ON
          if [[ "$data" == *"<Zone2>"* ]]; then S[Z2MU]=$mu; else S[MU]=$mu; fi
        fi
        ;;
    esac
    fa_state_save
  ) 9>>"$FA_DIR/state.lock"
}

# ── Handlers (stdin/stdout = socket, spawned by ncat --exec) ────────────────

fa_telnet_handler() {
  local cmd rc inj
  exec {inj}<>"$FA_DIR/inject"
  while :; do
    if IFS= read -r -d $'\r' -t 0.1 cmd; then
      cmd=${cmd#$'\n'}
      [[ -z "$cmd" ]] && continue
      printf '%s\n' "$cmd" >>"$FA_DIR/telnet.log"
      fa_apply_locked "$cmd"
    else
      rc=$?
      (( rc <= 128 )) && break   # EOF: client gone
    fi
    while IFS= read -r -t 0.01 -u "$inj" cmd; do
      printf '%s\r' "$cmd"
    done
  done
}

fa_http_handler() {
  local reqline path query hdr
  IFS= read -r reqline || return 0
  reqline=${reqline%$'\r'}
  path=${reqline#* }; path=${path%% *}
  while IFS= read -r -t 2 hdr; do
    hdr=${hdr%$'\r'}
    [[ -z "$hdr" ]] && break
  done
  query=""
  [[ "$path" == *\?* ]] && query=${path#*\?}
  path=${path%%\?*}
  case "$path" in
    /goform/formiPhoneAppDirect.xml)
      local cmd
      cmd=$(fa_urldecode "$query")
      printf '%s\n' "$cmd" >>"$FA_DIR/http.log"
      fa_apply_locked "$cmd" >/dev/null
      fa_http_respond ""
      ;;
    /goform/formMainZone_MainZoneXmlStatusLite.xml)
      fa_http_respond "$(fa_status_lite_main)"
      ;;
    /goform/formZone2_Zone2XmlStatusLite.xml)
      fa_http_respond "$(fa_status_lite_zone2)"
      ;;
    /goform/formNetAudio_StatusXml.xml)
      fa_http_respond "$(fa_netaudio_xml)"
      ;;
    *)
      fa_http_404
      ;;
  esac
}

fa_https_handler() {
  local reqline path query hdr type="" data="" k v
  IFS= read -r reqline || return 0
  reqline=${reqline%$'\r'}
  path=${reqline#* }; path=${path%% *}
  while IFS= read -r -t 2 hdr; do
    hdr=${hdr%$'\r'}
    [[ -z "$hdr" ]] && break
  done
  query=""
  [[ "$path" == *\?* ]] && query=${path#*\?}
  path=${path%%\?*}
  while IFS='=' read -r k v; do
    case "$k" in
      type) type=$(fa_urldecode "$v") ;;
      data) data=$(fa_urldecode "$v") ;;
    esac
  done < <(printf '%s\n' "$query" | tr '&' '\n')
  case "$path" in
    /ajax/globals/get_config)
      fa_http_respond "$(fa_get_config_xml "$type")"
      ;;
    /ajax/globals/set_config)
      printf 'set_config type=%s data=%s\n' "$type" "$data" >>"$FA_DIR/https.log"
      fa_set_config_apply "$type" "$data"
      fa_http_respond ""
      ;;
    *)
      fa_http_404
      ;;
  esac
}

# ── Server lifecycle ─────────────────────────────────────────────────────────

fa_serve() {
  mkdir -p "$FA_DIR"
  [[ -f "$FA_DIR/state" ]] || fa_state_defaults >"$FA_DIR/state"
  : >"$FA_DIR/telnet.log"
  : >"$FA_DIR/http.log"
  : >"$FA_DIR/https.log"
  [[ -p "$FA_DIR/inject" ]] || mkfifo "$FA_DIR/inject"

  if [[ -n "$FA_TELNET_PORT" ]]; then
    (
      while :; do
        ncat -l 127.0.0.1 "$FA_TELNET_PORT" \
          --exec "$FA_SELF telnet-handler $FA_DIR" 2>/dev/null || break
      done
    ) &
    echo $! >"$FA_DIR/telnet.pid"
  fi
  if [[ -n "$FA_HTTP_PORT" ]]; then
    ncat -lk 127.0.0.1 "$FA_HTTP_PORT" \
      --exec "$FA_SELF http-handler $FA_DIR" 2>/dev/null &
    echo $! >"$FA_DIR/http.pid"
  fi
  if [[ -n "$FA_HTTPS_PORT" ]]; then
    # ncat's built-in cert generation trips Fedora's OpenSSL digest policy;
    # generate our own throwaway cert instead.
    if [[ ! -f "$FA_DIR/cert.pem" ]]; then
      openssl req -x509 -newkey rsa:2048 -keyout "$FA_DIR/key.pem" \
        -out "$FA_DIR/cert.pem" -days 2 -nodes -subj "/CN=fake-avr" 2>/dev/null
    fi
    ncat -lk --ssl --ssl-cert "$FA_DIR/cert.pem" --ssl-key "$FA_DIR/key.pem" \
      127.0.0.1 "$FA_HTTPS_PORT" \
      --exec "$FA_SELF https-handler $FA_DIR" 2>/dev/null &
    echo $! >"$FA_DIR/https.pid"
  fi
  # Give listeners a moment to bind before the caller proceeds.
  sleep 0.3
}

fa_stop() {
  local f pid
  for f in "$FA_DIR"/telnet.pid "$FA_DIR"/http.pid "$FA_DIR"/https.pid; do
    [[ -f "$f" ]] || continue
    pid=$(<"$f")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$f"
  done
  # ncat children of the respawn loop
  pkill -f "ncat -l 127.0.0.1 ${FA_TELNET_PORT:-NONE}" 2>/dev/null
  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

FA_MODE="${1:-serve}"
shift || true

case "$FA_MODE" in
  telnet-handler) FA_DIR="$1"; fa_telnet_handler; exit 0 ;;
  http-handler)   FA_DIR="$1"; fa_http_handler; exit 0 ;;
  https-handler)  FA_DIR="$1"; fa_https_handler; exit 0 ;;
esac

FA_DIR=""
FA_TELNET_PORT=""
FA_HTTP_PORT=""
FA_HTTPS_PORT=""
while (( $# )); do
  case "$1" in
    --dir) FA_DIR="$2"; shift 2 ;;
    --telnet-port) FA_TELNET_PORT="$2"; shift 2 ;;
    --http-port) FA_HTTP_PORT="$2"; shift 2 ;;
    --https-port) FA_HTTPS_PORT="$2"; shift 2 ;;
    *) echo "fake-avr: unknown arg $1" >&2; exit 64 ;;
  esac
done
[[ -n "$FA_DIR" ]] || { echo "fake-avr: --dir required" >&2; exit 64; }

case "$FA_MODE" in
  serve) fa_serve ;;
  stop)  fa_stop ;;
  *) echo "fake-avr: unknown mode $FA_MODE" >&2; exit 64 ;;
esac
