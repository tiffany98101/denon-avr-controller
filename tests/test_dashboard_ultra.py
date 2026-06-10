"""
Tests for the dashboard-ultra (udash) alternate dashboard.

Covers the AppCommand batch response splitter/parsers (using XML captured
live from an AVR-X1600H), the pipelined-telnet demuxer, and rendered-layout
alignment at the ultra (>=200), mid (120-199), and narrow (<120) breakpoints.
"""

import os
import re
import subprocess
import textwrap
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "denon.sh"
SCRIPT_STR = str(SCRIPT)

# Captured live from AVR-X1600H (fw 3.34.620) on 2026-06-09.
APPCMD1_XML = """\
<?xml version="1.0" encoding="utf-8" ?>
<rx>
<cmd>
<zone1>ON</zone1>
<zone2>OFF</zone2>
</cmd>
<cmd>
<zone1>
<source>TV</source>
</zone1>
<zone2>
<source>PHONO</source>
</zone2>
</cmd>
<cmd>
<zone1>
<volume>-37.5</volume>
<state>variable</state>
<limit>OFF</limit>
<disptype>ABSOLUTE</disptype>
<dispvalue>42.5</dispvalue>
</zone1>
<zone2>
<volume>-15</volume>
<state>variable</state>
<limit>-10.0</limit>
<disptype>ABSOLUTE</disptype>
<dispvalue> 65</dispvalue>
</zone2>
</cmd>
<cmd>
<zone1>off</zone1>
<zone2>off</zone2>
</cmd>
<cmd>
<surround>Multi Ch Stereo                  </surround>
</cmd>
<cmd>
<list>
<listvalue>
<zone>Main</zone>
<value>0</value>
</listvalue>
<listvalue>
<zone>Zone2</zone>
<value>0</value>
</listvalue>
</list>
</cmd>
<cmd>
<zone1>LivingRoom</zone1>
<zone2>ZONE2     </zone2>
</cmd>
</rx>
"""

APPCMD2_XML = """\
<rx>
<cmd>
<status>0</status>
<adjust></adjust>
<bassvalue></bassvalue>
<treblevalue></treblevalue>
</cmd>
<cmd>
<status>1</status>
<level>-6.5dB</level>
<value>11</value>
</cmd>
<cmd>
<status>0</status>
<sw1level></sw1level>
</cmd>
<cmd>
<status>1</status>
<chlists>
<ch>
<name>C</name>
<status>1</status>
<level>0.0dB</level>
</ch>
<ch>
<name>SW</name>
<status>0</status>
<level></level>
</ch>
<ch>
<name>FL</name>
<status>1</status>
<level>0.0dB</level>
</ch>
<ch>
<name>FR</name>
<status>1</status>
<level>0.0dB</level>
</ch>
<ch>
<name>SL</name>
<status>1</status>
<level>-1.5dB</level>
</ch>
<ch>
<name>SR</name>
<status>1</status>
<level>0.0dB</level>
</ch>
</chlists>
</cmd>
<cmd>
<status>1</status>
<value>0</value>
</cmd>
</rx>
"""

TELNET_TEXT = (
    "MSMCH STEREO\r\nPSDRC OFF\r\nPSLFE 00\r\nPSBAS 52\r\nPSTRE 50\r\n"
    "PSTONE CTRL OFF\r\nSSINFAISSIG 02\r\nSYSDA PCM    \r\nSSINFAISFSV 48K\r\n"
    "ECOOFF\r\nDIM BRI\r\nSYSMI Multi Ch Stereo\r\nSLPOFF\r\nZ2SLP060\r\n"
)

SET_RENDER_VARS = textwrap.dedent("""\
    dash_receiver="Denon AVR-X1600H"; dash_ip="192.168.1.162"
    dash_main_zone_name="LivingRoom"; dash_main_power="On"; dash_main_source="TV"
    dash_main_volume="-37.5"; dash_main_max_volume_db=""; dash_main_muted="no"
    dash_sound_mode="Multi Ch Stereo"; dash_transport_state="play"
    dash_heos_model="HEOS AVR"; dash_heos_version="3.34.620"; dash_heos_network="wired"
    dash_zone2_name="ZONE2"; dash_zone2_power="Off"; dash_zone2_source="PHONO"
    dash_zone2_volume="Unknown"; dash_zone2_volume_db="-15"; dash_zone2_volume_raw="65"; dash_zone2_muted="no"
    dash_now_message=""; dash_now_title="Song — Title"; dash_now_artist="Artist"; dash_now_album="Album"
    dash_now_station=""; dash_now_service="Spotify"; dash_now_available=1; dash_errors=""
    dash_main_sources=$(printf '* 1  HEOS Music\\n  2  Blu-ray\\n  3  CBL/SAT\\n  4  Game\\n  5  TV Audio\\n  6  Media Player\\n  7  Bluetooth\\n  8  Tuner')
    dash_u_signal="PCM"; dash_u_signal_code="02"; dash_u_sample_rate="48K"
    dash_u_sleep_main="OFF"; dash_u_sleep_zone2="OFF"; dash_u_bass_raw="50"; dash_u_treble_raw="50"
    dash_u_drc="OFF"; dash_u_lfe="00"; dash_u_tone_ctrl="OFF"; dash_u_eco="OFF"; dash_u_dimmer="BRI"
    dash_u_tone_status="Off"; dash_u_dialog="-6.5 dB"; dash_u_sub="None"
    dash_u_chlevels_line1="C 0.0  FL 0.0  FR 0.0"; dash_u_chlevels_line2="SL 0.0  SR 0.0"
    dash_u_speaker_config="5.0"; dash_u_azs="Off"; dash_u_standby="Main Off / Zone2 Off"
    dash_u_zone2_limit="-10.0"; udash_tv=0; udash_tv_body=""
    dash_u_dynamic_eq="On"; dash_u_dynamic_volume="Light"; dash_u_multeq="Reference"
    dash_u_cinema_eq="Off"; dash_u_loudness_management="On"; dash_u_subwoofer_level_db="-3 dB"
    dash_u_heos_volume_level="42"; dash_u_brand_code="7"; dash_u_model_type="1"
    dash_u_main_volume_scale="7"; dash_u_main_volume_limit_raw="99"
    dash_u_zone2_volume_scale="1"; dash_u_zone2_volume_limit_raw="70"
    dash_u_aios_firmware="Aios 4.025"; dash_u_serial_number="ABC1234567"
    dash_u_upnp_mac="00:11:22:33:44:55"; dash_u_comm_api_vers="0301"
    dash_u_device_zones="2"; dash_u_upnp_model="AVR-X1600H"; dash_u_udn="uuid:denon-test"
    dash_u_pending_upgrade_version="01.02.03"
    dash_u_setup_lock="2"; dash_u_menu_lock="2"; dash_u_advanced_mode="1"; dash_u_ci_mode="2"
    dash_u_gui_type="1"; dash_u_webui_type="3"; dash_u_heos_sign_in="3"; dash_u_speaker_preset="0"
    dash_u_product_type="219"; dash_u_bt_headphones_single_used="0"
    dashboard_events=""; dashboard_ascii=0; dashboard_color_mode=never; dashboard_use_color=0; watch=0
""")


def _bash(code: str, env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["DENON_UNIT_TEST"] = "1"
    if env_extra:
        env.update(env_extra)
    full = f"source {SCRIPT_STR}\n{code}"
    return subprocess.run(
        ["bash", "-c", full],
        capture_output=True,
        text=True,
        env=env,
        timeout=20,
    )


def _strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)


def _display_width(s: str) -> int:
    b = s.encode("utf-8")
    cont = sum(1 for byte in b if 0x80 <= byte <= 0xBF)
    return len(b) - cont


class TestAppcmdBlockSplitter:
    def test_block_extraction_positional(self):
        code = textwrap.dedent("""\
            _denon_udash_appcmd_block "$RESP" 5
        """)
        r = _bash(code, env_extra={"RESP": APPCMD1_XML})
        assert r.returncode == 0
        assert "<surround>" in r.stdout
        assert "<zone1>" not in r.stdout

    def test_error_blocks_count_as_slots(self):
        resp = "<rx>\n<cmd>\n<a>1</a>\n</cmd>\n<error>2</error>\n<cmd>\n<b>3</b>\n</cmd>\n</rx>"
        r = _bash('_denon_udash_appcmd_block "$RESP" 3', env_extra={"RESP": resp})
        assert r.returncode == 0
        assert "<b>3</b>" in r.stdout

    def test_tail_reindexes_remaining_blocks(self):
        # Combined 12-verb response: blocks 8+ must parse as 1+ after the tail.
        combined = APPCMD1_XML.rstrip()[: -len("</rx>")] + APPCMD2_XML.split("<rx>")[1]
        code = textwrap.dedent("""\
            tail=$(_denon_udash_appcmd_tail "$RESP" 7)
            _denon_udash_parse_appcmd2 "$tail"
            printf '%s|%s|%s\\n' "$dash_u_dialog" "$dash_u_speaker_config" "$dash_u_azs"
        """)
        r = _bash(code, env_extra={"RESP": combined})
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "-6.5 dB|5.0|Off"


class TestAppcmd1Parse:
    def test_full_parse(self):
        code = textwrap.dedent("""\
            dash_sound_mode=Unknown
            _denon_udash_parse_appcmd1 "$RESP"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' \\
              "$dash_main_power" "$dash_zone2_power" "$dash_main_source" "$dash_zone2_source" \\
              "$dash_main_volume" "$dash_zone2_volume_db" "$dash_zone2_volume_raw" \\
              "$dash_sound_mode" "$dash_u_standby" "$dash_main_zone_name"
        """)
        r = _bash(code, env_extra={"RESP": APPCMD1_XML})
        assert r.returncode == 0, r.stderr
        fields = r.stdout.strip().split("|")
        assert fields == [
            "On", "Off", "TV", "PHONO", "-37.5", "-15", "65",
            "Multi Ch Stereo", "Main Off / Zone2 Off", "LivingRoom",
        ]


class TestAppcmd2Parse:
    def test_full_parse(self):
        code = textwrap.dedent("""\
            _denon_udash_parse_appcmd2 "$RESP"
            printf '%s|%s|%s|%s|%s|%s|%s\\n' \\
              "$dash_u_tone_status" "$dash_u_dialog" "$dash_u_sub" "$dash_u_azs" \\
              "$dash_u_speaker_config" "$dash_u_chlevels_line1" "$dash_u_chlevels_line2"
        """)
        r = _bash(code, env_extra={"RESP": APPCMD2_XML})
        assert r.returncode == 0, r.stderr
        fields = r.stdout.strip().split("|")
        assert fields == [
            "Off", "-6.5 dB", "None", "Off", "5.0",
            "C 0.0  FL 0.0  FR 0.0", "SL -1.5  SR 0.0",
        ]


class TestTelnetParse:
    def test_demux(self):
        code = textwrap.dedent("""\
            dash_sound_mode=Unknown
            _denon_udash_parse_telnet "$TXT"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' \\
              "$dash_sound_mode" "$dash_u_signal" "$dash_u_sample_rate" \\
              "$dash_u_sleep_main" "$dash_u_sleep_zone2" "$dash_u_bass_raw" \\
              "$dash_u_eco" "$dash_u_dimmer" "$dash_u_tone_ctrl"
        """)
        r = _bash(code, env_extra={"TXT": TELNET_TEXT})
        assert r.returncode == 0, r.stderr
        fields = r.stdout.strip().split("|")
        assert fields == [
            "Multi Ch Stereo", "PCM", "48K", "OFF", "060", "52", "OFF", "BRI", "OFF",
        ]


class TestLabelHelpers:
    def test_labels(self):
        code = textwrap.dedent("""\
            printf '%s|%s|%s|%s|%s|%s\\n' \\
              "$(_denon_udash_sleep_label 060)" "$(_denon_udash_sleep_label OFF)" \\
              "$(_denon_udash_tone_db 52)" "$(_denon_udash_lfe_label 05)" \\
              "$(_denon_udash_dimmer_label BRI)" "$(_denon_udash_sample_rate_label 48K)"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "60 min|Off|+2 dB|-5 dB|Bright|48 kHz"


class TestUdashRenderAlignment:
    """Every rendered line must have identical display width at each breakpoint."""

    def _render(self, width: int, height: int = 45) -> list[str]:
        code = SET_RENDER_VARS + "\n_denon_udash_render\n"
        r = _bash(code, env_extra={
            "DENON_DASHBOARD_WIDTH": str(width),
            "DENON_DASHBOARD_HEIGHT": str(height),
        })
        assert r.returncode == 0, f"bash error: {r.stderr}"
        output = _strip_ansi(r.stdout)
        return [ln for ln in output.split("\n") if ln]

    def _assert_uniform(self, width: int):
        lines = self._render(width)
        assert lines, "expected rendered output"
        # The footer line is composed to fit, not padded; check bordered lines.
        bordered = [ln for ln in lines if ln.lstrip().startswith(("┌", "│", "└", "+", "|"))]
        assert bordered, "expected bordered card lines"
        widths = {_display_width(ln) for ln in bordered}
        assert widths == {width}, (
            f"Misaligned right borders at width {width}: got widths {sorted(widths)}"
        )

    def test_ultra_220(self):
        self._assert_uniform(220)

    def test_mid_150(self):
        self._assert_uniform(150)

    def test_narrow_100(self):
        self._assert_uniform(100)

    def test_mode_selection(self):
        code = textwrap.dedent("""\
            udash_tv=0
            _denon_udash_layout 220 45; printf '%s ' "$udash_mode"
            _denon_udash_layout 150 45; printf '%s ' "$udash_mode"
            _denon_udash_layout 100 45; printf '%s\\n' "$udash_mode"
        """)
        r = _bash(code)
        assert r.returncode == 0
        assert r.stdout.strip() == "ultra mid narrow"

    def test_multibyte_now_playing_stays_aligned(self):
        # Em-dash in title comes via SET_RENDER_VARS ("Song — Title").
        self._assert_uniform(220)

    def test_priority_fill_respects_small_grid(self):
        lines = self._render(80, 24)
        text = "\n".join(lines)
        assert len(lines) <= 24
        for required in [
            "Power:   On",
            "Source:  TV",
            "Volume:  -37.5 dB",
            "Muted:   No",
            "Power:   Off",
            "Now:     Song",
            "State:   Playing",
            "Receiver: Denon AVR-X1600H",
            "IP:      192.168.1.162",
            "Recent Events",
        ]:
            assert required in text
        for shed in ["Audio Signal", "DSP / Audyssey", "Device / Firmware", "System / Locks"]:
            assert shed not in text

    def test_priority_fill_large_grid_surfaces_low_priority_panels(self):
        lines = self._render(320, 90)
        text = "\n".join(lines)
        assert len(lines) <= 90
        for expected in [
            "DSP / Audyssey",
            "Dynamic EQ: On",
            "HEOS Vol: 42",
            "Device / Firmware",
            "AIOS FW: Aios 4.025",
            "Serial:  ABC1234567",
            "System / Locks",
            "Setup Lock: 2",
            "Product: 219",
            "Update:  01.02.03",
        ]:
            assert expected in text
