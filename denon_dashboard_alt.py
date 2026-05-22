#!/usr/bin/env python3
"""Experimental Python dashboard for denon.sh.

This module intentionally keeps collection, event tracking, rendering, and the
watch loop separate. The first provider uses the existing denon.sh command
surface so the current shell dashboard can remain untouched.
"""

from __future__ import annotations

import argparse
import dataclasses
import http.client
import json
import os
import shutil
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
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
    provider: str = UNKNOWN
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
    if text in {"false", "0", "2", "no", "off"}:
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


def _power_name(value: Any) -> str:
    text = _clean(value)
    return {"1": "ON", "2": "STANDBY", "3": "OFF"}.get(text, _display(text))


def _raw_to_db(value: Any) -> str:
    text = _clean(value)
    if not text:
        return ""
    try:
        return f"{int(text) / 10 - 80:.1f} dB"
    except ValueError:
        return ""


def _xml_root(text: str) -> ET.Element | None:
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def _find_text(root: ET.Element | None, tag: str) -> str:
    if root is None:
        return ""
    for elem in root.iter():
        if elem.tag == tag and elem.text is not None:
            return elem.text.strip()
    return ""


def _zone(root: ET.Element | None, tag: str) -> ET.Element | None:
    if root is None:
        return None
    for elem in root.iter():
        if elem.tag == tag:
            return elem
    return None


def _zone_text(root: ET.Element | None, zone_tag: str, child_tag: str) -> str:
    zone = _zone(root, zone_tag)
    if zone is None:
        return ""
    child = zone.find(child_tag)
    return child.text.strip() if child is not None and child.text is not None else ""


def _active_source_index(root: ET.Element | None, zone: str) -> str:
    if root is None:
        return ""
    for elem in root.iter("Zone"):
        if elem.get("zone") == zone:
            return _clean(elem.get("index"))
    return ""


def _source_rows(root: ET.Element | None, zone: str) -> tuple[SourceSnapshot, ...]:
    if root is None:
        return ()
    rows: list[SourceSnapshot] = []
    active = _active_source_index(root, zone)
    for zone_elem in root.iter("Zone"):
        if zone_elem.get("zone") != zone:
            continue
        for source in zone_elem.iter("Source"):
            idx = _clean(source.get("index"))
            name = _find_text(source, "Name")
            if idx or name:
                rows.append(SourceSnapshot(index=idx, name=_display(name), active=idx == active))
    return tuple(rows)


def _source_name(root: ET.Element | None, zone: str, index: str) -> str:
    for source in _source_rows(root, zone):
        if source.index == index:
            return source.name
    return ""


def _parse_now_playing_xml(text: str) -> NowPlayingSnapshot:
    root = _xml_root(text)
    if root is None:
        return NowPlayingSnapshot()
    title = _find_text(root, "Song") or _find_text(root, "szLine1")
    artist = _find_text(root, "Artist") or _find_text(root, "szLine2")
    album = _find_text(root, "Album") or _find_text(root, "szLine3")
    return NowPlayingSnapshot(
        title=_clean(title),
        artist=_clean(artist),
        album=_clean(album),
    )


class DashboardProvider:
    """Collects one normalized snapshot. It never renders."""

    def collect(self) -> DashboardSnapshot:
        raise NotImplementedError


class ProviderUnavailable(RuntimeError):
    """Raised when a provider cannot produce a useful snapshot."""


class DirectDashboardProvider(DashboardProvider):
    """Collects dashboard data directly from receiver read-only endpoints."""

    GET_CONFIG_PORT = 10443

    def __init__(self, timeout: float = 2.0, strict: bool = True) -> None:
        self.timeout = timeout
        self.strict = strict
        self._ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self._ssl_context.check_hostname = False
        self._ssl_context.verify_mode = ssl.CERT_NONE

    def collect(self) -> DashboardSnapshot:
        warnings: list[str] = []
        errors: list[str] = []
        ip = self._resolve_ip()
        if not ip:
            message = "direct provider cannot resolve receiver IP; set DENON_IP or run denon discover"
            if self.strict:
                raise ProviderUnavailable(message)
            return DashboardSnapshot(
                provider="direct",
                errors=(message,),
                timestamp=datetime.now(),
            )

        xml_by_type: dict[int, str] = {}
        for type_id in (3, 4, 7, 12):
            try:
                xml_by_type[type_id] = self._get_config(ip, type_id)
            except Exception as exc:
                warnings.append(f"get_config type {type_id} unavailable: {exc}")

        required = (4, 7, 12)
        if not any(type_id in xml_by_type for type_id in required):
            message = "direct provider could not read receiver status endpoints"
            if self.strict:
                raise ProviderUnavailable(message)
            errors.append(message)

        snapshot = self._snapshot_from_xml(ip, xml_by_type, warnings, errors)
        if "heos" in _display(snapshot.main.source, "").lower():
            try:
                snapshot = dataclasses.replace(snapshot, now_playing=self._fetch_now_playing(ip))
            except Exception as exc:
                warnings = list(snapshot.warnings)
                warnings.append(f"now playing unavailable: {exc}")
                snapshot = dataclasses.replace(snapshot, warnings=tuple(warnings))
        return snapshot

    def _resolve_ip(self) -> str:
        for key in ("DENON_IP", "DENON_DEFAULT_IP"):
            value = os.environ.get(key, "").strip()
            if value:
                return value

        for path in self._config_paths():
            value = self._config_value(path, "DENON_IP") or self._config_value(path, "DENON_DEFAULT_IP")
            if value:
                return value

        cache_path = Path.home() / ".cache" / "denon_ip"
        if cache_path.is_file():
            return cache_path.read_text(encoding="utf-8").strip()
        return ""

    def _config_paths(self) -> tuple[Path, ...]:
        paths: list[Path] = []
        explicit = os.environ.get("DENON_CONFIG", "").strip()
        if explicit:
            paths.append(Path(explicit).expanduser())
        config_dir = Path.home() / ".config" / "denon"
        profile = os.environ.get("DENON_PROFILE", "").strip()
        if profile and "/" not in profile and not profile.startswith("."):
            paths.append(config_dir / "profiles" / profile)
        paths.append(config_dir / "config")
        return tuple(paths)

    def _config_value(self, path: Path, key: str) -> str:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return ""
        for line in lines:
            line = line.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            got_key, value = line.split("=", 1)
            if got_key.strip() == key:
                return value.strip()
        return ""

    def _get_config(self, ip: str, type_id: int) -> str:
        query = urllib.parse.urlencode({"type": str(type_id)})
        conn = http.client.HTTPSConnection(
            ip,
            self.GET_CONFIG_PORT,
            context=self._ssl_context,
            timeout=self.timeout,
        )
        try:
            conn.request("GET", f"/ajax/globals/get_config?{query}")
            response = conn.getresponse()
            body = response.read().decode("utf-8", "replace")
            if response.status >= 400:
                raise RuntimeError(f"HTTP {response.status}")
            if not body.strip():
                raise RuntimeError("empty response")
            return body
        finally:
            conn.close()

    def _fetch_now_playing(self, ip: str) -> NowPlayingSnapshot:
        urls = (
            f"http://{ip}/goform/formNetAudio_StatusXml.xml",
            f"http://{ip}:8080/goform/formNetAudio_StatusXml.xml",
        )
        last_error: Exception | None = None
        for url in urls:
            try:
                with urllib.request.urlopen(url, timeout=self.timeout) as response:
                    text = response.read().decode("utf-8", "replace")
                now = _parse_now_playing_xml(text)
                if now.title or now.artist or now.album:
                    return now
            except Exception as exc:
                last_error = exc
        if last_error is not None:
            raise last_error
        raise RuntimeError("no now-playing metadata")

    def _snapshot_from_xml(
        self,
        ip: str,
        xml_by_type: dict[int, str],
        warnings: Sequence[str],
        errors: Sequence[str],
    ) -> DashboardSnapshot:
        identity_root = _xml_root(xml_by_type.get(3, ""))
        power_root = _xml_root(xml_by_type.get(4, ""))
        source_root = _xml_root(xml_by_type.get(7, ""))
        volume_root = _xml_root(xml_by_type.get(12, ""))

        main_source_index = _active_source_index(source_root, "1")
        zone2_source_index = _active_source_index(source_root, "2")
        sources = _source_rows(source_root, "1")

        main = ZoneSnapshot(
            power=_power_name(_zone_text(power_root, "MainZone", "Power")),
            source=_display(_source_name(source_root, "1", main_source_index)),
            source_index=main_source_index,
            volume=_display(_raw_to_db(_zone_text(volume_root, "MainZone", "Volume"))),
            mute=_display_mute(_zone_text(volume_root, "MainZone", "Mute")),
        )

        zone2 = None
        if any((
            _zone(power_root, "Zone2") is not None,
            zone2_source_index,
            _zone(volume_root, "Zone2") is not None,
        )):
            zone2 = ZoneSnapshot(
                power=_power_name(_zone_text(power_root, "Zone2", "Power")),
                source=_display(_source_name(source_root, "2", zone2_source_index)),
                source_index=zone2_source_index,
                volume=_display(_raw_to_db(_zone_text(volume_root, "Zone2", "Volume"))),
                mute=_display_mute(_zone_text(volume_root, "Zone2", "Mute")),
            )

        return DashboardSnapshot(
            receiver=_display(_find_text(identity_root, "FriendlyName"), "Denon AVR"),
            ip=ip,
            provider="direct",
            main=main,
            zone2=zone2,
            sources=sources,
            timestamp=datetime.now(),
            warnings=tuple(warnings),
            errors=tuple(errors),
        )


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
            provider="shell",
            main=main,
            zone2=zone2,
            now_playing=now,
            sources=tuple(sources),
            timestamp=datetime.now(),
            warnings=tuple(warnings),
            errors=tuple(errors),
        )


class FallbackDashboardProvider(DashboardProvider):
    def __init__(self, primary: DashboardProvider, fallback: DashboardProvider) -> None:
        self.primary = primary
        self.fallback = fallback
        self._fallback_reason = ""

    def collect(self) -> DashboardSnapshot:
        if self._fallback_reason:
            snapshot = self.fallback.collect()
            return self._with_fallback_warning(snapshot, self._fallback_reason)
        try:
            return self.primary.collect()
        except ProviderUnavailable as exc:
            self._fallback_reason = str(exc)
        except Exception as exc:
            self._fallback_reason = f"direct provider failed: {exc}"
        snapshot = self.fallback.collect()
        return self._with_fallback_warning(snapshot, self._fallback_reason)

    def _with_fallback_warning(self, snapshot: DashboardSnapshot, reason: str) -> DashboardSnapshot:
        warnings = (f"auto provider using shell fallback: {reason}", *snapshot.warnings)
        return dataclasses.replace(snapshot, provider="shell-fallback", warnings=warnings)


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
        provider = _display(snapshot.provider, "provider unknown")
        subtitle = f"{snapshot.timestamp.strftime('Updated %H:%M:%S')} | {provider}"
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
    parser.add_argument("--provider", choices=("auto", "direct", "shell"), default="auto")
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
    shell_provider = ShellDashboardProvider(args.script)
    if args.provider == "shell":
        provider: DashboardProvider = shell_provider
    elif args.provider == "direct":
        provider = DirectDashboardProvider(strict=False)
    else:
        provider = FallbackDashboardProvider(
            DirectDashboardProvider(strict=True),
            shell_provider,
        )
    renderer = DashboardRenderer(color=args.color, unicode=args.unicode and not args.ascii)
    tracker = DashboardEventTracker()
    app = DashboardApp(provider, renderer, tracker, interval=args.interval)
    return app.run(watch=args.watch)


if __name__ == "__main__":
    raise SystemExit(main())
