import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from denon_dashboard_alt import (
    DirectDashboardProvider,
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


def test_renderer_handles_direct_provider_snapshot():
    frame = DashboardRenderer(color="never").render(
        complete_snapshot(provider="direct"),
        width=100,
        height=40,
    )
    assert "Updated 18:30:00 | direct" in frame
    assert "Main Zone" in frame


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


def test_direct_provider_records_warnings_on_partial_fetch_failure():
    provider = FakeDirectProvider({3: IDENTITY_XML, 4: POWER_XML, 7: SOURCE_XML})
    snapshot = provider.collect()
    assert snapshot.provider == "direct"
    assert any("get_config type 12 unavailable" in warning for warning in snapshot.warnings)
    assert snapshot.errors == ()


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
    assert "Denon AVR @ Unknown" in frame
    assert "No metadata for current source" in frame
    assert "No sources available" in frame
    assert "Warning: sources unavailable" in frame


@pytest.mark.parametrize(("width", "height"), [(24, 8), (36, 12), (120, 6)])
def test_renderer_width_height_overrides_do_not_traceback(width, height):
    frame = DashboardRenderer(color="never").render(
        complete_snapshot(),
        width=width,
        height=height,
    )
    assert isinstance(frame, str)
    assert "Main Zone" in frame or width < 32 or height < 12


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
    ])
    assert args.watch is True
    assert args.interval == 2
    assert args.color == "never"
    assert args.ascii is True
    assert args.provider == "direct"


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
