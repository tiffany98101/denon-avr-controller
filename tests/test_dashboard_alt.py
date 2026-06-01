import json
import os
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import denon_dashboard_alt as dashboard_alt
from denon_dashboard_alt import (
    DirectDashboardProvider,
    DashboardCommandController,
    DashboardEventTracker,
    DashboardProvider,
    DashboardRenderer,
    DashboardSnapshot,
    FallbackDashboardProvider,
    NowPlayingSnapshot,
    ProviderUnavailable,
    SourceSnapshot,
    ZoneSnapshot,
    build_parser,
    pad_text,
    compare_snapshots,
    interactive_keyboard_enabled,
    parse_key_sequence,
    render_panel,
    render_provider_comparison,
    strip_ansi,
    snapshot_to_dict,
    truncate_text,
    visible_width,
)


SCRIPT = Path(__file__).parent.parent / "denon.sh"


IDENTITY_XML = "<listGlobals><FriendlyName>Denon AVR-X1600H</FriendlyName></listGlobals>"
POWER_XML = """
<listGlobals>
  <MainZone><Power>1</Power></MainZone>
  <Zone2><Power>3</Power></Zone2>
</listGlobals>
"""
SOURCE_XML = """
<SourceList>
  <Zone zone="1" index="13">
    <Source index="1"><Name>Phono</Name></Source>
    <Source index="6"><Name>TV Audio</Name></Source>
    <Source index="13"><Name>HEOS Music</Name></Source>
  </Zone>
  <Zone zone="2" index="1">
    <Source index="1"><Name>Phono</Name></Source>
    <Source index="13"><Name>HEOS Music</Name></Source>
  </Zone>
</SourceList>
"""
VOLUME_XML = """
<listGlobals>
  <MainZone><Volume>450</Volume><Mute>2</Mute></MainZone>
  <Zone2><Volume>650</Volume><Mute>1</Mute></Zone2>
</listGlobals>
"""
NOW_XML = """
<item>
  <Song>Song One</Song>
  <Artist>Artist One</Artist>
  <Album>Album One</Album>
  <State>Playing</State>
</item>
"""


class FakeDirectProvider(DirectDashboardProvider):
    def __init__(self, responses: dict[int, str], now_xml: str = NOW_XML, ip: str = "192.0.2.10", strict: bool = True):
        super().__init__(timeout=0.01, strict=strict)
        self.responses = responses
        self.now_xml = now_xml
        self.fake_ip = ip

    def _resolve_ip(self) -> str:
        return self.fake_ip

    def _get_config(self, ip: str, type_id: int) -> str:
        if type_id not in self.responses:
            raise RuntimeError(f"type {type_id} missing")
        return self.responses[type_id]

    def _fetch_now_playing(self, ip: str) -> NowPlayingSnapshot:
        return self._parse_fake_now()

    def _parse_fake_now(self) -> NowPlayingSnapshot:
        from denon_dashboard_alt import _parse_now_playing_xml

        return _parse_now_playing_xml(self.now_xml)


class TimeoutDirectProvider(FakeDirectProvider):
    def _get_config(self, ip: str, type_id: int) -> str:
        if type_id == 12:
            raise TimeoutError("slow receiver")
        return super()._get_config(ip, type_id)


class RaisingProvider(DashboardProvider):
    def collect(self) -> DashboardSnapshot:
        raise ProviderUnavailable("no direct IP")


class StaticProvider(DashboardProvider):
    def collect(self) -> DashboardSnapshot:
        return DashboardSnapshot(
            receiver="Shell Receiver",
            ip="192.0.2.20",
            provider="shell",
            main=ZoneSnapshot(power="ON"),
        )


def complete_snapshot(**overrides):
    data = {
        "receiver": "Denon AVR-X1600H",
        "ip": "192.0.2.10",
        "main": ZoneSnapshot(
            power="ON",
            source="HEOS Music",
            source_index="13",
            volume="-35.0 dB",
            mute="No",
        ),
        "zone2": ZoneSnapshot(
            power="OFF",
            source="Phono",
            source_index="1",
            volume="raw 650",
            mute="No",
        ),
        "now_playing": NowPlayingSnapshot(
            title="Song One",
            artist="Artist One",
            album="Album One",
            state="Playing",
            media_type="song",
        ),
        "sources": (
            SourceSnapshot(index="1", name="Phono"),
            SourceSnapshot(index="6", name="TV Audio"),
            SourceSnapshot(index="13", name="HEOS Music", active=True),
        ),
        "timestamp": datetime(2026, 5, 21, 18, 30, 0),
    }
    data.update(overrides)
    return DashboardSnapshot(**data)


def test_renderer_handles_complete_snapshot():
    frame = DashboardRenderer(color="never").render(
        complete_snapshot(),
        width=100,
        height=40,
    )
    assert "Denon AVR-X1600H @ 192.0.2.10" in frame
    assert "Main Zone" in frame
    assert "Zone 2" in frame
    assert "Now Playing / Audio" in frame
    assert "Sources" in frame
    assert "* 13  HEOS Music" in frame
    assert "direct" not in frame


def test_visible_width_and_truncation_ignore_ansi():
    text = "\x1b[31mReceiverName\x1b[0m"
    assert strip_ansi(text) == "ReceiverName"
    assert visible_width(text) == len("ReceiverName")
    assert truncate_text("abcdef", 4) == "abc…"
    assert pad_text("abc", 5) == "abc  "


def test_unicode_panel_rendering_is_width_stable():
    panel = render_panel("Panel", ["alpha", "beta"], width=24, unicode=True)
    assert panel[0].startswith("┌")
    assert panel[-1].startswith("└")
    assert all(visible_width(line) == 24 for line in panel)


def test_ascii_panel_rendering_is_width_stable():
    panel = render_panel("Panel", ["alpha"], width=20, unicode=False)
    assert panel[0] == "+------------------+"
    assert panel[-1] == "+------------------+"
    assert all(visible_width(line) == 20 for line in panel)


def test_renderer_handles_direct_provider_snapshot():
    frame = DashboardRenderer(color="never").render(
        complete_snapshot(provider="direct"),
        width=100,
        height=40,
    )
    assert "direct | 18:30:00" in frame
    assert "Main Zone" in frame


def test_renderer_shows_control_target_only_when_interactive_controls_are_active():
    snapshot = complete_snapshot(provider="direct")
    interactive = DashboardRenderer(color="never").render(
        snapshot,
        width=100,
        height=40,
        key_help=True,
        control_target="Zone2",
    )
    non_interactive = DashboardRenderer(color="never").render(
        snapshot,
        width=100,
        height=40,
        control_target="Zone2",
    )

    assert "Control Target: Zone2" in interactive
    assert "1-4 quick select  z zone" in interactive
    assert "Control Target:" not in non_interactive


def test_direct_provider_parses_main_zone_xml():
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML, 12: VOLUME_XML})
    snapshot = provider.collect()
    assert snapshot.provider == "direct"
    assert snapshot.receiver == "Denon AVR-X1600H"
    assert snapshot.ip == "192.0.2.10"
    assert snapshot.main.power == "ON"
    assert snapshot.main.source == "HEOS Music"
    assert snapshot.main.source_index == "13"
    assert snapshot.main.volume == "-35.0 dB"
    assert snapshot.main.mute == "No"
    assert SourceSnapshot(index="13", name="HEOS Music", active=True) in snapshot.sources
    assert snapshot.now_playing.title == "Song One"
    assert snapshot.now_playing.state == "Playing"


def test_direct_provider_parses_zone2_xml():
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML, 12: VOLUME_XML})
    snapshot = provider.collect()
    assert snapshot.zone2 is not None
    assert snapshot.zone2.power == "OFF"
    assert snapshot.zone2.source == "Phono"
    assert snapshot.zone2.source_index == "1"
    assert snapshot.zone2.volume == "-15.0 dB"
    assert snapshot.zone2.mute == "Yes"


def test_direct_provider_handles_missing_xml_fields():
    provider = FakeDirectProvider(
        {
            3: "<listGlobals />",
            4: "<listGlobals><MainZone /></listGlobals>",
            7: "<SourceList><Zone zone=\"1\" /></SourceList>",
            12: "<listGlobals><MainZone /></listGlobals>",
        },
        now_xml="<item />",
    )
    snapshot = provider.collect()
    assert snapshot.receiver == "Denon AVR"
    assert snapshot.main.power == "Unknown"
    assert snapshot.main.source == "Unknown"
    assert snapshot.main.volume == "Unknown"
    assert snapshot.main.mute == "Unknown"
    assert snapshot.sources == ()
    assert "active main source missing" in snapshot.warnings
    assert "main power missing" in snapshot.warnings


def test_direct_provider_records_warnings_on_partial_fetch_failure():
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML})
    snapshot = provider.collect()
    assert snapshot.provider == "direct"
    assert any("get_config type 12 unavailable" in warning for warning in snapshot.warnings)
    assert snapshot.errors == ()


def test_direct_provider_distinguishes_timeout_warning():
    provider = TimeoutDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML})
    snapshot = provider.collect()
    assert any("get_config type 12 timed out" in warning for warning in snapshot.warnings)


def test_direct_provider_treats_missing_zone2_as_absent():
    source_xml = """
    <SourceList>
      <Zone zone="1" index="6">
        <Source index="6"><Name>TV Audio</Name></Source>
      </Zone>
    </SourceList>
    """
    provider = FakeDirectProvider({
        3: IDENTITY_XML,
        4: "<listGlobals><MainZone><Power>1</Power></MainZone></listGlobals>",
        7: source_xml,
        12: "<listGlobals><MainZone><Volume>450</Volume><Mute>2</Mute></MainZone></listGlobals>",
    })
    snapshot = provider.collect()
    assert snapshot.zone2 is None
    assert snapshot.main.source == "TV Audio"
    assert snapshot.warnings == ()


def test_direct_provider_malformed_xml_records_parse_warning():
    provider = FakeDirectProvider({
        3: IDENTITY_XML,
        4: "<listGlobals><MainZone><Power>1</Power></MainZone>",
        7: SOURCE_XML,
        12: VOLUME_XML,
    })
    snapshot = provider.collect()
    assert "power XML parse failed" in snapshot.warnings
    assert "main power missing" in snapshot.warnings
    assert snapshot.main.source == "HEOS Music"


def test_direct_provider_missing_active_source_warns_without_crashing():
    source_xml = """
    <SourceList>
      <Zone zone="1">
        <Source index="6"><Name>TV Audio</Name></Source>
      </Zone>
    </SourceList>
    """
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: source_xml, 12: VOLUME_XML})
    snapshot = provider.collect()
    assert snapshot.main.source == "Unknown"
    assert "active main source missing" in snapshot.warnings


def test_direct_provider_active_source_missing_from_list_warns():
    source_xml = """
    <SourceList>
      <Zone zone="1" index="13">
        <Source index="6"><Name>TV Audio</Name></Source>
      </Zone>
    </SourceList>
    """
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: source_xml, 12: VOLUME_XML})
    snapshot = provider.collect()
    assert snapshot.main.source == "Unknown"
    assert "active main source 13 missing from source list" in snapshot.warnings


def test_direct_provider_unknown_volume_and_mute_formats_do_not_crash():
    volume_xml = "<listGlobals><MainZone><Volume>loud</Volume><Mute>maybe</Mute></MainZone></listGlobals>"
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML, 12: volume_xml})
    snapshot = provider.collect()
    assert snapshot.main.volume == "Unknown"
    assert snapshot.main.mute == "Unknown"


def test_heos_now_playing_xml_with_missing_fields_is_absent():
    provider = FakeDirectProvider(
        {3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML, 12: VOLUME_XML},
        now_xml="<item><Song></Song></item>",
    )
    snapshot = provider.collect()
    assert snapshot.now_playing.title is None or snapshot.now_playing.title == ""
    assert snapshot.now_playing.artist is None or snapshot.now_playing.artist == ""


def test_direct_provider_direct_mode_no_ip_returns_error_snapshot():
    provider = FakeDirectProvider({}, ip="", strict=False)
    snapshot = provider.collect()
    assert snapshot.provider == "direct"
    assert any("cannot resolve receiver IP" in error for error in snapshot.errors)


def test_direct_provider_auto_mode_no_ip_raises_for_fallback():
    provider = FakeDirectProvider({}, ip="", strict=True)
    with pytest.raises(ProviderUnavailable):
        provider.collect()


def test_renderer_handles_missing_partial_snapshot():
    frame = DashboardRenderer(color="never").render(
        DashboardSnapshot(
            receiver="Denon AVR",
            ip="Unknown",
            warnings=("sources unavailable",),
            timestamp=datetime(2026, 5, 21, 18, 30, 0),
        ),
        width=72,
        height=30,
    )
    assert "Denon AVR @ -" in frame
    assert "No metadata for current source" in frame
    assert "No sources available" in frame
    assert "sources unavailable" in frame


def test_renderer_missing_fields_use_placeholder():
    frame = DashboardRenderer(color="never").render(
        DashboardSnapshot(provider="direct", timestamp=datetime(2026, 5, 21, 18, 30, 0)),
        width=80,
        height=30,
    )
    assert "Power: -" in frame
    assert "Source: -" in frame
    assert "Artist: -" in frame


@pytest.mark.parametrize(("width", "height"), [(24, 8), (36, 12), (120, 6)])
def test_renderer_width_height_overrides_do_not_traceback(width, height):
    frame = DashboardRenderer(color="never").render(
        complete_snapshot(),
        width=width,
        height=height,
    )
    assert isinstance(frame, str)
    assert "Main Zone" in frame or width < 32 or height < 12


def test_renderer_truncates_long_now_playing_values():
    snapshot = complete_snapshot(
        now_playing=NowPlayingSnapshot(
            title="A" * 120,
            artist="Artist " + ("B" * 120),
            album="Album",
            state="Playing",
        )
    )
    frame = DashboardRenderer(color="never").render(snapshot, width=80, height=40)
    assert "…" in frame
    assert "A" * 90 not in frame


def test_renderer_deduplicates_warnings_in_frame():
    snapshot = complete_snapshot(
        warnings=("same warning", "same warning", "other warning"),
        errors=("same warning",),
    )
    frame = DashboardRenderer(color="never").render(snapshot, width=100, height=60)
    assert frame.count("same warning") == 1
    assert "other warning" in frame
    assert "2 warnings" in frame


def test_renderer_handles_many_sources_and_many_warnings():
    sources = tuple(SourceSnapshot(index=str(i), name=f"Very Long Source Name {i}", active=i == 3) for i in range(1, 20))
    warnings = tuple(f"warning {i}" for i in range(1, 12))
    frame = DashboardRenderer(color="never").render(
        complete_snapshot(sources=sources, warnings=warnings),
        width=120,
        height=40,
    )
    assert "Sources" in frame
    assert "... 7 more" in frame
    assert "Warnings" in frame
    assert "warning 1" in frame
    assert "warning 7" not in frame


def test_renderer_handles_partial_direct_snapshot():
    snapshot = DashboardSnapshot(
        receiver="Denon AVR",
        ip="192.0.2.10",
        provider="direct",
        main=ZoneSnapshot(power="ON"),
        timestamp=datetime(2026, 5, 21, 18, 30, 0),
    )
    frame = DashboardRenderer(color="never").render(snapshot, width=72, height=24)
    assert "Denon AVR @ 192.0.2.10" in frame
    assert "Power: ON" in frame
    assert "Source: -" in frame


def test_event_tracker_does_not_spam_first_baseline():
    tracker = DashboardEventTracker()
    assert tracker.update(complete_snapshot()) == ()


def test_event_tracker_records_source_volume_and_now_playing_changes():
    tracker = DashboardEventTracker()
    tracker.update(complete_snapshot())
    changed = complete_snapshot(
        main=ZoneSnapshot(
            power="ON",
            source="TV Audio",
            source_index="6",
            volume="-34.0 dB",
            mute="No",
        ),
        now_playing=NowPlayingSnapshot(
            title="Song Two",
            artist="Artist One",
            album="Album One",
            state="Playing",
            media_type="song",
        ),
    )
    events = "\n".join(tracker.update(changed))
    assert "Source: HEOS Music -> TV Audio" in events
    assert "Main Volume: -35.0 dB -> -34.0 dB" in events
    assert "Now Playing: Song One - Artist One -> Song Two - Artist One" in events


def test_dashboard_alt_parser_accepts_expected_options():
    args = build_parser().parse_args([
        "--watch",
        "--interval",
        "2",
        "--color",
        "never",
        "--ascii",
        "--provider",
        "direct",
        "--compare-providers",
    ])
    assert args.watch is True
    assert args.interval == 2
    assert args.color == "never"
    assert args.ascii is True
    assert args.provider == "direct"
    assert args.compare_providers is True


@pytest.mark.parametrize(("sequence", "action"), [
    ("\x1b[A", "volume_up"),
    ("\x1b[B", "volume_down"),
    ("\x1b[C", "next"),
    ("\x1b[D", "previous"),
    (" ", "play_pause"),
    ("1", "quick_select_1"),
    ("2", "quick_select_2"),
    ("3", "quick_select_3"),
    ("4", "quick_select_4"),
    ("m", "mute_toggle"),
    ("z", "cycle_zone_target"),
    ("q", "quit"),
])
def test_parse_key_sequence_maps_dashboard_controls(sequence, action):
    assert parse_key_sequence(sequence) == action


def test_non_tty_mode_does_not_enable_interactive_keyboard_handling():
    class NonTty:
        def isatty(self):
            return False

    class Tty:
        def isatty(self):
            return True

    assert interactive_keyboard_enabled(True, NonTty()) is False
    assert interactive_keyboard_enabled(False, Tty()) is False
    assert interactive_keyboard_enabled(True, Tty()) is True


def test_dashboard_command_throttle_is_deterministic_without_sleep():
    calls = []
    now = [100.0]

    def fake_clock():
        return now[0]

    def fake_runner(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

    controller = DashboardCommandController(
        str(SCRIPT),
        throttle_seconds=0.2,
        clock=fake_clock,
        runner=fake_runner,
    )
    snapshot = complete_snapshot()

    assert controller.handle("volume_up", snapshot).events == ("Key: Volume Up",)
    assert controller.handle("volume_up", snapshot).event is None
    now[0] += 0.21
    assert controller.handle("volume_up", snapshot).events == ("Key: Volume Up",)
    assert calls == [
        [str(SCRIPT), "up"],
        [str(SCRIPT), "up"],
    ]


def test_dashboard_control_target_cycles_between_main_and_zone2():
    controller = DashboardCommandController(str(SCRIPT))

    first = controller.handle("cycle_zone_target", complete_snapshot())
    assert controller.control_target == "Zone2"
    assert first.events == ("Key: Control Target: Zone2",)

    controller._last_command_at = -float("inf")
    second = controller.handle("cycle_zone_target", complete_snapshot())
    assert controller.control_target == "Main"
    assert second.events == ("Key: Control Target: Main",)


def test_dashboard_volume_and_mute_dispatch_use_selected_zone_target():
    calls = []

    def fake_runner(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

    snapshot = complete_snapshot(zone2=ZoneSnapshot(power="ON", mute="No"))
    controller = DashboardCommandController(str(SCRIPT), runner=fake_runner, throttle_seconds=0)

    assert controller.handle("volume_up", snapshot).events == ("Key: Volume Up",)
    assert controller.handle("volume_down", snapshot).events == ("Key: Volume Down",)
    assert controller.handle("mute_toggle", snapshot).events == ("Key: Mute Toggle",)

    controller.handle("cycle_zone_target", snapshot)
    assert controller.handle("volume_up", snapshot).events == ("Key: Volume Up",)
    assert controller.handle("volume_down", snapshot).events == ("Key: Volume Down",)
    assert controller.handle("mute_toggle", snapshot).events == ("Key: Mute Toggle",)
    muted_snapshot = complete_snapshot(zone2=ZoneSnapshot(power="ON", mute="Yes"))
    assert controller.handle("mute_toggle", muted_snapshot).events == ("Key: Mute Toggle",)

    assert calls == [
        [str(SCRIPT), "up"],
        [str(SCRIPT), "down"],
        [str(SCRIPT), "toggle", "mute"],
        [str(SCRIPT), "zone2", "up"],
        [str(SCRIPT), "zone2", "down"],
        [str(SCRIPT), "zone2", "mute"],
        [str(SCRIPT), "zone2", "unmute"],
    ]


@pytest.mark.parametrize(("action", "expected_command", "expected_event"), [
    ("quick_select_1", [str(SCRIPT), "qs", "1"], "Key: Quick Select 1"),
    ("quick_select_2", [str(SCRIPT), "qs", "2"], "Key: Quick Select 2"),
    ("quick_select_3", [str(SCRIPT), "qs", "3"], "Key: Quick Select 3"),
    ("quick_select_4", [str(SCRIPT), "qs", "4"], "Key: Quick Select 4"),
])
def test_dashboard_quick_select_hotkeys_dispatch_existing_command_path(action, expected_command, expected_event):
    calls = []

    def fake_runner(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

    controller = DashboardCommandController(str(SCRIPT), runner=fake_runner)
    result = controller.handle(action, complete_snapshot())

    assert result.events == (expected_event,)
    assert calls == [expected_command]


@pytest.mark.parametrize(("action", "event"), [
    ("volume_up", "Key: Volume Up"),
    ("volume_down", "Key: Volume Down"),
    ("previous", "Key: Previous"),
    ("next", "Key: Next"),
    ("play_pause", "Key: Play/Pause"),
    ("mute_toggle", "Key: Mute Toggle"),
    ("quick_select_1", "Key: Quick Select 1"),
    ("quick_select_2", "Key: Quick Select 2"),
    ("quick_select_3", "Key: Quick Select 3"),
    ("quick_select_4", "Key: Quick Select 4"),
])
def test_dashboard_key_actions_report_recent_event_feedback(action, event):
    def fake_runner(command, **kwargs):
        return subprocess.CompletedProcess(command, 0, stdout="ok", stderr="")

    tracker = DashboardEventTracker()
    controller = DashboardCommandController(str(SCRIPT), runner=fake_runner)
    result = controller.handle(action, complete_snapshot())
    for message in result.events:
        tracker.record(message, timestamp=datetime(2026, 5, 21, 18, 30, 0))

    assert result.quit is False
    assert result.events == (event,)
    assert tracker.events == (f"18:30:00 {event}",)


def test_dashboard_zone_target_key_reports_recent_event_feedback():
    tracker = DashboardEventTracker()
    controller = DashboardCommandController(str(SCRIPT))
    result = controller.handle("cycle_zone_target", complete_snapshot())
    for message in result.events:
        tracker.record(message, timestamp=datetime(2026, 5, 21, 18, 30, 0))

    assert result.events == ("Key: Control Target: Zone2",)
    assert tracker.events == ("18:30:00 Key: Control Target: Zone2",)


def test_dashboard_quit_key_has_no_recent_event_feedback():
    controller = DashboardCommandController(str(SCRIPT))
    result = controller.handle("quit", complete_snapshot())

    assert result.quit is True
    assert result.events == ()
    assert result.event is None


def test_transport_command_failure_reports_recent_event_without_crashing():
    def fake_runner(command, **kwargs):
        return subprocess.CompletedProcess(command, 1, stdout="", stderr="unsupported")

    controller = DashboardCommandController(str(SCRIPT), runner=fake_runner)
    result = controller.handle("next", complete_snapshot())

    assert result.quit is False
    assert result.events == ("Key: Next", "Transport command unavailable: next")


def test_zone2_command_failure_keeps_key_feedback_and_warning():
    def fake_runner(command, **kwargs):
        return subprocess.CompletedProcess(command, 1, stdout="", stderr="unsupported")

    controller = DashboardCommandController(str(SCRIPT), runner=fake_runner, throttle_seconds=0)
    controller.handle("cycle_zone_target", complete_snapshot())
    result = controller.handle("volume_up", complete_snapshot())

    assert result.events == ("Key: Volume Up", "Zone2 command unavailable: volume up")


def test_dashboard_alt_help_is_discoverable_preview_text():
    help_text = build_parser().format_help()
    assert "Experimental Python dashboard preview" in help_text
    assert "denon dashboard-alt --provider auto" in help_text
    assert "denon dashboard-alt --provider direct --json" in help_text
    assert "denon dashboard-alt --compare-providers" in help_text
    assert "--json is one-shot only" in help_text
    assert "denon dashboard" in help_text
    assert "stable default dashboard" in help_text


def test_denon_help_mentions_dashboard_alt_preview():
    result = subprocess.run(
        [str(SCRIPT), "help"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0
    assert "denon dashboard-alt" in result.stdout
    assert "experimental Python dashboard preview" in result.stdout
    assert "denon dashboard remains the stable default" in result.stdout


def test_readme_dashboard_alt_examples_use_supported_options():
    readme = (Path(__file__).parent.parent / "README.md").read_text(encoding="utf-8")
    examples = []
    for line in readme.splitlines():
        line = line.strip()
        if "dashboard-alt" not in line or line.startswith("#"):
            continue
        if " denon dashboard-alt " in f" {line} ":
            examples.append(line)

    assert "denon dashboard-alt --provider auto" in examples
    assert "denon dashboard-alt --provider direct --json" in examples
    assert "denon dashboard-alt --compare-providers" in examples

    for example in examples:
        if "=" in example.split()[0]:
            parts = shlex.split(example)
            command_index = parts.index("denon")
            parts = parts[command_index:]
        else:
            parts = shlex.split(example)
        assert parts[:2] == ["denon", "dashboard-alt"]
        build_parser().parse_args(parts[2:])


@pytest.mark.parametrize("provider", ["auto", "direct", "shell"])
def test_dashboard_alt_parser_accepts_provider_modes(provider):
    args = build_parser().parse_args(["--provider", provider])
    assert args.provider == provider


def test_auto_provider_falls_back_to_shell_when_direct_unavailable():
    provider = FallbackDashboardProvider(RaisingProvider(), StaticProvider())
    snapshot = provider.collect()
    assert snapshot.provider == "shell-fallback"
    assert snapshot.receiver == "Shell Receiver"
    assert any("auto provider using shell fallback: no direct IP" in warning for warning in snapshot.warnings)


def test_snapshot_to_dict_is_plain_and_stable():
    snapshot = complete_snapshot(provider="direct")
    data = snapshot_to_dict(snapshot)
    assert data["provider"] == "direct"
    assert data["receiver"] == "Denon AVR-X1600H"
    assert data["main_power"] == "ON"
    assert data["zone2_volume"] == "raw 650"
    assert data["now_title"] == "Song One"
    assert data["source_count"] == 3
    assert data["timestamp"] == "2026-05-21T18:30:00"
    assert isinstance(data["sources"][0], dict)


def test_compare_snapshots_reports_same_fields():
    direct = complete_snapshot(provider="direct")
    shell = complete_snapshot(provider="shell")
    rows = compare_snapshots(direct, shell)
    status_by_field = {row["field"]: row["status"] for row in rows}
    assert status_by_field["Main Power"] == "same"
    assert status_by_field["Main Source"] == "same"
    assert status_by_field["Provider"] == "different"


def test_compare_snapshots_reports_different_fields():
    direct = complete_snapshot(provider="direct")
    shell = complete_snapshot(
        provider="shell",
        main=ZoneSnapshot(power="ON", source="TV Audio", source_index="6", volume="-34.0 dB", mute="No"),
    )
    rows = compare_snapshots(direct, shell)
    status_by_field = {row["field"]: row["status"] for row in rows}
    assert status_by_field["Main Source"] == "different"
    assert status_by_field["Main Volume"] == "different"


def test_compare_snapshots_reports_missing_direct_fields():
    direct = complete_snapshot(provider="direct", now_playing=NowPlayingSnapshot())
    shell = complete_snapshot(provider="shell")
    rows = compare_snapshots(direct, shell)
    status_by_field = {row["field"]: row["status"] for row in rows}
    assert status_by_field["Now Title"] == "missing-direct"
    assert status_by_field["Now Artist"] == "missing-direct"
    assert status_by_field["Playback State"] == "missing-direct"


def test_compare_snapshots_reports_provider_error_without_crashing():
    direct = DashboardSnapshot(provider="direct", errors=("direct failed",))
    shell = complete_snapshot(provider="shell")
    output = render_provider_comparison(direct, shell)
    assert "dashboard-alt provider comparison" in output
    assert "Direct Error" in output
    assert "direct failed" in output
    assert "error" in output


def test_provider_comparison_output_is_readable_and_stable():
    direct = complete_snapshot(provider="direct")
    shell = complete_snapshot(provider="shell")
    output = render_provider_comparison(direct, shell)
    assert output.splitlines()[0] == "dashboard-alt provider comparison"
    assert "Field              Status" in output
    assert "Main Power         same" in output
    assert "Provider           different" in output


def test_compare_providers_mode_uses_both_providers_without_network(monkeypatch, capsys):
    class DirectStaticProvider(DashboardProvider):
        def __init__(self, *args, **kwargs):
            pass

        def collect(self) -> DashboardSnapshot:
            return complete_snapshot(provider="direct")

    class ShellStaticProvider(DashboardProvider):
        def __init__(self, *args, **kwargs):
            pass

        def collect(self) -> DashboardSnapshot:
            return complete_snapshot(provider="shell")

    monkeypatch.setattr(dashboard_alt, "DirectDashboardProvider", DirectStaticProvider)
    monkeypatch.setattr(dashboard_alt, "ShellDashboardProvider", ShellStaticProvider)
    rc = dashboard_alt.main(["--compare-providers", "--script", str(SCRIPT)])
    output = capsys.readouterr().out
    assert rc == 0
    assert "dashboard-alt provider comparison" in output
    assert "Main Power         same" in output


def test_json_mode_outputs_stable_snapshot_without_network(monkeypatch, capsys):
    class DirectStaticProvider(DashboardProvider):
        def __init__(self, *args, **kwargs):
            pass

        def collect(self) -> DashboardSnapshot:
            return complete_snapshot(provider="direct")

    monkeypatch.setattr(dashboard_alt, "DirectDashboardProvider", DirectStaticProvider)
    rc = dashboard_alt.main(["--provider", "direct", "--json"])
    output = capsys.readouterr().out
    data = json.loads(output)
    assert rc == 0
    assert data["provider"] == "direct"
    assert data["receiver"] == "Denon AVR-X1600H"
    assert data["main_power"] == "ON"
    assert "timestamp" in data
    assert "Keys:" not in output
    assert "Key:" not in output
    assert "Control Target:" not in output
    assert "quick select" not in output.lower()


def test_json_rejects_watch(capsys):
    rc = dashboard_alt.main(["--json", "--watch"])
    captured = capsys.readouterr()
    assert rc == 2
    assert "--json cannot be combined with --watch" in captured.err


def test_json_rejects_compare_providers(capsys):
    rc = dashboard_alt.main(["--json", "--compare-providers"])
    captured = capsys.readouterr()
    assert rc == 2
    assert "--json cannot be combined with --compare-providers" in captured.err


def test_dashboard_alt_shell_dispatch_does_not_force_receiver_discovery(tmp_path):
    helper = tmp_path / "dashboard_alt_helper.py"
    helper.write_text(
        "import sys\n"
        "print('helper-args:' + ' '.join(sys.argv[1:]))\n"
    )
    env = os.environ.copy()
    env["DENON_DASHBOARD_ALT_HELPER"] = str(helper)
    env["DENON_CACHE_TTL_SECONDS"] = "0"
    env.pop("DENON_IP", None)
    result = subprocess.run(
        [str(SCRIPT), "dashboard-alt", "--watch", "--interval", "2", "--color", "never"],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
    )
    assert result.returncode == 0
    assert "helper-args:" in result.stdout
    assert "--script" in result.stdout
    assert "--watch --interval 2 --color never" in result.stdout
    assert "Could not find Denon receiver" not in result.stderr


def test_existing_version_command_still_works_after_dashboard_alt_dispatch():
    result = subprocess.run(
        [str(SCRIPT), "version"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0
    assert result.stdout.strip()
