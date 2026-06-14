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
    # Keep render/layout tests independent of the developer's real saved Denon
    # config/profile. Source-time config loading can otherwise make tests pass or
    # fail based on ~/.config/denon/config values such as panel selections.
    env.pop("DENON_PROFILE", None)
    for key in list(env):
        if key.startswith("DENON_DASHBOARD_ULTRA_"):
            env.pop(key, None)
    env.setdefault("DENON_CONFIG", os.devnull)
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


class TestUdashConfiguration:
    def test_config_file_loads_dashboard_ultra_defaults(self, tmp_path):
        config = tmp_path / "denon.conf"
        config.write_text(
            "\n".join(
                [
                    "DENON_DASHBOARD_ULTRA_WATCH=1",
                    "DENON_DASHBOARD_ULTRA_INTERVAL=7",
                    "DENON_DASHBOARD_ULTRA_TV=1",
                    "DENON_DASHBOARD_ULTRA_COLOR=never",
                    "DENON_DASHBOARD_ULTRA_ASCII=1",
                    "DENON_DASHBOARD_ULTRA_PANELS=main,zone2,events",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        code = textwrap.dedent("""\
            _denon_load_config "$DENON_CONFIG"
            printf '%s|%s|%s|%s|%s|%s\\n' \\
              "$DENON_DASHBOARD_ULTRA_WATCH" "$DENON_DASHBOARD_ULTRA_INTERVAL" \\
              "$DENON_DASHBOARD_ULTRA_TV" "$DENON_DASHBOARD_ULTRA_COLOR" \\
              "$DENON_DASHBOARD_ULTRA_ASCII" "$DENON_DASHBOARD_ULTRA_PANELS"
        """)
        r = _bash(code, env_extra={"DENON_CONFIG": str(config)})
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "1|7|1|never|1|main,zone2,events"

    def test_dashboard_ultra_uses_configured_defaults(self):
        code = textwrap.dedent("""\
            _denon_udash_collect_responsive() { :; }
            _denon_dashboard_update_events() { :; }
            _denon_dashboard_restore_terminal() { :; }
            _denon_udash_redraw() {
              printf 'watch=%s interval=%s tv=%s color=%s ascii=%s\\n' \
                "$watch" "$interval" "$udash_tv" "$dashboard_color_mode" "$dashboard_ascii"
              dashboard_stop_pending=1
            }
            _denon_dashboard_ultra
        """)
        r = _bash(
            code,
            env_extra={
                "DENON_DASHBOARD_ULTRA_WATCH": "1",
                "DENON_DASHBOARD_ULTRA_INTERVAL": "7",
                "DENON_DASHBOARD_ULTRA_TV": "1",
                "DENON_DASHBOARD_ULTRA_COLOR": "never",
                "DENON_DASHBOARD_ULTRA_ASCII": "1",
            },
        )
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "\x1b[?25lwatch=1 interval=7 tv=1 color=never ascii=1"

    def test_dashboard_ultra_cli_options_override_configured_defaults(self):
        code = textwrap.dedent("""\
            _denon_udash_collect_responsive() { :; }
            _denon_dashboard_update_events() { :; }
            _denon_dashboard_restore_terminal() { :; }
            _denon_udash_redraw() {
              printf 'watch=%s interval=%s tv=%s color=%s ascii=%s\\n' \
                "$watch" "$interval" "$udash_tv" "$dashboard_color_mode" "$dashboard_ascii"
              dashboard_stop_pending=1
            }
            _denon_dashboard_ultra --watch 2 --tv --color always --unicode
        """)
        r = _bash(
            code,
            env_extra={
                "DENON_DASHBOARD_ULTRA_WATCH": "0",
                "DENON_DASHBOARD_ULTRA_INTERVAL": "7",
                "DENON_DASHBOARD_ULTRA_TV": "0",
                "DENON_DASHBOARD_ULTRA_COLOR": "never",
                "DENON_DASHBOARD_ULTRA_ASCII": "1",
            },
        )
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "\x1b[?25lwatch=1 interval=2 tv=1 color=always ascii=0"

    def test_dashboard_ultra_setup_prints_setup_options(self, tmp_path):
        r = _bash("_denon_dashboard_ultra setup", env_extra={"DENON_CONFIG": str(tmp_path / "missing.conf")})
        assert r.returncode == 0, r.stderr
        out = r.stdout
        assert "Dashboard Ultra setup options" in out
        assert "panels:   all" in out
        assert "denon config set DENON_DASHBOARD_ULTRA_PANELS" in out
        assert "Panel keys:" in out
        assert "main, zone2, now, events, receiver, audio, tone, sources, tv, dsp, firmware" in out
        assert "denon config set DENON_DASHBOARD_ULTRA_WATCH 1" in out
        assert "denon config set DENON_DASHBOARD_ULTRA_INTERVAL 5" in out
        assert "denon profile set livingroom DENON_DASHBOARD_ULTRA_WATCH 1" in out
        assert "denon setip <receiver-ip>" in out

    def test_dashboard_ultra_setup_reflects_configured_defaults(self):
        r = _bash(
            "_denon_dashboard_ultra --setup",
            env_extra={
                "DENON_DASHBOARD_ULTRA_WATCH": "1",
                "DENON_DASHBOARD_ULTRA_INTERVAL": "7",
                "DENON_DASHBOARD_ULTRA_TV": "1",
                "DENON_DASHBOARD_ULTRA_COLOR": "never",
                "DENON_DASHBOARD_ULTRA_ASCII": "1",
                "DENON_DASHBOARD_ULTRA_PANELS": "main,zone2,sources",
            },
        )
        assert r.returncode == 0, r.stderr
        out = r.stdout
        assert "watch:    1" in out
        assert "interval: 7" in out
        assert "tv:       1" in out
        assert "color:    never" in out
        assert "ascii:    1" in out
        assert "panels:   main,zone2,sources" in out


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

    def test_panel_selection_filters_dashboard_cards(self):
        code = SET_RENDER_VARS + "\n_denon_udash_render\n"
        r = _bash(
            code,
            env_extra={
                "DENON_DASHBOARD_WIDTH": "150",
                "DENON_DASHBOARD_HEIGHT": "35",
                "DENON_DASHBOARD_ULTRA_PANELS": "main,zone2,sources",
            },
        )
        assert r.returncode == 0, r.stderr
        output = _strip_ansi(r.stdout)
        assert "Main" in output
        assert "Zone 2" in output
        assert "Sources (Main)" in output
        assert "Now Playing" not in output
        assert "Recent Events" not in output
        assert "Receiver / Network" not in output
        assert "DSP / Audyssey" not in output

    def test_panel_selection_none_falls_back_to_all_panels(self):
        code = SET_RENDER_VARS + "\n_denon_udash_render\n"
        r = _bash(
            code,
            env_extra={
                "DENON_DASHBOARD_WIDTH": "150",
                "DENON_DASHBOARD_HEIGHT": "35",
                "DENON_DASHBOARD_ULTRA_PANELS": "none",
            },
        )
        assert r.returncode == 0, r.stderr
        output = _strip_ansi(r.stdout)
        assert "Main" in output
        assert "Zone 2" in output
        assert "Now Playing" in output
        assert "Recent Events" in output
        assert "Receiver / Network" in output

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
        # Labels are padded to the widest label of their panel, so match
        # "label: value" with flexible spacing.
        for label, value in [
            ("Power", "On"),
            ("Source", "TV"),
            ("Volume", "-37.5 dB"),
            ("Muted", "No"),
            ("Power", "Off"),
            ("Now", "Song"),
            ("State", "Playing"),
            ("Receiver", "Denon AVR-X1600H"),
            ("IP", "192.168.1.162"),
        ]:
            assert re.search(rf"{re.escape(label)}: +{re.escape(value)}", text), (
                f"missing '{label}: {value}' in:\n{text}"
            )
        assert "Recent Events" in text
        for shed in ["Audio Signal", "DSP / Audyssey", "Device / Firmware", "System / Locks"]:
            assert shed not in text

    def test_priority_fill_large_grid_surfaces_low_priority_panels(self):
        lines = self._render(320, 90)
        text = "\n".join(lines)
        assert len(lines) <= 90
        for expected in [
            "DSP / Audyssey",
            # Device / Firmware now lives in the pinned bottom band.
            "Device / Firmware",
            "Recent Events",
        ]:
            assert expected in text
        for label, value in [
            ("Dynamic EQ", "On"),
            ("HEOS Vol", "42"),
            ("AIOS FW", "Aios 4.025"),
            ("Serial", "ABC1234567"),
            ("Update", "01.02.03"),
        ]:
            assert re.search(rf"{re.escape(label)}: +{re.escape(value)}", text), (
                f"missing '{label}: {value}' in:\n{text}"
            )
        # System / Locks is a tier-3 panel and surfaces at this large size; its
        # fields are collected every cycle and must render, not just be gathered.
        assert "System / Locks" in text
        for label, value in [("Setup Lock", "2"), ("Menu Lock", "2"), ("CI Mode", "2")]:
            assert re.search(rf"{re.escape(label)}: +{re.escape(value)}", text), (
                f"missing '{label}: {value}' in:\n{text}"
            )

    def test_sources_panel_preserves_source_names_in_large_adaptive_row(self):
        lines = self._render(320, 90)
        source_lines = []
        in_source_row = False

        for line in lines:
            if "Sources (Main)" in line:
                in_source_row = True
            elif in_source_row and line.startswith("└"):
                break
            if in_source_row:
                source_lines.append(line)

        text = "\n".join(source_lines)
        # Entries are normalized to "<marker> <index> <name>" with the index
        # right-aligned, so single spacing is canonical.
        for expected in [
            "* 1 HEOS Music",
            "2 Blu-ray",
            "3 CBL/SAT",
            "4 Game",
            "5 TV Audio",
            "6 Media Player",
            "7 Bluetooth",
            "8 Tuner",
        ]:
            assert expected in text
        assert not re.search(r"\b\d\.\.\.", text)

    def test_panel_values_share_one_column(self):
        # Every key:value panel pads labels to the widest label of that panel,
        # so all values start at the same column — including long labels such
        # as "Model Type:", "Vol Scale:", "UPnP MAC:", and "Dynamic Vol:".
        lines = self._render(200, 55)
        # Walk bordered grid rows; group panel content by the column at which
        # the panel's left border sits.
        value_cols: dict[tuple[int, int], set[int]] = {}
        panel_id = 0
        open_panels: dict[int, int] = {}
        for line in lines:
            for m in re.finditer(r"[┌+](?=─|-)", line):
                panel_id += 1
                open_panels[m.start()] = panel_id
            for m in re.finditer(r"[└+](?=─|-)", line):
                open_panels.pop(m.start(), None)
            for col, pid in open_panels.items():
                seg = line[col:]
                kv = re.match(r"[│|] ([A-Za-z][A-Za-z0-9 /-]*): +(?=\S)", seg)
                if kv:
                    value_cols.setdefault((col, pid), set()).add(kv.end())
        for (col, pid), cols in value_cols.items():
            assert len(cols) == 1, (
                f"panel at col {col} has ragged value columns {sorted(cols)}:\n"
                + "\n".join(lines)
            )

    def test_continuation_lines_indent_to_value_column(self):
        # The "Levels:" channel-level continuation must indent to the value
        # column of its panel, not column 0.
        lines = self._render(220, 55)
        text = "\n".join(lines)
        levels = re.search(r"Levels: +(?=\S)", text)
        assert levels, f"Levels row missing:\n{text}"
        value_col_text = levels.group(0)
        # _denon_trim collapses internal whitespace runs, so the rendered
        # channel-level rows are single-spaced.
        m1 = re.search(r"([│|] +)Levels: +C 0\.0", text)
        m2 = re.search(r"([│|] +)SL 0\.0 SR 0\.0", text)
        assert m1 and m2, f"Levels/continuation rows missing:\n{text}"
        # Continuation starts where the Levels value starts.
        assert len(m2.group(1)) == len(m1.group(1)) + len(value_col_text), (
            f"continuation not indented to value column:\n{text}"
        )

    def test_sources_indices_right_aligned_with_fixed_marker_column(self):
        # Mixed one- and two-digit indices must not shift names; the "*"
        # selected marker keeps its own column.
        mixed = (
            "dash_main_sources=$(printf '  1  HEOS Music\\n  2  Blu-ray\\n"
            "* 4  TV Audio\\n  9  Phono\\n  10  AUX\\n  13  Internet Radio')\n"
        )
        code = SET_RENDER_VARS + mixed + "_denon_udash_render\n"
        r = _bash(code, env_extra={
            "DENON_DASHBOARD_WIDTH": "220",
            "DENON_DASHBOARD_HEIGHT": "55",
        })
        assert r.returncode == 0, f"bash error: {r.stderr}"
        text = _strip_ansi(r.stdout)
        # Indices right-align to the widest index and names start one space
        # after; the marker column precedes the index field.
        for entry in [" 1 HEOS Music", " 2 Blu-ray", "*  4 TV Audio",
                      " 9 Phono", "10 AUX", "13 Internet Radio"]:
            assert entry in text, f"missing normalized entry {entry!r}:\n{text}"
        # Slice out the Sources panel by its border span, then verify all
        # names within each rendered sources column share one offset.
        lines = text.split("\n")
        title_line = next(ln for ln in lines if "Sources (Main)" in ln)
        borders = [i for i, ch in enumerate(title_line) if ch in "│|"]
        t = title_line.index("Sources (Main)")
        left = max(i for i in borders if i < t)
        right = min(i for i in borders if i > t)
        offsets: dict[int, set[int]] = {}
        for line in lines:
            seg = line[left:right]
            for m in re.finditer(r"([* ]) ( ?)(\d+) (\S)", seg):
                offsets.setdefault(m.start(1), set()).add(m.start(4) - m.start(1))
        assert offsets, f"no source entries found in panel slice:\n{text}"
        for col, offs in offsets.items():
            assert len(offs) == 1, f"names misaligned at col {col}: {sorted(offs)}\n{text}"


class TestUdashRecentEventsPriority:
    """Recent Events is pinned to the bottom band and must always render.

    The dashboard-ultra layout renders Recent Events (paired with Device /
    Firmware at multi-column widths, full-width when narrow) as a dedicated
    bottom band, independent of how the adaptive grid above sheds panels.
    System / Locks renders as a tier-3 panel when there is room. These are
    *semantic* checks on the rendered panels, not line counts or border alignment.
    """

    OPTIONAL_PANELS = [
        "Audio Signal",
        "Tone / Levels",
        "TV (lgtv)",
        "DSP / Audyssey",
        "Device / Firmware",
    ]

    def _render(self, width: int, height: int) -> str:
        # The screenshot showed the keyboard hint footer (interactive watch),
        # so exercise the same footer height here.
        pre = "udash_tv=1\ndashboard_keyboard_active=1\n"
        code = SET_RENDER_VARS + pre + "_denon_udash_render\n"
        r = _bash(code, env_extra={
            "DENON_DASHBOARD_WIDTH": str(width),
            "DENON_DASHBOARD_HEIGHT": str(height),
        })
        assert r.returncode == 0, f"bash error: {r.stderr}"
        return _strip_ansi(r.stdout)

    def test_recent_events_always_present(self):
        # Recent Events is pinned, so it must render at every size, including
        # wide-but-short panes that used to blank the entire dashboard.
        for width, height in [
            (320, 50), (280, 45), (240, 40), (200, 30),
            (200, 18), (200, 16), (150, 30), (80, 24),
        ]:
            text = self._render(width, height)
            assert "Recent Events" in text, (
                f"Recent Events missing at {width}x{height}; rendered:\n{text}"
            )

    def test_now_top_band_and_recent_events_bottom_band_when_wide(self):
        # At wide widths Now Playing is the full-width top band (above the grid)
        # and Recent Events is the full-width bottom band (below the grid). With
        # enough rows the fixed Device / Firmware grid panel is also present.
        text = self._render(280, 55)
        assert "Now Playing" in text
        assert "Recent Events" in text
        assert "Device / Firmware" in text
        # Now Playing leads (top band); Recent Events trails (bottom band).
        assert text.index("Now Playing") < text.index("LivingRoom (Main)")
        assert text.index("Receiver / Network") < text.index("Recent Events")
        assert text.index("Device / Firmware") < text.index("Recent Events")

    def test_system_locks_panel_restored_when_room(self):
        # System / Locks is a tier-3 panel: it renders when there is room and
        # sheds with the other tier-3 content on small panes (it is never a
        # must-keep panel, so Recent Events still wins the bottom band).
        text = self._render(320, 90)
        assert "System / Locks" in text
        assert re.search(r"Setup Lock: +2", text)
        # On an 80x24 pane every tier-3 panel sheds, System / Locks included.
        text_small = self._render(80, 24)
        assert "System / Locks" not in text_small

    def test_optional_panels_never_shown_without_recent_events(self):
        # Whenever any optional/low-priority panel is visible, the Recent Events
        # band must be visible too. Swept across wide widths and moderate
        # heights, not just the 80x24 / 320x90 extremes.
        for width in [220, 260, 320]:
            for height in [28, 34, 40]:
                text = self._render(width, height)
                shown = [p for p in self.OPTIONAL_PANELS if p in text]
                if shown:
                    assert "Recent Events" in text, (
                        f"At {width}x{height} optional panels {shown} are visible "
                        f"but Recent Events is missing:\n{text}"
                    )


class TestUdashSlackFill:
    """The grid fills the viewport (no dead band) and growable panels expand to
    fill the slack instead of truncating while free rows sit below.
    """

    # Ten sources, so "+N more" only appears when genuinely out of rows.
    SOURCES_ITEMS = [
        "* 1  CBL/SAT", "  2  DVD", "  3  Blu-ray", "  4  Game",
        "  5  Media Player", "  6  TV Audio", "  7  AUX", "  8  CD",
        "  9  Phono", "  10 HEOS Music",
    ]
    EVENT_ITEMS = ["[09:01] Main power On", "[09:02] Volume -37.5", "[09:03] Source TV"]

    def _printf_lines(self, var: str, items: list[str]) -> str:
        # printf '%s\n' 'a' 'b' ... -> one real newline per item (no %b escaping
        # pitfalls). The \n is a single backslash so bash printf expands it.
        args = " ".join("'" + s + "'" for s in items)
        return f"{var}=$(printf '%s\\n' {args})\n"

    def _render(self, width: int, height: int) -> list[str]:
        pre = (
            "udash_tv=1\ndashboard_keyboard_active=1\nwatch=1\n"
            + self._printf_lines("dash_main_sources", self.SOURCES_ITEMS)
            + self._printf_lines("dashboard_events", self.EVENT_ITEMS)
        )
        code = SET_RENDER_VARS + pre + "_denon_udash_render\n"
        r = _bash(code, env_extra={
            "DENON_DASHBOARD_WIDTH": str(width),
            "DENON_DASHBOARD_HEIGHT": str(height),
        })
        assert r.returncode == 0, f"bash error: {r.stderr}"
        return _strip_ansi(r.stdout).split("\n")

    def test_grid_reaches_footer_no_dead_band(self):
        # Rendered output should span the full viewport height, leaving no dead
        # band of empty rows above/below the footer.
        for width, height in [(140, 40), (200, 55), (320, 90), (280, 60)]:
            lines = self._render(width, height)
            # strip a single trailing empty line artifact, if any
            while lines and lines[-1] == "":
                lines.pop()
            assert len(lines) == height, (
                f"dead band at {width}x{height}: rendered {len(lines)} of {height} rows"
            )

    def test_no_line_overflows_terminal_width(self):
        for width, height in [(80, 24), (140, 40), (200, 55), (320, 90)]:
            lines = self._render(width, height)
            widest = max((_display_width(ln) for ln in lines), default=0)
            assert widest <= width, (
                f"overflow at {width}x{height}: widest line {widest} > {width}"
            )

    def test_sources_fills_when_slack_available(self):
        # With ample rows, the Sources panel shows every source (no "+N more").
        for width, height in [(200, 55), (320, 90), (280, 60)]:
            text = "\n".join(self._render(width, height))
            assert "10 HEOS Music" in text, f"sources truncated at {width}x{height}"
            assert "more" not in text, f"sources still sheds at {width}x{height}:\n{text}"

    def test_now_playing_is_full_width_band_when_wide(self):
        # Now Playing is the full-width top band; a long combined title is not
        # truncated (no ellipsis on the Now: line).
        long_title = "A Very Long Track Title That Should Not Be Truncated At All Here"
        pre = (
            "udash_tv=1\ndashboard_keyboard_active=1\nwatch=1\n"
            f"dash_now_title={long_title!r}\n"
            "dash_now_artist='Artist'\ndash_now_album='Album'\n"
        )
        code = SET_RENDER_VARS + pre + "_denon_udash_render\n"
        r = _bash(code, env_extra={
            "DENON_DASHBOARD_WIDTH": "280", "DENON_DASHBOARD_HEIGHT": "55",
        })
        assert r.returncode == 0, r.stderr
        text = _strip_ansi(r.stdout)
        assert long_title in text, "Now Playing title was truncated"
        # The Now Playing band leads the layout.
        assert text.index("Now Playing") < text.index("LivingRoom (Main)")

    def test_small_grid_still_sheds_without_overflow(self):
        # Preserve tier-shedding at small (large-font) grids: no overflow, no
        # mid-field clipping of must-keep fields.
        lines = self._render(80, 24)
        assert len(lines) <= 25
        text = "\n".join(lines)
        assert "Recent Events" in text
        assert re.search(r"Power: +On", text)
        widest = max((_display_width(ln) for ln in lines), default=0)
        assert widest <= 80
