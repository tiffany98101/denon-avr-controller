#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  STUBBIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  export PATH="$STUBBIN:$PATH"
  export DENON_TELNET_PORT=23
  export DENON_HTTP_PORTS="8080"
  source "$ROOT/lib/protocol.sh"
  source "$ROOT/lib/config.sh"
  source "$ROOT/lib/transport.sh"
}

teardown() {
  :
}

write_stub_ncat_ok() {
  cat >"$STUBBIN/ncat" <<'EOF'
#!/usr/bin/env bash
cat >/tmp/denon-bats-ncat.stdin
printf 'PWON\r'
EOF
  chmod +x "$STUBBIN/ncat"
}

write_stub_curl_http() {
  cat >"$STUBBIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *formiPhoneAppDirect.xml*)
    printf '200'
    ;;
  *formMainZone_MainZoneXmlStatusLite.xml*)
    printf '<item><Power><value>ON</value></Power><MasterVolume><value>45</value></MasterVolume><Mute><value>off</value></Mute><InputFuncSelect><value>SAT/CBL</value></InputFuncSelect></item>'
    ;;
esac
EOF
  chmod +x "$STUBBIN/curl"
}

@test "avr_send reads a telnet query from the fake AVR" {
  write_stub_ncat_ok
  run avr_send --expect PW --timeout 0.1 127.0.0.1 "PW?"
  [ "$status" -eq 0 ]
  [ "$output" = "PWON" ]
  grep -q $'PW?\r' /tmp/denon-bats-ncat.stdin
}

@test "avr_send --http sends through formiPhoneAppDirect and synthesizes query reply" {
  write_stub_curl_http
  run avr_send --http --expect MV --timeout 0.1 127.0.0.1 "MV?"
  [ "$status" -eq 0 ]
  [ "$output" = "MV45" ]
}

@test "denon raw passthrough uses v2 transport and preserves legacy raw namespace" {
  write_stub_ncat_ok
  run env \
    DENON_IP=127.0.0.1 \
    DENON_CONFIG_JSON="$BATS_TEST_TMPDIR/config.json" \
    bash "$ROOT/denon.sh" raw PW?
  [ "$status" -eq 0 ]
  [[ "$output" == *"PWON"* ]]
  grep -q $'PW?\r' /tmp/denon-bats-ncat.stdin

  rm -f /tmp/denon-bats-ncat.stdin
  run env DENON_IP=127.0.0.1 bash "$ROOT/denon.sh" raw get nope
  [ "$status" -ne 0 ]
  [ ! -e /tmp/denon-bats-ncat.stdin ]
}

@test "denon raw types remains a local legacy raw helper" {
  write_stub_ncat_ok
  run env DENON_IP=127.0.0.1 bash "$ROOT/denon.sh" raw types
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 identity"* ]]
  [[ "$output" == *"12 volume"* ]]
  [ ! -e /tmp/denon-bats-ncat.stdin ]
}

@test "bin/denon wrapper executes the repo script" {
  run "$ROOT/bin/denon" --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
