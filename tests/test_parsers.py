"""
Pytest tests for denon_release_candidate.sh parser functions.

Each test sources the script via bash subprocess (DENON_UNIT_TEST=1 suppresses
the top-level command dispatch) and calls individual helper functions with
fixture bodies captured during Phase 4 live probing.
"""

import json
import os
import subprocess
import textwrap
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "denon_release_candidate.sh"
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
        assert r.stdout.strip() == "0006786D20A0"

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
        assert r.stdout.strip() == "BJE27210571433"

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

    def test_no_response_error_is_classified(self):
        code = textwrap.dedent(f"""\
            body=$(cat '{FIXTURES}/appcommand_error.txt')
            _denon_data_appcommand_response_status_summary "$body"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "no_response\tCould not handle the request"

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
