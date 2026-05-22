#!/usr/bin/env python3
"""Experimental Python dashboard for denon.sh.

This module intentionally keeps collection, event tracking, rendering, and the
watch loop separate. The first provider uses the existing denon.sh command
surface so the current shell dashboard can remain untouched.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import shutil
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Sequence


UNKNOWN = "Unknown"


@dataclass(frozen=True)
class ZoneSnapshot:
    power: str | None = None
    source: str | None = None
    source_index: str | None = None
    volume: str | None = None
    mute: str | None = None


@dataclass(frozen=True)
class NowPlayingSnapshot:
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    state: str | None = None
    service: str | None = None
    media_type: str | None = None


@dataclass(frozen=True)
class SourceSnapshot:
    index: str
    name: str
    active: bool = False


@dataclass(frozen=True)
class DashboardSnapshot:
    receiver: str = UNKNOWN
    ip: str = UNKNOWN
    main: ZoneSnapshot = field(default_factory=ZoneSnapshot)
    zone2: ZoneSnapshot | None = None
    now_playing: NowPlayingSnapshot = field(default_factory=NowPlayingSnapshot)
    sources: tuple[SourceSnapshot, ...] = ()
    network: str | None = None
    player: str | None = None
    heos_status: str | None = None
    timestamp: datetime = field(default_factory=datetime.now)
    warnings: tuple[str, ...] = ()
    errors: tuple[str, ...] = ()


def _clean(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    if text.lower() in {"", "unknown", "null", "none", "n/a", "na", "-"}:
        return ""
    return text


def _display(value: Any, default: str = UNKNOWN) -> str:
    return _clean(value) or default


def _display_mute(value: Any) -> str:
    text = _clean(value).lower()
    if text in {"true", "1", "yes", "on"}:
        return "Yes"
    if text in {"false", "0", "no", "off"}:
        return "No"
    return UNKNOWN


def _display_volume(value: Any, raw_zone2: bool = False) -> str:
    text = _clean(value)
    if not text:
        return UNKNOWN
    if text.endswith(" dB"):
        return text
    if raw_zone2 and text.isdigit():
        return f"raw {text}"
    return f"{text} dB"


class DashboardProvider:
    """Collects one normalized snapshot. It never renders."""

    def collect(self) -> DashboardSnapshot:
        raise NotImplementedError


class ShellDashboardProvider(DashboardProvider):
    def __init__(self, script: str | Path, timeout: float = 4.0) -> None:
        self.script = str(script)
        self.timeout = timeout

    def _run(self, *args: str) -> tuple[int, str, str]:
        try:
            proc = subprocess.run(
                [self.script, *args],
                capture_output=True,
                text=True,
                timeout=self.timeout,
                env=os.environ.copy(),
            )
        except subprocess.TimeoutExpired:
            return 124, "", f"{' '.join(args)} timed out after {self.timeout:g}s"
        except OSError as exc:
            return 127, "", f"{' '.join(args)} failed: {exc}"
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()

    def collect(self) -> DashboardSnapshot:
        warnings: list[str] = []
        errors: list[str] = []
        receiver = UNKNOWN
        ip = UNKNOWN
        main = ZoneSnapshot()
        zone2: ZoneSnapshot | None = None
        sources: list[SourceSnapshot] = []
        now = NowPlayingSnapshot()

        rc, out, err = self._run("info", "--json")
        if rc == 0 and out:
            try:
                info = json.loads(out)
            except json.JSONDecodeError as exc:
                warnings.append(f"info JSON parse failed: {exc}")
                info = {}
            receiver = _display(info.get("receiver"))
            ip = _display(info.get("ip"))
            main_data = info.get("mainZone") or {}
            zone2_data = info.get("zone2") or {}
            main = ZoneSnapshot(
                power=_display(main_data.get("power")),
                source=_display(main_data.get("sourceName")),
                source_index=_clean(main_data.get("sourceIndex")),
                volume=_display_volume(main_data.get("volumeDb")),
                mute=_display_mute(main_data.get("muted")),
            )
            if any(_clean(zone2_data.get(k)) for k in ("power", "sourceName", "sourceIndex", "volumeRaw", "muted")):
                zone2 = ZoneSnapshot(
                    power=_display(zone2_data.get("power")),
                    source=_display(zone2_data.get("sourceName")),
                    source_index=_clean(zone2_data.get("sourceIndex")),
                    volume=_display_volume(zone2_data.get("volumeRaw"), raw_zone2=True),
                    mute=_display_mute(zone2_data.get("muted")),
                )
        else:
            errors.append(err or out or "info unavailable")

        rc, out, err = self._run("sources", "--json")
        if rc == 0 and out:
            try:
                for item in json.loads(out):
                    sources.append(
                        SourceSnapshot(
                            index=str(item.get("index", "")),
                            name=_display(item.get("displayName") or item.get("receiverName")),
                            active=bool(item.get("active")),
                        )
                    )
            except (TypeError, json.JSONDecodeError) as exc:
                warnings.append(f"sources JSON parse failed: {exc}")
        else:
            warnings.append(err or out or "sources unavailable")

        rc, out, err = self._run("track")
        if rc == 0 and out:
            fields = _parse_label_lines(out)
            now = dataclasses.replace(
                now,
                title=_clean(fields.get("Title")),
                artist=_clean(fields.get("Artist")),
                album=_clean(fields.get("Album")),
            )
        else:
            warnings.append(err or out or "now playing unavailable")

        if "heos" in _display(main.source, "").lower():
            rc, out, err = self._run("heos", "now")
            if rc == 0 and out:
                fields = _parse_label_lines(out)
                now = dataclasses.replace(
                    now,
                    state=_clean(fields.get("State")),
                    media_type=_clean(fields.get("Type")),
                    title=_clean(fields.get("Title")) or now.title,
                    artist=_clean(fields.get("Artist")) or now.artist,
                    album=_clean(fields.get("Album")) or now.album,
                    service=_clean(fields.get("Source ID")),
                )
            else:
                warnings.append(err or out or "HEOS status unavailable")

        return DashboardSnapshot(
            receiver=receiver,
            ip=ip,
            main=main,
            zone2=zone2,
            now_playing=now,
            sources=tuple(sources),
            timestamp=datetime.now(),
            warnings=tuple(warnings),
            errors=tuple(errors),
        )


def _parse_label_lines(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip()
    return result


class DashboardEventTracker:
    def __init__(self, limit: int = 20) -> None:
        self.limit = limit
        self._baseline: dict[str, str] | None = None
        self._events: deque[str] = deque(maxlen=limit)

    @property
    def events(self) -> tuple[str, ...]:
        return tuple(self._events)

    def update(self, snapshot: DashboardSnapshot) -> tuple[str, ...]:
        current = self._event_state(snapshot)
        if self._baseline is None:
            self._baseline = current
            return self.events

        now_stamp = snapshot.timestamp.strftime("%H:%M:%S")
        for key, label in (
            ("power", "Power"),
            ("source", "Source"),
            ("volume", "Main Volume"),
            ("mute", "Main Mute"),
            ("zone2_power", "Zone 2 Power"),
            ("zone2_source", "Zone 2 Source"),
            ("zone2_volume", "Zone 2 Volume"),
            ("zone2_mute", "Zone 2 Mute"),
            ("now_playing", "Now Playing"),
            ("playback", "HEOS Playback"),
        ):
            old = self._baseline.get(key, "")
            new = current.get(key, "")
            if old and new and old != new:
                self._events.appendleft(f"{now_stamp} {label}: {old} -> {new}")

        self._baseline = current
        return self.events

    def _event_state(self, snapshot: DashboardSnapshot) -> dict[str, str]:
        now = snapshot.now_playing
        title = _clean(now.title)
        artist = _clean(now.artist)
        station = _clean(now.service)
        if title and artist:
            now_text = f"{title} - {artist}"
        else:
            now_text = title or station
        zone2 = snapshot.zone2 or ZoneSnapshot()
        return {
            "power": _clean(snapshot.main.power),
            "source": _clean(snapshot.main.source),
            "volume": _clean(snapshot.main.volume),
            "mute": _clean(snapshot.main.mute),
            "zone2_power": _clean(zone2.power),
            "zone2_source": _clean(zone2.source),
            "zone2_volume": _clean(zone2.volume),
            "zone2_mute": _clean(zone2.mute),
            "now_playing": now_text,
            "playback": _clean(now.state),
        }


class DashboardRenderer:
    def __init__(self, color: str = "auto", unicode: bool = False) -> None:
        self.color = color
        self.unicode = unicode

    def render(
        self,
        snapshot: DashboardSnapshot,
        width: int,
        height: int,
        events: Sequence[str] = (),
    ) -> str:
        width = max(32, width)
        height = max(10, height)
        lines: list[str] = []
        title = f"{snapshot.receiver} @ {snapshot.ip}"
        subtitle = snapshot.timestamp.strftime("Updated %H:%M:%S")
        lines.append(self._header(title, subtitle, width))

        panel_width = width
        if width >= 96:
            left_w = width // 2 - 1
            right_w = width - left_w - 2
            lines.extend(self._two_columns(
                self._panel_lines("Main Zone", self._zone_rows(snapshot.main), left_w),
                self._panel_lines("Zone 2", self._zone_rows(snapshot.zone2), right_w),
                gap="  ",
            ))
        else:
            lines.extend(self._panel_lines("Main Zone", self._zone_rows(snapshot.main), panel_width))
            if snapshot.zone2 is not None:
                lines.extend(self._panel_lines("Zone 2", self._zone_rows(snapshot.zone2), panel_width))

        lines.extend(self._panel_lines("Now Playing / Audio", self._now_rows(snapshot), panel_width))
        lines.extend(self._panel_lines("Sources", self._source_rows(snapshot), panel_width))
        lines.extend(self._panel_lines("Recent Events / Warnings", self._warning_rows(snapshot, events), panel_width))

        return "\n".join(lines[:height])

    def _header(self, title: str, subtitle: str, width: int) -> str:
        text = f" {title} | {subtitle} "
        return self._color(self._fit(text, width), "1;36")

    def _zone_rows(self, zone: ZoneSnapshot | None) -> list[str]:
        if zone is None:
            return ["No Zone 2 data available"]
        rows = [
            f"Power:  {_display(zone.power)}",
            f"Source: {_display(zone.source)}{self._index_suffix(zone.source_index)}",
            f"Volume: {_display(zone.volume)}",
            f"Mute:   {_display(zone.mute)}",
        ]
        return rows

    def _now_rows(self, snapshot: DashboardSnapshot) -> list[str]:
        now = snapshot.now_playing
        return [
            f"Title:  {_display(now.title, 'No metadata for current source')}",
            f"Artist: {_display(now.artist)}",
            f"Album:  {_display(now.album)}",
            f"State:  {_display(now.state)}",
            f"Type:   {_display(now.media_type)}",
        ]

    def _source_rows(self, snapshot: DashboardSnapshot) -> list[str]:
        if not snapshot.sources:
            return ["No sources available"]
        rows = []
        for source in snapshot.sources[:12]:
            marker = "*" if source.active else " "
            rows.append(f"{marker} {source.index:>2}  {source.name}")
        if len(snapshot.sources) > 12:
            rows.append(f"... {len(snapshot.sources) - 12} more")
        return rows

    def _warning_rows(self, snapshot: DashboardSnapshot, events: Sequence[str]) -> list[str]:
        rows = list(events[:8])
        for warning in snapshot.warnings[:4]:
            rows.append(f"Warning: {warning}")
        for error in snapshot.errors[:4]:
            rows.append(f"Error: {error}")
        return rows or ["No state changes yet"]

    def _panel_lines(self, title: str, rows: Sequence[str], width: int) -> list[str]:
        if self.unicode:
            tl, tr, bl, br, side, horiz = ("┌", "┐", "└", "┘", "│", "─")
        else:
            tl, tr, bl, br, side, horiz = ("+", "+", "+", "+", "|", "-")
        line = horiz * max(0, width - 2)
        out = [f"{tl}{line}{tr}", self._fit(f"{side} {title}", width - 1) + side]
        for row in rows:
            out.append(self._fit(f"{side} {row}", width - 1) + side)
        out.append(f"{bl}{line}{br}")
        return out

    def _two_columns(self, left: Sequence[str], right: Sequence[str], gap: str) -> list[str]:
        count = max(len(left), len(right))
        left_w = len(left[0]) if left else 0
        right_w = len(right[0]) if right else 0
        rows = []
        for i in range(count):
            l = left[i] if i < len(left) else " " * left_w
            r = right[i] if i < len(right) else " " * right_w
            rows.append(f"{l}{gap}{r}")
        return rows

    def _index_suffix(self, source_index: str | None) -> str:
        text = _clean(source_index)
        return f" ({text})" if text else ""

    def _fit(self, text: str, width: int) -> str:
        text = text.replace("\n", " ")
        if len(text) > width:
            return text[: max(0, width - 3)] + ("..." if width >= 3 else "")
        return text + (" " * (width - len(text)))

    def _color(self, text: str, code: str) -> str:
        if self.color == "never":
            return text
        if self.color == "auto" and (not sys.stdout.isatty() or os.environ.get("NO_COLOR")):
            return text
        return f"\033[{code}m{text}\033[0m"


class DashboardApp:
    def __init__(
        self,
        provider: DashboardProvider,
        renderer: DashboardRenderer,
        tracker: DashboardEventTracker,
        interval: float = 5.0,
    ) -> None:
        self.provider = provider
        self.renderer = renderer
        self.tracker = tracker
        self.interval = interval

    def run(self, watch: bool = False, width: int | None = None, height: int | None = None) -> int:
        try:
            while True:
                snapshot = self.provider.collect()
                events = self.tracker.update(snapshot)
                frame = self.renderer.render(
                    snapshot,
                    width or terminal_width(),
                    height or terminal_height(),
                    events=events,
                )
                if watch:
                    sys.stdout.write("\033[H\033[J")
                sys.stdout.write(frame + "\n")
                sys.stdout.flush()
                if not watch:
                    return 1 if snapshot.errors else 0
                time.sleep(self.interval)
        except KeyboardInterrupt:
            if watch:
                sys.stdout.write("\n")
            return 0


def terminal_width() -> int:
    env = os.environ.get("DENON_DASHBOARD_WIDTH")
    if env and env.isdigit():
        return int(env)
    return shutil.get_terminal_size((100, 32)).columns


def terminal_height() -> int:
    env = os.environ.get("DENON_DASHBOARD_HEIGHT")
    if env and env.isdigit():
        return int(env)
    return shutil.get_terminal_size((100, 32)).lines


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="denon dashboard-alt")
    parser.add_argument("--watch", action="store_true", help="redraw until interrupted")
    parser.add_argument("--interval", type=float, default=5.0, help="watch refresh interval in seconds")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--unicode", action="store_true", help="reserve for Unicode rendering")
    mode.add_argument("--ascii", action="store_true", help="force ASCII rendering")
    parser.add_argument("--script", default=str(Path(__file__).with_name("denon.sh")), help=argparse.SUPPRESS)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.interval <= 0:
        print("Error: --interval must be greater than zero", file=sys.stderr)
        return 2
    provider = ShellDashboardProvider(args.script)
    renderer = DashboardRenderer(color=args.color, unicode=args.unicode and not args.ascii)
    tracker = DashboardEventTracker()
    app = DashboardApp(provider, renderer, tracker, interval=args.interval)
    return app.run(watch=args.watch)


if __name__ == "__main__":
    raise SystemExit(main())
