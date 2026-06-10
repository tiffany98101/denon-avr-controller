#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  TMPHOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TMPHOME"
  export HOME="$TMPHOME"
  export XDG_CONFIG_HOME="$TMPHOME/.config"
  export DENON_CONFIG_JSON="$TMPHOME/.config/denon/config.json"
  source "$ROOT/lib/config.sh"
}

@test "config_set_device creates a selectable JSON device" {
  run config_set_device livingroom 127.0.0.1 aa:bb AVR-X1600H SERIAL1
  [ "$status" -eq 0 ]

  run bash -c '
    source "$1/lib/config.sh"
    config_load livingroom
    printf "%s\t%s\t%s\n" "$DENON_CFG_DEVICE" "$DENON_CFG_HOST" "$DENON_CFG_MAC"
  ' bash "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = $'livingroom\t127.0.0.1\taa:bb' ]
}

@test "config_load reports missing explicit device" {
  config_set_device main 127.0.0.1
  run config_load missing
  [ "$status" -eq 1 ]
  [[ "$output" == *"device 'missing' not found"* ]]
}

@test "aliases resolve and preserve unknown names" {
  alias_set tv SAT/CBL

  run alias_resolve tv
  [ "$status" -eq 0 ]
  [ "$output" = "SAT/CBL" ]

  run alias_resolve bluray
  [ "$status" -eq 0 ]
  [ "$output" = "bluray" ]
}
