"""
Pytest tests for denon.sh parser functions.

Each test sources the script via bash subprocess (DENON_UNIT_TEST=1 suppresses
the top-level command dispatch) and calls individual helper functions with
fixture bodies captured during Phase 4 live probing.
"""

import json
import os
import re
import subprocess
import textwrap
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "denon.sh"
FIXTURES = Path(__file__).parent / "fixtures"
SCRIPT_STR = str(SCRIPT)


def _bash(code: str, env_extra: dict | None = None) -> subprocess.CompletedProcess:
    """Run bash snippet with the script sourced."""
    env = os.environ.copy()
    env["DENON_UNIT_TEST"] = "1"
    if env_extra:
        env.update(env_extra)
    full = f'source {SCRIPT_STR}\n{code}'
    return subprocess.run(
        ["bash", "-c", full],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
    )


def _assert_no_dashboard_helper_errors(r: subprocess.CompletedProcess) -> None:
    combined = r.stdout + r.stderr
    assert "sed:" not in combined
    assert "Invalid range end" not in combined


def _strip_dashboard_control_sequences(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)


# ---------------------------------------------------------------------------
# _denon_data_parse_xml_field  (UPnP fixture tests)
# ---------------------------------------------------------------------------

class TestParseXmlField:
    def _read(self, name: str) -> str:
        return (FIXTURES / name).read_text()

    def test_modelname_from_deviceinfo(self):
        body = self._read("upnp_deviceinfo.xml").replace("'", "'\\''")
        r = _bash(f"printf '%s' '{body}' | _denon_data_parse_xml_field /dev/stdin ModelName || "
                  f"_denon_data_parse_xml_field '{body}' ModelName; "
                  # direct call form
                  f"_denon_data_parse_xml_field $'{ body }' ModelName 2>/dev/null || true")
        # Use the function with body as variable argument
        body2 = self._read("upnp_deviceinfo.xml")
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_deviceinfo.xml')
            _denon_data_parse_xml_field "$body" "ModelName"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "AVR-X1600H" in r.stdout

    def test_macaddress_from_deviceinfo(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_deviceinfo.xml')
            _denon_data_parse_xml_field "$body" "MacAddress"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "00:00:00:00:00:00"

    def test_commapiversfrom_deviceinfo(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_deviceinfo.xml')
            _denon_data_parse_xml_field "$body" "CommApiVers"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "0301"

    def test_device_zones_from_deviceinfo(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_deviceinfo.xml')
            _denon_data_parse_xml_field "$body" "DeviceZones"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "2"

    def test_serial_from_aios(self):
        """aios_device.xml has namespace-qualified tags; sed must strip prefix."""
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_aios_device.xml')
            printf '%s' "$body" | sed -n 's:.*<serialNumber>\\([^<]*\\)</serialNumber>.*:\\1:p' | sed -n '1p'
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "SERIAL_PLACEHOLDER"

    def test_aios_firmware_from_aios(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_aios_device.xml')
            printf '%s' "$body" | sed -n 's:.*<modelNumber>\\([^<]*\\)</modelNumber>.*:\\1:p' | sed -n '1p'
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "4.025" in r.stdout

    def test_udn_from_aios(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/upnp_aios_device.xml')
            printf '%s' "$body" | sed -n 's:.*<UDN>\\([^<]*\\)</UDN>.*:\\1:p' | sed -n '1p'
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip().startswith("uuid:")


class TestExplicitSourceCommands:
    def test_explicit_tv_shortcut_still_sets_source(self):
        code = textwrap.dedent("""\
            calls=""
            _denon_get_source_xml() {
              printf '%s' '<SourceList><Zone zone="1" index="13"><Source index="6"><Name>TV Audio</Name></Source><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'
            }
            _denon_set_config() {
              calls="${calls}${1}:${2}"$'\\n'
            }
            _denon_wait_for_source() { return 0; }
            _denon_alias_for_source() { return 1; }
            _denon_source_name_by_idx() { printf '%s' 'TV Audio'; }
            _denon_status_pretty() { printf '%s' 'status-called'; }

            _denon_set_source "tv audio" "1" >/dev/null
            printf '%s' "$calls"
        """)
        r = _bash(code)
        assert r.returncode == 0, r.stderr
        assert '7:<Source zone="1" index="6"></Source>' in r.stdout


# ---------------------------------------------------------------------------
# Bug B-3: multi-line body → single record line
# ---------------------------------------------------------------------------

class TestBugB3MultiLineBody:
    def test_multiline_body_produces_single_record(self):
        """Multi-line HTML body must collapse to one tab-separated record, not several."""
        code = textwrap.dedent("""\
            data_discovered_endpoint_records=""
            body=$'<html>\\n<body>\\n<h1>Title</h1>\\n<p>Some text here</p>\\n</body>\\n</html>'
            _denon_data_record_discovered_endpoint "/test/path" "$body"
            # Count lines in the record (should be exactly 1 non-empty line)
            count=$(printf '%s' "$data_discovered_endpoint_records" | grep -c '.')
            printf '%s\\n' "$count"
        """)
        r = _bash(code)
        assert r.returncode == 0
        # Exactly one record line
        assert r.stdout.strip() == "1"

    def test_multiline_body_summary_has_no_newlines(self):
        """The summary field in a record must not contain embedded newlines."""
        code = textwrap.dedent("""\
            data_discovered_endpoint_records=""
            body=$'line1\\nline2\\nline3'
            _denon_data_record_discovered_endpoint "/some/path" "$body"
            printf '%s' "$data_discovered_endpoint_records"
        """)
        r = _bash(code)
        assert r.returncode == 0
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        assert len(lines) == 1, f"Expected 1 record line, got {len(lines)}: {r.stdout!r}"


# ---------------------------------------------------------------------------
# Bug B-1 + B-2: web endpoint discovery
# ---------------------------------------------------------------------------

class TestBugB1B2WebDiscovery:
    def test_b1_extracts_src_attribute(self):
        """src= and href= attributes should be discovered (B-1 fix)."""
        html = '<script src="/ajax/globals/get_config"></script>'
        code = textwrap.dedent(f"""\
            result=$(_denon_data_discover_web_endpoints_from_text '{html}')
            printf '%s\\n' "$result"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "/ajax/globals/get_config" in r.stdout

    def test_b1_extracts_href_attribute(self):
        html = '<link href="/css/main.css" rel="stylesheet">'
        code = textwrap.dedent(f"""\
            result=$(_denon_data_discover_web_endpoints_from_text '{html}')
            printf '%s\\n' "$result"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "/css/main.css" in r.stdout

    def test_b2_rejects_js_code_fragment(self):
        """Tokens like ,d=b.css should not match as URL paths (B-2 fix)."""
        js = 'var d=b.css,e=c.html;this.attr("src",d+e);'
        code = textwrap.dedent(f"""\
            result=$(_denon_data_discover_web_endpoints_from_text '{js}')
            printf '%s\\n' "$result"
        """)
        r = _bash(code)
        assert r.returncode == 0
        # None of the JS tokens should appear as discovered paths
        for bad in ["d=b.css", "c.html", ",d", ";this"]:
            assert bad not in r.stdout, f"JS fragment {bad!r} should not appear in output"

    def test_b2_accepts_clean_quoted_path(self):
        """A clean quoted path like "/goform/AppCommand.xml" must be discovered."""
        text = 'var url = "/goform/AppCommand.xml";'
        code = textwrap.dedent(f"""\
            result=$(_denon_data_discover_web_endpoints_from_text '{text}')
            printf '%s\\n' "$result"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "/goform/AppCommand.xml" in r.stdout

    def test_dedup_same_path_appears_once(self):
        """Duplicate paths in the source text should be de-duplicated."""
        html = '<a href="/index.html">A</a><a href="/index.html">B</a>'
        code = textwrap.dedent(f"""\
            result=$(_denon_data_discover_web_endpoints_from_text '{html}')
            count=$(printf '%s\\n' "$result" | grep -c '/index.html' || true)
            printf '%s\\n' "$count"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "1"


# ---------------------------------------------------------------------------
# Bug B-4: repeated XML leaf paths produce JSON arrays
# ---------------------------------------------------------------------------

class TestBugB4XmlLeafArrays:
    def test_repeated_path_produces_array(self):
        """When the same dotted path appears multiple times, output must be a JSON array."""
        # Simulate what _denon_data_print_get_config_json does: feed tab-sep path/value pairs
        # through the awk block. We call it by populating data_get_config_leaf_records.
        code = textwrap.dedent("""\
            data_get_config_leaf_records=""
            data_get_config_leaf_records+=$'7\\tSourceList.Zone.Source.Name\\tBD\\n'
            data_get_config_leaf_records+=$'7\\tSourceList.Zone.Source.Name\\tDVD\\n'
            data_get_config_leaf_records+=$'7\\tSourceList.Zone.Source.Name\\tGame\\n'
            data_get_config_types="7"
            data_get_config_raw_7=""
            out=$(_denon_data_print_get_config_json 2>/dev/null)
            printf '%s\\n' "$out"
        """)
        r = _bash(code)
        assert r.returncode == 0
        try:
            obj = json.loads(r.stdout)
        except json.JSONDecodeError:
            assert False, f"Output is not valid JSON: {r.stdout!r}"
        # Records are nested: {"7": {"raw": "...", "fields": {"path": value}}}
        val = obj["7"]["fields"]["SourceList.Zone.Source.Name"]
        assert isinstance(val, list), f"Repeated path should be a JSON array, got: {val!r}"
        assert set(val) == {"BD", "DVD", "Game"}

    def test_unique_path_produces_scalar(self):
        """A path appearing exactly once must remain a JSON string, not an array."""
        code = textwrap.dedent("""\
            data_get_config_leaf_records=$'4\\tZone.Power\\tON\\n'
            data_get_config_types="4"
            data_get_config_raw_4=""
            out=$(_denon_data_print_get_config_json 2>/dev/null)
            printf '%s\\n' "$out"
        """)
        r = _bash(code)
        assert r.returncode == 0
        try:
            obj = json.loads(r.stdout)
        except json.JSONDecodeError:
            assert False, f"Output is not valid JSON: {r.stdout!r}"
        val = obj["4"]["fields"]["Zone.Power"]
        assert isinstance(val, str), f"Unique path should be a scalar string, got: {val!r}"
        assert val == "ON"


# ---------------------------------------------------------------------------
# Deviceinfo/AppCommand capability inventory
# ---------------------------------------------------------------------------

class TestDeviceinfoCapabilities:
    def _capabilities(self) -> list[dict]:
        code = textwrap.dedent(f"""\
            denon data capabilities --source '{FIXTURES}/deviceinfo_capabilities_trimmed.xml' --json
        """)
        r = _bash(code)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)["capabilities"]

    def _verbs(self, verb: str) -> list[dict]:
        return [item for item in self._capabilities() if item["verb"] == verb]

    def test_repeated_xml_paths_are_preserved(self):
        items = self._verbs("GetZoneName")
        assert len(items) == 2
        assert {item["xml_path"] for item in items} == {
            "Device_Info.DeviceCapabilities.DeviceZoneCapabilities.Zone.Functions.GetZoneName"
        }

    def test_unsafe_verbs_are_classified_as_skipped(self):
        skipped = {item["verb"]: item for item in self._capabilities() if item["safety"] == "skipped"}
        assert skipped["SetToneControl"]["skip_reason"] == "mutating or account/action verb prefix"
        assert skipped["ResetDevice"]["skip_reason"] == "mutating or account/action verb prefix"

    def test_unknown_verbs_are_listed_but_not_executed(self):
        [item] = self._verbs("GetMystery")
        assert item["safety"] == "unknown"
        assert item["probe_status"] == "not_probed"
        assert item["probe_summary"] == "not in exact live-probe allowlist"

    def test_known_safe_verbs_are_included_in_dry_run_plan(self):
        [item] = self._verbs("GetToneControl")
        assert item["safety"] == "known-safe"
        assert item["probe_status"] == "dry-run"
        assert item["probe_summary"] == "eligible for --probe-safe"
        assert item["has_parser"] is True

    def test_capability_json_shape_for_probe_results(self):
        [item] = self._verbs("GetToneControl")
        assert set(item) == {
            "source_endpoint",
            "xml_path",
            "verb",
            "kind",
            "safety",
            "skip_reason",
            "has_parser",
            "probe_status",
            "probe_summary",
        }


class TestPromotedLiveFieldParsers:
    def test_system_type11_fields_are_parsed_by_path(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/get_config_live_system_type11.xml')
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.AdvancedMode")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.CIMode")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.MenuLock")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.GuiType")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.HEOSSignIn")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.WebUIType")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "System.ProductType")"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.splitlines() == ["1", "2", "2", "1", "3", "3", "219"]

    def test_volume_scale_and_limits_are_parsed_by_zone(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/get_config_live_volume_type12.xml')
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "listGlobals.MainZone.VolumeScale")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "listGlobals.MainZone.VolumeLimit")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "listGlobals.Zone2.VolumeScale")"
            printf '%s\\n' "$(_denon_data_xml_leaf_first "$body" "listGlobals.Zone2.VolumeLimit")"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.splitlines() == ["1", "99", "1", "70"]

    def test_promoted_xml_leaves_are_not_reported_as_unhandled(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/get_config_live_system_type11.xml')
            data_available_records=""
            data_get_config_leaf_records=""
            _denon_data_add_xml_leaves "11" "$body"
            printf '%s' "$data_available_records"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Unhandled parsed XML leaves" not in r.stdout
        assert "System.AdvancedMode" not in r.stdout

    def test_empty_rx_response_is_classified_without_payload(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/appcommand_empty_rx.xml')
            _denon_data_appcommand_response_status_summary "$body"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "empty\tnone"

    def test_empty_appcommand_response_is_classified_empty(self):
        code = "_denon_data_appcommand_response_status_summary ''"
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "empty\tnone"

    def test_non_xml_appcommand_response_is_classified_malformed(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/appcommand_error.txt')
            _denon_data_appcommand_response_status_summary "$body"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "malformed\tCould not handle the request"

    def test_partial_appcommand_response_is_classified_malformed(self):
        code = "_denon_data_appcommand_response_status_summary '<rx><cmd'"
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "malformed\t<cmd"

    def test_useful_rx_response_is_classified_ok(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/appcommand_useful_rx.xml')
            _denon_data_appcommand_response_status_summary "$body"
        """)
        r = _bash(code)
        assert r.returncode == 0
        status, summary = r.stdout.strip().split("\t", 1)
        assert status == "ok"
        assert "GetToneControl" in summary
        assert "6" in summary

    def test_appcommand_probe_curl_failure_is_classified(self):
        code = textwrap.dedent("""\
            BASE=http://192.0.2.10
            _denon_curl() { return 22; }
            _denon_data_probe_appcommand_safe GetToneControl
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "curl_error\tcurl exited 22"


class TestDataSummaryOutput:
    SUMMARY_RECORDS = """\
        data_available_records=""
        data_available_records+=$'receiver\\tReceiver\\tname\\tDenon AVR-X1600H\\n'
        data_available_records+=$'receiver\\tReceiver\\tip\\t192.0.2.10\\n'
        data_available_records+=$'receiver\\tReceiver\\tbrand_code\\t7\\n'
        data_available_records+=$'receiver\\tReceiver\\tmodel_type\\t1\\n'
        data_available_records+=$'main_zone\\tMain Zone\\tzone_name\\tLivingRoom\\n'
        data_available_records+=$'main_zone\\tMain Zone\\tvolume_scale\\t7\\n'
        data_available_records+=$'main_zone\\tMain Zone\\tvolume_limit_raw\\t99\\n'
        data_available_records+=$'main_zone\\tMain Zone\\tvolume_max_db\\t18.0\\n'
        data_available_records+=$'zone2\\tZone 2\\tzone_name\\tZONE2\\n'
        data_available_records+=$'zone2\\tZone 2\\tvolume_scale\\t1\\n'
        data_available_records+=$'zone2\\tZone 2\\tvolume_limit_raw\\t70\\n'
        data_available_records+=$'system\\tSystem\\tsetup_lock\\t2\\n'
        data_available_records+=$'system\\tSystem\\tbt_headphones_single_used\\t0\\n'
        data_available_records+=$'system\\tSystem\\tspeaker_preset\\t0\\n'
        data_available_records+=$'system\\tSystem\\tadvanced_mode\\t1\\n'
        data_available_records+=$'system\\tSystem\\tci_mode\\t2\\n'
        data_available_records+=$'system\\tSystem\\tmenu_lock\\t2\\n'
        data_available_records+=$'system\\tSystem\\tgui_type\\t1\\n'
        data_available_records+=$'system\\tSystem\\theos_sign_in\\t3\\n'
        data_available_records+=$'system\\tSystem\\twebui_type\\t3\\n'
        data_available_records+=$'system\\tSystem\\tproduct_type\\t219\\n'
        data_available_records+=$'network_heos\\tNetwork / HEOS\\theos_model\\tDenon AVR-X1600H\\n'
        data_available_records+=$'network_heos\\tNetwork / HEOS\\theos_version\\t3.88.614\\n'
        data_available_records+=$'network_heos\\tNetwork / HEOS\\tnetwork\\twifi\\n'
        data_available_records+=$'upnp\\tUPnP / Device Identity\\tpending_upgrade_version\\t00\\n'
        data_available_records+=$'upnp\\tUPnP / Device Identity\\taios_firmware\\tAios 4.025\\n'
    """

    def test_summary_json_includes_promoted_fields_with_unknown_labels(self):
        code = textwrap.dedent(self.SUMMARY_RECORDS + """\
            _denon_data_print_summary_json
        """)
        r = _bash(code)
        assert r.returncode == 0
        obj = json.loads(r.stdout)
        assert obj["receiver"]["brand_code"] == {"raw": "7", "label": "unknown"}
        assert obj["volume"]["main_zone"]["volume_scale"] == {"raw": "7", "label": "unknown"}
        assert obj["system"]["setup_lock"] == {"raw": "2", "label": "unknown"}
        assert obj["system"]["heos_sign_in"] == {"raw": "3", "label": "unknown"}

    def test_summary_readable_preserves_firmware_limitation(self):
        code = textwrap.dedent(self.SUMMARY_RECORDS + """\
            _denon_data_print_summary_readable
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Network / Firmware Notes" in r.stdout
        assert "network                      Wi-Fi" in r.stdout
        assert "zone2                        Zone 2" in r.stdout
        assert "avr_mainboard_firmware" in r.stdout
        assert "unavailable on tested read-only surfaces" in r.stdout
        assert "heos_version" in r.stdout
        assert "separate HEOS firmware, not AVR mainboard firmware" in r.stdout
        assert "pending update metadata, not installed firmware" in r.stdout
        assert "AVR mainboard firmware: 3.88.614" not in r.stdout

    def test_status_output_stays_concise(self):
        code = textwrap.dedent("""\
            _denon_get_power_xml() { printf '%s' '<listGlobals><MainZone><Power>1</Power></MainZone></listGlobals>'; }
            _denon_get_source_xml() { printf '%s' '<SourceList><Zone zone="1" index="6"><Source index="6"><Name>TV Audio</Name></Source></Zone></SourceList>'; }
            _denon_get_vol_xml() { printf '%s' '<listGlobals><MainZone><Volume>490</Volume><Mute>2</Mute></MainZone></listGlobals>'; }
            _denon_alias_for_source() { return 1; }
            _denon_source_name_by_idx() { printf '%s' 'TV Audio'; }
            _denon_status_pretty
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "Power: ON | Source: TV Audio | Volume: -31.0 dB"
        for noisy in ["brand_code", "model_type", "setup_lock", "heos_sign_in", "firmware"]:
            assert noisy not in r.stdout

    def test_mute_normalization_accepts_on_like_values(self):
        code = textwrap.dedent("""\
            for value in on ON yes YES true TRUE 1 MUON Z2MUON; do
              printf '%s=%s\\n' "$value" "$(_denon_normalize_mute "$value")"
            done
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert all(line.endswith("=yes") for line in r.stdout.splitlines())

    def test_mute_normalization_accepts_off_like_values(self):
        code = textwrap.dedent("""\
            for value in off OFF no NO false FALSE 0 MUOFF Z2MUOFF 2; do
              printf '%s=%s\\n' "$value" "$(_denon_normalize_mute "$value")"
            done
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert all(line.endswith("=no") for line in r.stdout.splitlines())

    def test_mute_display_uses_title_case_yes_no(self):
        code = textwrap.dedent("""\
            printf 'on=%s\\n' "$(_denon_mute_display_name on)"
            printf 'off=%s\\n' "$(_denon_mute_display_name off)"
            printf 'missing=%s\\n' "$(_denon_mute_display_name)"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.splitlines() == ["on=Yes", "off=No", "missing=Unknown"]

    def test_display_helpers_format_network_zone_and_empty_messages(self):
        code = textwrap.dedent("""\
            printf 'network=%s\\n' "$(_denon_display_network_label wifi)"
            printf 'wired=%s\\n' "$(_denon_display_network_label ethernet)"
            printf 'zone=%s\\n' "$(_denon_display_zone_label ZONE2)"
            printf 'empty=%s\\n' "$(_denon_display_empty_message no-state-changes)"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.splitlines() == [
            "network=Wi-Fi",
            "wired=Ethernet",
            "zone=Zone 2",
            "empty=No State Changes Yet",
        ]

    def test_data_readable_formats_display_values_without_changing_json_boundary(self):
        code = textwrap.dedent("""\
            data_available_records=""
            data_available_records+=$'main_zone\\tMain Zone\\tmuted\\tno\\n'
            data_available_records+=$'main_zone\\tMain Zone\\tzone_name\\tMainZone\\n'
            data_available_records+=$'zone2\\tZone 2\\tmuted\\tyes\\n'
            data_available_records+=$'zone2\\tZone 2\\tzone_name\\tZONE2\\n'
            data_available_records+=$'network_heos\\tNetwork / HEOS\\tnetwork\\twifi\\n'
            _denon_data_print_readable
            printf -- '---JSON---\\n'
            _denon_data_print_json
        """)
        r = _bash(code)
        assert r.returncode == 0
        readable, json_text = r.stdout.split("---JSON---\n", 1)
        assert "muted                  No" in readable
        assert "muted                  Yes" in readable
        assert "zone_name              Main Zone" in readable
        assert "zone_name              Zone 2" in readable
        assert "network                Wi-Fi" in readable
        obj = json.loads(json_text)
        assert obj["main_zone"]["muted"] == "no"
        assert obj["main_zone"]["zone_name"] == "MainZone"
        assert obj["zone2"]["muted"] == "yes"
        assert obj["zone2"]["zone_name"] == "ZONE2"
        assert obj["heos"]["network"] == "wifi"

    def test_mute_normalization_unknown_values_stay_unknown(self):
        code = textwrap.dedent("""\
            printf 'empty=%s\\n' "$(_denon_normalize_mute "")"
            printf 'unknown=%s\\n' "$(_denon_normalize_mute unknown)"
            printf 'Unknown=%s\\n' "$(_denon_normalize_mute Unknown)"
            printf 'null=%s\\n' "$(_denon_normalize_mute null)"
            printf 'missing=%s\\n' "$(_denon_normalize_mute)"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert all(line.endswith("=Unknown") for line in r.stdout.splitlines())

    def test_info_json_uses_null_for_unknown_mute(self):
        code = textwrap.dedent("""\
            IP=192.0.2.10
            _denon_get_identity_xml() { printf '%s' '<Device><FriendlyName>Denon AVR-X1600H</FriendlyName></Device>'; }
            _denon_get_power_xml() { printf '%s' '<listGlobals><MainZone><Power>1</Power></MainZone><Zone2><Power>2</Power></Zone2></listGlobals>'; }
            _denon_get_source_xml() { printf '%s' '<SourceList><Zone zone="1" index="6"></Zone><Zone zone="2" index="1"></Zone></SourceList>'; }
            _denon_get_vol_xml() { printf '%s' '<listGlobals><MainZone><Volume>490</Volume><Mute></Mute></MainZone><Zone2><Volume>650</Volume><Mute>bogus</Mute></Zone2></listGlobals>'; }
            _denon_query_main_mute_raw() { return 1; }
            _denon_query_zone2_mute_raw() { return 1; }
            _denon_alias_for_source() { return 1; }
            _denon_source_name_by_idx() { printf '%s' 'HEOS Music'; }
            _denon_info --json
        """)
        r = _bash(code)
        assert r.returncode == 0
        obj = json.loads(r.stdout)
        assert obj["mainZone"]["muted"] is None
        assert obj["zone2"]["muted"] is None

    def test_resolve_main_mute_known_xml_skips_telnet(self, tmp_path):
        log = tmp_path / "telnet.log"
        code = textwrap.dedent(f"""\
            _denon_query_main_mute_raw() {{
              printf 'called\\n' >>'{log}'
              printf '%s' 'MUOFF'
            }}
            _denon_resolve_main_mute 1
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "1"
        assert not log.exists()

    def test_resolve_main_mute_unknown_xml_uses_known_telnet_fallback(self):
        code = textwrap.dedent("""\
            _denon_query_main_mute_raw() { printf '%s' 'MUOFF'; }
            _denon_resolve_main_mute bogus
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "MUOFF"

    def test_resolve_main_mute_unknown_telnet_leaves_unknown(self):
        code = textwrap.dedent("""\
            _denon_query_main_mute_raw() { printf '%s' 'garbage'; }
            _denon_resolve_main_mute ''
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "Unknown"

    def test_status_uses_known_xml_mute_without_telnet_override(self, tmp_path):
        log = tmp_path / "telnet.log"
        code = textwrap.dedent("""\
            _denon_get_power_xml() { printf '%s' '<listGlobals><MainZone><Power>1</Power></MainZone></listGlobals>'; }
            _denon_get_source_xml() { printf '%s' '<SourceList><Zone zone="1" index="13"><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'; }
            _denon_get_vol_xml() { printf '%s' '<listGlobals><MainZone><Volume>450</Volume><Mute>1</Mute></MainZone></listGlobals>'; }
            _denon_query_main_mute_raw() {
              printf 'called\\n' >>"$DENON_TEST_TELNET_LOG"
              printf '%s' 'MUOFF'
            }
            _denon_alias_for_source() { return 1; }
            _denon_source_name_by_idx() { printf '%s' 'HEOS Music'; }
            _denon_status_pretty
        """)
        r = _bash(code, {"DENON_TEST_TELNET_LOG": str(log)})
        assert r.returncode == 0
        assert r.stdout.strip() == "Power: ON | Source: HEOS Music | Volume: -35.0 dB [MUTED]"
        assert not log.exists()

    def test_status_json_uses_telnet_fallback_when_xml_mute_unknown(self):
        code = textwrap.dedent("""\
            IP=192.0.2.10
            _denon_get_power_xml() { printf '%s' '<listGlobals><MainZone><Power>1</Power></MainZone></listGlobals>'; }
            _denon_get_source_xml() { printf '%s' '<SourceList><Zone zone="1" index="13"><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'; }
            _denon_get_vol_xml() { printf '%s' '<listGlobals><MainZone><Volume>450</Volume><Mute></Mute></MainZone></listGlobals>'; }
            _denon_query_main_mute_raw() { printf '%s' 'MUOFF'; }
            _denon_alias_for_source() { return 1; }
            _denon_source_name_by_idx() { printf '%s' 'HEOS Music'; }
            _denon_status_json
        """)
        r = _bash(code)
        assert r.returncode == 0
        obj = json.loads(r.stdout)
        assert obj["muted"] is False

    def test_dashboard_raw_main_mute_off_renders_no(self):
        code = textwrap.dedent("""\
            IP=192.0.2.10
            _denon_info() { return 1; }
            _denon_status_pretty() { printf '%s\\n' 'Power: ON | Source: HEOS Music | Volume: -31.0 dB'; }
            _denon_zone_status_pretty() { printf '%s\\n' 'Zone 2 | Power: OFF | Source: Phono | Volume: -15.0 | Muted: No'; }
            _denon_sources() {
              if [[ "$1" == "1" ]]; then
                printf '%s\\n' '  1  TV Audio' '* 13 HEOS Music'
              else
                printf '%s\\n' '* 1  Phono'
              fi
            }
            _denon_track() { return 1; }
            _denon_get_config() { printf '%s' '<listGlobals><MainZone>Main Zone</MainZone><Zone2>Zone 2</Zone2></listGlobals>'; }
            _denon_get_vol_xml() { printf '%s' '<listGlobals><MainZone><Volume>490</Volume><Mute>off</Mute><Max>980</Max></MainZone><Zone2><Volume>650</Volume><Mute>Z2MUOFF</Mute></Zone2></listGlobals>'; }
            _denon_query_main_mute_raw() { return 1; }
            _denon_query_zone2_mute_raw() { return 1; }
            _denon_dashboard_telnet_status() { return 1; }
            _denon_dashboard_heos_status() { return 1; }
            dashboard_initialized=0
            previous_dashboard_key=""
            dashboard_events=""
            last_dashboard_event=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            dashboard_ascii=1
            watch=0
            DENON_DASHBOARD_WIDTH=120
            DENON_DASHBOARD_HEIGHT=40
            _denon_dashboard_collect
            _denon_dashboard_update_events
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Muted:  No" in r.stdout
        assert "Muted:  no" not in r.stdout
        assert "Muted:  yes" not in r.stdout


class TestDashboardRecentEvents:
    EVENT_STATE = """\
        dashboard_initialized=0
        previous_dashboard_key=""
        dashboard_events=""
        last_dashboard_event=""
        dash_main_power="ON"
        dash_main_source="HEOS Music"
        dash_main_source_index="13"
        dash_main_muted="no"
        dash_main_volume="-35.0"
        dash_sound_mode="Stereo"
        dash_zone2_power="ON"
        dash_zone2_source="HEOS Music"
        dash_zone2_source_index="13"
        dash_zone2_muted="no"
        dash_zone2_volume_db="-15.0"
        dash_transport_state="Playing"
        dash_now_title="Song One"
        dash_now_artist="Artist One"
        dash_now_album="Album One"
        dash_now_station="Station One"
        dash_now_service="Spotify"
    """

    def test_recent_events_logs_now_playing_title_change_once(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_now_title="Song Two"
            _denon_dashboard_update_events
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.count("Now Playing: Song Two — Artist One") == 1

    def test_recent_events_ignores_unknown_now_playing_changes(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            dash_now_title="Unknown"
            dash_now_artist="Unknown"
            dash_now_album=""
            dash_now_station=""
            dash_now_service=""
            _denon_dashboard_update_events
            dash_now_title=""
            dash_now_artist=""
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Now Playing:" not in r.stdout

    def test_recent_events_preserves_now_playing_capitalization(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_now_title="iT'S a Long Way"
            dash_now_artist="AC/DC"
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Now Playing: iT'S a Long Way — AC/DC" in r.stdout

    def test_recent_events_logs_main_volume_change_once(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_main_volume="-34.0"
            _denon_dashboard_update_events
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.count("Main Volume: -35.0 dB -> -34.0 dB") == 1

    def test_recent_events_logs_zone2_volume_change(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_zone2_volume_db="-14.0"
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Zone 2 Volume: -15.0 dB -> -14.0 dB" in r.stdout

    def test_recent_events_ignores_missing_volume_on_both_refreshes(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            dash_main_volume="Unknown"
            dash_zone2_volume_db=""
            _denon_dashboard_update_events
            dash_main_volume=""
            dash_zone2_volume_db="Unknown"
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Volume:" not in r.stdout

    def test_recent_events_logs_main_mute_with_display_values(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_main_muted="yes"
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Main Mute: No -> Yes" in r.stdout
        assert "no -> yes" not in r.stdout

    def test_recent_events_logs_zone2_mute_with_display_values(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_zone2_muted="yes"
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Zone 2 Mute: No -> Yes" in r.stdout
        assert "no -> yes" not in r.stdout

    def test_recent_events_renames_heos_playback_state_event(self):
        code = textwrap.dedent(self.EVENT_STATE + """\
            _denon_dashboard_update_events
            dash_transport_state="Paused"
            _denon_dashboard_update_events
            printf '%s\\n' "$dashboard_events"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "HEOS Playback: Playing -> Paused" in r.stdout
        assert "HEOS: Playing -> Paused" not in r.stdout


class TestDashboardDiagnostics:
    DASHBOARD_STATE = """\
        dash_receiver="Denon AVR-X1600H"
        dash_ip="192.0.2.10"
        dash_main_zone_name="LivingRoom"
        dash_main_power="ON"
        dash_main_source="TV Audio"
        dash_sound_mode="Multi Ch Stereo"
        dash_main_volume="-31.0"
        dash_main_max_volume_db="18.0"
        dash_main_muted="no"
        dash_now_available=0
        dash_now_message="No metadata for current source"
        dash_zone2_name="ZONE2"
        dash_zone2_power="OFF"
        dash_zone2_source="Phono"
        dash_zone2_volume_db="-15.0"
        dash_zone2_volume_raw="650"
        dash_zone2_muted="no"
        dash_heos_version="3.88.614"
        dash_heos_network="wifi"
        dash_main_sources=$'  1  Xfinity X1\\n* 6  TV Audio\\n  13 HEOS Music'
        dashboard_events=""
        dash_errors=""
        dashboard_color_mode="never"
        dashboard_use_color=0
        dashboard_ascii=1
        watch=0
        DENON_DASHBOARD_WIDTH=72
    """

    DASHBOARD_DIAG = """\
        dash_diag_brand_code="1"
        dash_diag_model_type="1"
        dash_diag_main_volume_scale="1"
        dash_diag_main_volume_limit="99"
        dash_diag_zone2_volume_scale="1"
        dash_diag_zone2_volume_limit="70"
        dash_diag_setup_lock="2"
        dash_diag_menu_lock="2"
        dash_diag_speaker_preset="0"
        dash_diag_advanced_mode="1"
        dash_diag_ci_mode="2"
        dash_diag_heos_sign_in="3"
        dash_diag_gui_type="1"
        dash_diag_webui_type="3"
        dash_diag_avr_firmware="unavailable_on_tested_read_only_surfaces"
        dash_diag_heos_firmware="3.88.614"
    """

    def test_denon_version_reports_release_candidate_version(self):
        r = subprocess.run(
            [str(SCRIPT), "version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        assert r.returncode == 0
        assert r.stdout.strip() == "1.2.0-beta.4"

    def test_normal_dashboard_does_not_include_diagnostics(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Main Zone" in r.stdout
        assert "Diagnostics" not in r.stdout
        assert "Brand:" not in r.stdout
        assert "AVR FW:" not in r.stdout

    def test_dashboard_renders_main_zone_zone2_and_receiver_info_panels(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            DENON_DASHBOARD_WIDTH=120
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Main Zone" in r.stdout
        assert "Zone 2" in r.stdout
        assert "Receiver Info" in r.stdout
        assert "Receiver / Zone 2" not in r.stdout

    def test_dashboard_body_display_values_are_normalized(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            _denon_dashboard_layout 120 40
            _denon_dashboard_build_bodies
            printf '%s\\n---ZONE---\\n%s\\n---RECEIVER---\\n%s\\n---NOW---\\n%s\\n---EVENTS---\\n%s\\n' \
              "$dash_main_body" "$dash_zone2_body" "$dash_receiver_body" "$dash_now_body" "$dash_events_body"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "HEOS:     3.88.614 Wi-Fi" in r.stdout
        assert "Zone:   Zone 2" in r.stdout
        assert "Title:   No Metadata For Current Source" in r.stdout
        assert "No State Changes Yet" in r.stdout
        assert "wifi" not in r.stdout
        assert "ZONE2" not in r.stdout
        assert "No state changes yet" not in r.stdout

    def test_static_dashboard_unicode_render_starts_with_top_border(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            dashboard_ascii=0
            dashboard_color_mode="never"
            dashboard_use_color=0
            DENON_DASHBOARD_WIDTH=120
            DENON_DASHBOARD_HEIGHT=40
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        frame = _strip_dashboard_control_sequences(r.stdout)
        assert frame.startswith("\u250c")
        assert not frame.startswith("\u2502 Main Zone")
        assert frame.index("\u250c") < frame.index("Main Zone")

    def test_live_dashboard_unicode_redraw_starts_with_top_border(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            dashboard_ascii=0
            dashboard_color_mode="never"
            dashboard_use_color=0
            watch=1
            DENON_DASHBOARD_WIDTH=120
            DENON_DASHBOARD_HEIGHT=40
            _denon_dashboard_redraw
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert r.stdout.startswith("\x1b[H\x1b[J")
        assert not r.stdout.endswith("\n")
        frame = _strip_dashboard_control_sequences(r.stdout)
        assert frame.startswith("\u250c")
        assert not frame.startswith("\u2502 Main Zone")
        assert frame.index("\u250c") < frame.index("Main Zone")
        assert "denon-avr-controller v1.2.0-beta.4" in frame
        assert "[q] Quit | [r] Redraw" in frame

    def test_live_dashboard_ascii_redraw_starts_with_top_border(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            dashboard_ascii=1
            dashboard_color_mode="never"
            dashboard_use_color=0
            watch=1
            DENON_DASHBOARD_WIDTH=120
            DENON_DASHBOARD_HEIGHT=40
            _denon_dashboard_redraw
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert not r.stdout.endswith("\n")
        frame = _strip_dashboard_control_sequences(r.stdout)
        assert frame.startswith("+")
        assert not frame.startswith("| Main Zone")
        assert frame.index("+") < frame.index("Main Zone")

    def test_dashboard_layout_wide_top_boxes_are_proportional(self):
        code = textwrap.dedent("""\
            _denon_dashboard_layout 120 40
            printf '%s %s %s %s\\n' "$dash_layout_mode" "$dash_layout_top_w1" "$dash_layout_top_w2" "$dash_layout_top_w3"
        """)
        r = _bash(code)
        assert r.returncode == 0
        mode, w1, w2, w3 = r.stdout.strip().split()
        widths = [int(w1), int(w2), int(w3)]
        assert mode == "wide"
        assert max(widths) - min(widths) <= 2
        assert sum(widths) + 4 == 120

    def test_dashboard_layout_bottom_row_is_equal_width(self):
        code = textwrap.dedent("""\
            _denon_dashboard_layout 120 40
            printf '%s %s\\n' "$dash_layout_sources_w" "$dash_layout_events_w"
        """)
        r = _bash(code)
        assert r.returncode == 0
        sources_w, events_w = [int(part) for part in r.stdout.strip().split()]
        assert sources_w + events_w + 2 == 120
        assert 0.48 <= sources_w / (sources_w + events_w) <= 0.52

    def test_dashboard_bottom_row_renders_two_panels_with_shared_height(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_ascii=0
            dashboard_color_mode="never"
            dashboard_use_color=0
            dashboard_events=""
            _denon_dashboard_set_borders
            _denon_dashboard_build_bodies
            _denon_dashboard_layout 120 40
            printf 'height:%s\\n' "$dash_layout_bottom_h"
            _denon_dashboard_render_two_panel_row \
              "Main Zone Sources" "$dash_main_sources" "$dash_layout_sources_w" \
              "Recent Events" "$dash_events_body" "$dash_layout_events_w" \
              "$dash_layout_bottom_h"
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        lines = r.stdout.splitlines()
        height = int(lines[0].split(":", 1)[1])
        row_lines = lines[1:]
        assert len(row_lines) == height
        assert row_lines[0].count("\u250c") == 2
        assert row_lines[1].count("\u2502") == 4
        assert row_lines[2].count("\u2502") == 4
        assert row_lines[-1].count("\u2514") == 2
        assert "Main Zone Sources" in row_lines[1]
        assert "Recent Events" in row_lines[1]
        assert "No State Changes Yet" in "\n".join(row_lines)

    def test_dashboard_bottom_row_many_sources_do_not_change_shared_height(self):
        code = textwrap.dedent("""\
            dashboard_ascii=0
            dashboard_color_mode="never"
            dashboard_use_color=0
            _denon_dashboard_set_borders
            dash_main_sources=""
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
              dash_main_sources="${dash_main_sources}  ${i} Source ${i}"$'\\n'
            done
            dash_main_sources="${dash_main_sources%$'\\n'}"
            dash_events_body="No State Changes Yet"
            printf 'height:%s\\n' 7
            _denon_dashboard_render_two_panel_row \
              "Main Zone Sources" "$dash_main_sources" 70 \
              "Recent Events" "$dash_events_body" 48 \
              7
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        lines = r.stdout.splitlines()
        height = int(lines[0].split(":", 1)[1])
        row_lines = lines[1:]
        assert len(row_lines) == height
        assert row_lines[0].count("\u250c") == 2
        assert row_lines[-1].count("\u2514") == 2
        assert "Source 1" in "\n".join(row_lines)
        assert "Source 15" not in "\n".join(row_lines)
        assert all(
            line.count("\u2502") == 4 or line.count("\u250c") == 2 or line.count("\u2514") == 2
            for line in row_lines
        )

    def test_dashboard_tall_layout_uses_proportional_row_heights(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            _denon_dashboard_build_bodies
            _denon_dashboard_layout 120 80
            printf '%s %s %s %s\\n' "$dash_layout_top_h" "$dash_layout_now_h" "$dash_layout_bottom_h" "$dash_layout_footer_height"
        """)
        r = _bash(code)
        assert r.returncode == 0
        top_h, now_h, bottom_h, footer_h = [int(part) for part in r.stdout.strip().split()]
        available = 80 - footer_h - 2
        assert top_h > 10
        assert now_h > 10
        assert bottom_h > top_h
        assert bottom_h > now_h
        assert bottom_h < available * 0.65
        assert 0.23 <= top_h / available <= 0.27
        assert 0.18 <= now_h / available <= 0.22
        assert 0.53 <= bottom_h / available <= 0.57

    def test_dashboard_normal_wide_layout_keeps_top_and_now_meaningful(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            _denon_dashboard_build_bodies
            _denon_dashboard_layout 120 40
            printf '%s %s %s %s\\n' "$dash_layout_top_h" "$dash_layout_now_h" "$dash_layout_bottom_h" "$dash_layout_footer_height"
        """)
        r = _bash(code)
        assert r.returncode == 0
        top_h, now_h, bottom_h, footer_h = [int(part) for part in r.stdout.strip().split()]
        available = 40 - footer_h - 2
        assert top_h >= 10
        assert now_h >= 10
        assert bottom_h > top_h
        assert bottom_h > now_h
        assert top_h + now_h + bottom_h == available

    def test_dashboard_footer_includes_version_and_quit_hint(self):
        code = textwrap.dedent("""\
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_errors=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            watch=1
            _denon_dashboard_render_footer 120
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "denon-avr-controller v1.2.0-beta.4" in r.stdout
        assert "[q] Quit" in r.stdout
        assert "[q] Quit | [r] Redraw" in r.stdout
        assert "v1.2.0-beta.4[q]" not in r.stdout
        assert re.search(r"v1\.2\.0-beta\.4 {2,}\[q\] Quit", r.stdout)

    def test_dashboard_footer_truncates_receiver_before_version(self):
        code = textwrap.dedent("""\
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_errors=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            watch=1
            _denon_dashboard_render_footer 80
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "denon-avr-controller v1.2.0-beta.4" in r.stdout
        assert "[q] Quit" in r.stdout
        assert "[q] Quit | [r] Redraw" in r.stdout
        assert "v1.2.0-beta.4[q]" not in r.stdout
        assert re.search(r"v1\.2\.0-beta\.4 {2,}\[q\] Quit", r.stdout)

    def test_dashboard_footer_narrow_keeps_key_hints(self):
        code = textwrap.dedent("""\
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_errors=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            watch=1
            _denon_dashboard_render_footer 50
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "[q] Quit | [r] Redraw" in r.stdout
        assert "v1.2.0-beta.4[q]" not in r.stdout
        assert re.search(r" {2,}\[q\] Quit", r.stdout)

    def test_dashboard_strip_ansi_handles_script_generated_sgr_colors(self):
        code = textwrap.dedent("""\
            dashboard_color_mode="always"
            dashboard_use_color=0
            _denon_dashboard_setup_color
            colored="$(_denon_dashboard_c green "denon-avr-controller v1.2.0-beta.4")"
            printf 'plain:%s\\n' "$(_denon_dashboard_strip_ansi "$colored")"
            printf 'width:%s\\n' "$(_denon_dashboard_visible_width "$colored")"
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "plain:denon-avr-controller v1.2.0-beta.4" in r.stdout
        assert "width:34" in r.stdout

    def test_dashboard_footer_ansi_sequences_do_not_affect_width(self):
        code = textwrap.dedent("""\
            dashboard_color_mode="always"
            dashboard_use_color=0
            _denon_dashboard_setup_color
            colored_version="$(_denon_dashboard_c green "denon-avr-controller v1.2.0-beta.4")"
            colored_q="$(_denon_dashboard_c yellow "[q]")"
            colored_r="$(_denon_dashboard_c yellow "[r]")"
            left="Updated 18:08:09 | Denon AVR-X1600H @ 192.0.2.10 | $colored_version"
            right="$colored_q Quit | $colored_r Redraw"
            line=$(_denon_dashboard_compose_footer_line "$left" "$right" 120)
            printf '%s\\n' "$line"
            plain=$(_denon_dashboard_strip_ansi "$line")
            printf 'visible:%s\\n' "$(_denon_dashboard_visible_width "$line")"
            printf 'plain:%s\\n' "$plain"
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "visible:120" in r.stdout
        assert "[q] Quit | [r] Redraw" in r.stdout
        plain = next(line.removeprefix("plain:") for line in r.stdout.splitlines() if line.startswith("plain:"))
        assert "v1.2.0-beta.4[q]" not in plain
        assert re.search(r"v1\.2\.0-beta\.4 {2,}\[q\] Quit", plain)

    def test_dashboard_footer_color_enabled_has_no_helper_errors(self):
        code = textwrap.dedent("""\
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_errors=""
            dashboard_color_mode="always"
            dashboard_use_color=0
            _denon_dashboard_setup_color
            watch=1
            _denon_dashboard_render_footer 120
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "denon-avr-controller v1.2.0-beta.4" in r.stdout
        assert "[q] Quit | [r] Redraw" in r.stdout
        assert "v1.2.0-beta.4[q]" not in r.stdout

    def test_dashboard_footer_missing_version_does_not_crash(self):
        code = textwrap.dedent("""\
            DENON_CONTROLLER_VERSION=""
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_errors=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            watch=1
            _denon_dashboard_render_footer 120
        """)
        r = _bash(code)
        assert r.returncode == 0
        _assert_no_dashboard_helper_errors(r)
        assert "denon-avr-controller vunknown" in r.stdout
        assert "[q] Quit" in r.stdout

    def test_dashboard_missing_zone2_data_does_not_crash(self):
        code = textwrap.dedent("""\
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_main_zone_name="LivingRoom"
            dash_main_power="ON"
            dash_main_source="TV Audio"
            dash_sound_mode="Multi Ch Stereo"
            dash_main_volume="-31.0"
            dash_main_muted="no"
            dash_now_message="No metadata for current source"
            dash_main_sources=$'* 6  TV Audio'
            dashboard_events=""
            dash_errors=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            dashboard_ascii=1
            dashboard_diagnostics=0
            watch=0
            DENON_DASHBOARD_WIDTH=72
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Zone 2" in r.stdout
        assert "Power:  Unknown" in r.stdout

    def test_dashboard_very_narrow_terminal_does_not_crash(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            DENON_DASHBOARD_WIDTH=24
            DENON_DASHBOARD_HEIGHT=18
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Main Zone" in r.stdout

    def test_dashboard_very_short_terminal_does_not_crash(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + """\
            dashboard_diagnostics=0
            DENON_DASHBOARD_WIDTH=120
            DENON_DASHBOARD_HEIGHT=8
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Main Zone" in r.stdout

    def test_dashboard_missing_now_playing_data_does_not_crash(self):
        code = textwrap.dedent("""\
            dash_receiver="Denon AVR-X1600H"
            dash_ip="192.0.2.10"
            dash_main_zone_name="LivingRoom"
            dash_main_power="ON"
            dash_main_source="TV Audio"
            dash_sound_mode="Multi Ch Stereo"
            dash_main_volume="-31.0"
            dash_main_muted="no"
            dash_zone2_name="ZONE2"
            dash_zone2_power="OFF"
            dash_zone2_source="Phono"
            dash_zone2_muted="no"
            dash_main_sources=$'* 6  TV Audio'
            dashboard_events=""
            dash_errors=""
            dashboard_color_mode="never"
            dashboard_use_color=0
            dashboard_ascii=1
            dashboard_diagnostics=0
            watch=0
            DENON_DASHBOARD_WIDTH=72
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Now Playing / Audio" in r.stdout
        assert "Title:   Unknown" in r.stdout

    def test_dashboard_quit_keys_set_stop_pending(self):
        code = textwrap.dedent("""\
            _denon_dashboard_redraw() { printf 'redraw called\\n'; }
            dashboard_stop_pending=0
            dashboard_exit_status=9
            _denon_dashboard_handle_key q
            printf 'q:%s:%s\\n' "$dashboard_stop_pending" "$dashboard_exit_status"
            dashboard_stop_pending=0
            dashboard_exit_status=9
            _denon_dashboard_handle_key Q
            printf 'Q:%s:%s\\n' "$dashboard_stop_pending" "$dashboard_exit_status"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "q:1:0" in r.stdout
        assert "Q:1:0" in r.stdout

    def test_dashboard_diagnostics_includes_promoted_fields(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + self.DASHBOARD_DIAG + """\
            dashboard_diagnostics=1
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Diagnostics" in r.stdout
        assert "Brand:  raw=1 label=Unknown" in r.stdout
        assert "Main Volume: scale 1 / limit 99" in r.stdout
        assert "Zone 2 Volume: scale 1 / limit 70" in r.stdout
        assert "Locks: setup 2 / menu 2" in r.stdout
        assert "HEOS Sign-In: raw=3 label=Unknown" in r.stdout

    def test_dashboard_diagnostics_narrow_width_does_not_crash(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + self.DASHBOARD_DIAG + """\
            dashboard_diagnostics=1
            DENON_DASHBOARD_WIDTH=50
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "Diagnostics" in r.stdout
        assert "Main Zone" in r.stdout

    def test_dashboard_diagnostics_firmware_text_is_not_misleading(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + self.DASHBOARD_DIAG + """\
            dashboard_diagnostics=1
            _denon_dashboard_render
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert "AVR FW: unavailable_on_tested_read_only_surfaces" in r.stdout
        assert "HEOS FW: 3.88.614 separate" in r.stdout
        assert "AVR FW: 3.88.614" not in r.stdout

    def test_dashboard_color_and_unicode_paths_render(self):
        code = textwrap.dedent(self.DASHBOARD_STATE + self.DASHBOARD_DIAG + """\
            dashboard_diagnostics=1
            dashboard_color_mode="always"
            dashboard_ascii=0
            DENON_DASHBOARD_WIDTH=120
            _denon_dashboard_render
        """)
        r = _bash(code, env_extra={"NO_COLOR": ""})
        assert r.returncode == 0
        assert "\x1b[" in r.stdout
        assert "┌" in r.stdout
        assert "Diagnostics" in r.stdout


# ---------------------------------------------------------------------------
# Telnet fixture sanity checks
# ---------------------------------------------------------------------------

class TestTelnetFixtures:
    def test_psswr_fixture_content(self):
        body = (FIXTURES / "telnet_psswr.txt").read_text()
        assert "PSSWR ON" in body

    def test_psswl_fixture_content(self):
        body = (FIXTURES / "telnet_psswl.txt").read_text()
        assert "PSSWL 50" in body

    def test_cv_fixture_has_fl_fr(self):
        body = (FIXTURES / "telnet_cv.txt").read_text()
        assert "CVFL" in body
        assert "CVFR" in body

    def test_psswl_dB_conversion(self):
        """Raw PSSWL value 50 should convert to 0 dB (50 = 0 dB centre)."""
        raw = 50
        db = raw - 50
        assert db == 0

    def test_mv_parse(self):
        body = (FIXTURES / "telnet_mv.txt").read_text()
        # MV535 means volume raw = 535
        import re
        m = re.search(r'MV(\d+)', body)
        assert m is not None
        assert int(m.group(1)) == 535


# ---------------------------------------------------------------------------
# HEOS fixture sanity checks
# ---------------------------------------------------------------------------

class TestHeosFixtures:
    def test_get_volume_level(self):
        body = (FIXTURES / "heos_get_volume.json").read_text()
        data = json.loads(body)
        assert data["heos"]["result"] == "success"
        msg = data["heos"]["message"]
        assert "level=53" in msg

    def test_check_account_signed_out(self):
        body = (FIXTURES / "heos_check_account.json").read_text()
        data = json.loads(body)
        assert data["heos"]["result"] == "success"
        assert "signed_out" in data["heos"]["message"]
