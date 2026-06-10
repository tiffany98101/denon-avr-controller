#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  source "$ROOT/lib/protocol.sh"
}

@test "zone_cmd maps main and zone2 power commands" {
  run zone_cmd 1 power on
  [ "$status" -eq 0 ]
  [ "$output" = "ZMON" ]

  run zone_cmd 2 power off
  [ "$status" -eq 0 ]
  [ "$output" = "Z2OFF" ]
}

@test "protocol_valid_cmd rejects shell metacharacters" {
  run protocol_valid_cmd "PW?"
  [ "$status" -eq 0 ]

  run protocol_valid_cmd "PW?;rm -rf /"
  [ "$status" -ne 0 ]
}

@test "protocol_http_synthesize turns StatusLite XML into telnet reply" {
  xml='<item><Power><value>ON</value></Power><MasterVolume><value>45</value></MasterVolume></item>'
  run protocol_http_synthesize "MV?" "$xml"
  [ "$status" -eq 0 ]
  [ "$output" = "MV45" ]
}
