import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from denon_dashboard_alt import (
    DashboardEventTracker,
    DashboardRenderer,
    DashboardSnapshot,
    NowPlayingSnapshot,
    SourceSnapshot,
    ZoneSnapshot,
    build_parser,
)


SCRIPT = Path(__file__).parent.parent / "denon.sh"


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
    args = build_parser().parse_args(["--watch", "--interval", "2", "--color", "never", "--ascii"])
    assert args.watch is True
    assert args.interval == 2
    assert args.color == "never"
    assert args.ascii is True


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
