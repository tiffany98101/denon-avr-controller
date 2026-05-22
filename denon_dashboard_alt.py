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
import re
import shutil
import socket
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
PLACEHOLDER = "-"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


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


def _bounded_unique(items: Sequence[str], limit: int = 8) -> tuple[str, ...]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        text = _clean(item)
        if not text or text in seen:
            continue
        seen.add(text)
        result.append(text)
        if len(result) >= limit:
            break
    return tuple(result)


def _xml_root(text: str) -> ET.Element | None:
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def _xml_root_with_warning(text: str, label: str, warnings: list[str]) -> ET.Element | None:
    if not _clean(text):
        return None
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        warnings.append(f"{label} XML parse failed")
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
    state = _find_text(root, "State") or _find_text(root, "PlayState") or _find_text(root, "PlaybackState")
    return NowPlayingSnapshot(
        title=_clean(title),
        artist=_clean(artist),
        album=_clean(album),
        state=_clean(state),
    )


class DashboardProvider:
    """Collects one normalized snapshot. It never renders."""

    def collect(self) -> DashboardSnapshot:
        raise NotImplementedError


class ProviderUnavailable(RuntimeError):
    """Raised when a provider cannot produce a useful snapshot."""


def snapshot_to_dict(snapshot: DashboardSnapshot) -> dict[str, Any]:
    zone2 = snapshot.zone2 or ZoneSnapshot()
    return {
        "provider": _clean(snapshot.provider),
        "receiver": _clean(snapshot.receiver),
        "ip": _clean(snapshot.ip),
        "main_power": _clean(snapshot.main.power),
        "main_source": _clean(snapshot.main.source),
        "main_source_index": _clean(snapshot.main.source_index),
        "main_volume": _clean(snapshot.main.volume),
        "main_mute": _clean(snapshot.main.mute),
        "zone2_power": _clean(zone2.power),
        "zone2_source": _clean(zone2.source),
        "zone2_source_index": _clean(zone2.source_index),
        "zone2_volume": _clean(zone2.volume),
        "zone2_mute": _clean(zone2.mute),
        "now_title": _clean(snapshot.now_playing.title),
        "now_artist": _clean(snapshot.now_playing.artist),
        "now_album": _clean(snapshot.now_playing.album),
        "playback_state": _clean(snapshot.now_playing.state),
        "now_service": _clean(snapshot.now_playing.service),
        "now_media_type": _clean(snapshot.now_playing.media_type),
        "source_count": len(snapshot.sources),
        "sources": [
            {
                "index": source.index,
                "name": source.name,
                "active": source.active,
            }
            for source in snapshot.sources
        ],
        "network": _clean(snapshot.network),
        "player": _clean(snapshot.player),
        "heos_status": _clean(snapshot.heos_status),
        "warnings": list(snapshot.warnings),
        "warning_count": len(snapshot.warnings),
        "errors": list(snapshot.errors),
        "error_count": len(snapshot.errors),
        "timestamp": snapshot.timestamp.isoformat(timespec="seconds"),
    }


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
            except (TimeoutError, socket.timeout) as exc:
                warnings.append(f"get_config type {type_id} timed out: {exc}")
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
                warnings = [*snapshot.warnings, f"now playing endpoint unavailable: {exc}"]
                snapshot = dataclasses.replace(snapshot, warnings=_bounded_unique(warnings))
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
        parse_warnings = list(warnings)
        identity_root = _xml_root_with_warning(xml_by_type.get(3, ""), "identity", parse_warnings)
        power_root = _xml_root_with_warning(xml_by_type.get(4, ""), "power", parse_warnings)
        source_root = _xml_root_with_warning(xml_by_type.get(7, ""), "sources", parse_warnings)
        volume_root = _xml_root_with_warning(xml_by_type.get(12, ""), "volume", parse_warnings)

        main_source_index = _active_source_index(source_root, "1")
        zone2_source_index = _active_source_index(source_root, "2")
        sources = _source_rows(source_root, "1")
        missing_expected = self._missing_expected_fields(
            power_root,
            source_root,
            volume_root,
            main_source_index,
        )
        parse_warnings.extend(missing_expected)

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
            warnings=_bounded_unique(parse_warnings),
            errors=_bounded_unique(errors),
        )

    def _missing_expected_fields(
        self,
        power_root: ET.Element | None,
        source_root: ET.Element | None,
        volume_root: ET.Element | None,
        main_source_index: str,
    ) -> list[str]:
        warnings: list[str] = []
        expected = (
            ("main power missing", _zone_text(power_root, "MainZone", "Power")),
            ("main volume missing", _zone_text(volume_root, "MainZone", "Volume")),
            ("main mute missing", _zone_text(volume_root, "MainZone", "Mute")),
        )
        for label, value in expected:
            if not _clean(value):
                warnings.append(label)
        if source_root is not None and not main_source_index:
            warnings.append("active main source missing")
        elif main_source_index and not _source_name(source_root, "1", main_source_index):
            warnings.append(f"active main source {main_source_index} missing from source list")
        return warnings


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
                    volume=_display(_raw_to_db(zone2_data.get("volumeRaw"))),
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


COMPARE_FIELDS: tuple[tuple[str, str], ...] = (
    ("provider", "Provider"),
    ("receiver", "Receiver"),
    ("main_power", "Main Power"),
    ("main_source", "Main Source"),
    ("main_volume", "Main Volume"),
    ("main_mute", "Main Mute"),
    ("zone2_power", "Zone 2 Power"),
    ("zone2_source", "Zone 2 Source"),
    ("zone2_volume", "Zone 2 Volume"),
    ("zone2_mute", "Zone 2 Mute"),
    ("now_title", "Now Title"),
    ("now_artist", "Now Artist"),
    ("playback_state", "Playback State"),
    ("source_count", "Source Count"),
    ("warning_count", "Warnings"),
)


def collect_provider_snapshot(provider: DashboardProvider, name: str) -> DashboardSnapshot:
    try:
        return provider.collect()
    except Exception as exc:
        return DashboardSnapshot(
            provider=name,
            errors=(f"{name} provider error: {exc}",),
            timestamp=datetime.now(),
        )


def compare_snapshots(direct: DashboardSnapshot, shell: DashboardSnapshot) -> list[dict[str, str]]:
    direct_dict = snapshot_to_dict(direct)
    shell_dict = snapshot_to_dict(shell)
    rows: list[dict[str, str]] = []
    for key, label in COMPARE_FIELDS:
        direct_value = direct_dict.get(key, "")
        shell_value = shell_dict.get(key, "")
        status = _comparison_status(direct_value, shell_value)
        if key == "provider" and direct.errors:
            status = "error"
        if key == "provider" and shell.errors:
            status = "error"
        rows.append({
            "field": label,
            "status": status,
            "direct": _comparison_value(direct_value),
            "shell": _comparison_value(shell_value),
        })
    for error in direct.errors:
        rows.append({"field": "Direct Error", "status": "error", "direct": error, "shell": ""})
    for error in shell.errors:
        rows.append({"field": "Shell Error", "status": "error", "direct": "", "shell": error})
    return rows


def _comparison_status(direct_value: Any, shell_value: Any) -> str:
    direct_missing = _is_missing_comparison_value(direct_value)
    shell_missing = _is_missing_comparison_value(shell_value)
    if direct_missing and shell_missing:
        return "same"
    if direct_missing:
        return "missing-direct"
    if shell_missing:
        return "missing-shell"
    if direct_value == shell_value:
        return "same"
    return "different"


def _is_missing_comparison_value(value: Any) -> bool:
    if isinstance(value, int):
        return False
    if isinstance(value, list):
        return len(value) == 0
    return not _clean(value)


def _comparison_value(value: Any) -> str:
    if isinstance(value, list):
        return f"{len(value)} items"
    if value is None:
        return "-"
    text = str(value)
    return text if text else "-"


def render_provider_comparison(direct: DashboardSnapshot, shell: DashboardSnapshot) -> str:
    rows = compare_snapshots(direct, shell)
    lines = [
        "dashboard-alt provider comparison",
        "",
        f"{'Field':<18} {'Status':<15} {'Direct':<28} Shell",
        f"{'-' * 18} {'-' * 15} {'-' * 28} {'-' * 28}",
    ]
    for row in rows:
        direct_value = _truncate(row["direct"], 28)
        shell_value = _truncate(row["shell"], 60)
        lines.append(f"{row['field']:<18} {row['status']:<15} {direct_value:<28} {shell_value}")
    direct_warnings = "; ".join(direct.warnings)
    shell_warnings = "; ".join(shell.warnings)
    if direct_warnings or shell_warnings:
        lines.extend(["", "Warnings"])
        if direct_warnings:
            lines.append(f"  direct: {direct_warnings}")
        if shell_warnings:
            lines.append(f"  shell:  {shell_warnings}")
    return "\n".join(lines)


def _truncate(text: str, width: int) -> str:
    text = text.replace("\n", " ")
    if len(text) <= width:
        return text
    return text[: max(0, width - 3)] + "..."


def run_provider_comparison(script: str | Path) -> int:
    direct = collect_provider_snapshot(DirectDashboardProvider(strict=False), "direct")
    shell = collect_provider_snapshot(ShellDashboardProvider(script), "shell")
    print(render_provider_comparison(direct, shell))
    return 0


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


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def visible_width(text: str) -> int:
    return len(strip_ansi(text))


def truncate_text(text: Any, width: int) -> str:
    if width <= 0:
        return ""
    plain = str(text).replace("\n", " ").replace("\r", " ")
    if visible_width(plain) <= width:
        return plain
    if width <= 1:
        return plain[:width]
    return plain[: max(0, width - 1)] + "…"


def pad_text(text: Any, width: int) -> str:
    fitted = truncate_text(text, width)
    pad = width - visible_width(fitted)
    return fitted + (" " * max(0, pad))


def display_value(value: Any) -> str:
    return _clean(value) or PLACEHOLDER


def render_status_kv(label: str, value: Any, width: int) -> str:
    label_text = f"{label}:"
    value_text = display_value(value)
    if width <= 0:
        return f"{label_text} {value_text}"
    if width <= len(label_text) + 1:
        return truncate_text(f"{label_text} {value_text}", width)
    value_width = width - len(label_text) - 1
    return f"{label_text} {pad_text(value_text, value_width)}"


@dataclass(frozen=True)
class Panel:
    title: str
    lines: tuple[str, ...]


def render_panel(
    title: str,
    lines: Sequence[str],
    width: int,
    height: int | None = None,
    unicode: bool = True,
) -> list[str]:
    width = max(8, width)
    content_width = max(0, width - 4)
    if unicode:
        tl, tr, bl, br, side, horiz = ("┌", "┐", "└", "┘", "│", "─")
    else:
        tl, tr, bl, br, side, horiz = ("+", "+", "+", "+", "|", "-")

    body = [str(line) for line in lines] or [PLACEHOLDER]
    if height is not None:
        height = max(3, height)
        body = body[: max(0, height - 3)]
    rendered = [f"{tl}{horiz * (width - 2)}{tr}"]
    rendered.append(f"{side} {pad_text(title, content_width)} {side}")
    for line in body:
        rendered.append(f"{side} {pad_text(line, content_width)} {side}")
    if height is not None:
        while len(rendered) < height - 1:
            rendered.append(f"{side} {' ' * content_width} {side}")
    rendered.append(f"{bl}{horiz * (width - 2)}{br}")
    return rendered


def render_two_column_row(
    left: Panel,
    right: Panel,
    width: int,
    height: int | None = None,
    unicode: bool = True,
) -> list[str]:
    gap = 2
    left_width = max(8, width // 2 - 1)
    right_width = max(8, width - left_width - gap)
    left_lines = render_panel(left.title, left.lines, left_width, height=height, unicode=unicode)
    right_lines = render_panel(right.title, right.lines, right_width, height=height, unicode=unicode)
    count = max(len(left_lines), len(right_lines))
    out: list[str] = []
    for index in range(count):
        left_line = left_lines[index] if index < len(left_lines) else " " * left_width
        right_line = right_lines[index] if index < len(right_lines) else " " * right_width
        out.append(f"{left_line}{' ' * gap}{right_line}")
    return out


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
        width = max(28, width)
        height = max(8, height)
        warnings = self._dedupe_lines((*snapshot.warnings, *snapshot.errors))
        event_lines = self._dedupe_lines(events)
        lines: list[str] = []
        lines.extend(self._header_lines(snapshot, width, len(warnings)))

        main_panel = Panel("Main Zone", tuple(self._zone_rows(snapshot.main)))
        zone2_panel = Panel("Zone 2", tuple(self._zone_rows(snapshot.zone2)))
        now_panel = Panel("Now Playing / Audio", tuple(self._now_rows(snapshot)))
        sources_panel = Panel("Sources", tuple(self._source_rows(snapshot)))
        events_panel = Panel("Recent Events", tuple(event_lines[:8]) or ("No state changes yet",))
        warning_lines = [f"{index + 1}. {warning}" for index, warning in enumerate(warnings[:6])]
        warnings_panel = Panel("Warnings", tuple(warning_lines))

        if width >= 100:
            lines.extend(render_two_column_row(main_panel, zone2_panel, width, unicode=self.unicode))
            lines.extend(render_panel(now_panel.title, now_panel.lines, width, unicode=self.unicode))
            lines.extend(render_two_column_row(sources_panel, events_panel, width, height=16, unicode=self.unicode))
            if warnings:
                lines.extend(render_panel(warnings_panel.title, warnings_panel.lines, width, height=min(8, len(warning_lines) + 3), unicode=self.unicode))
        elif width >= 70:
            lines.extend(render_two_column_row(main_panel, zone2_panel, width, unicode=self.unicode))
            lines.extend(render_panel(now_panel.title, now_panel.lines, width, unicode=self.unicode))
            lines.extend(render_panel(sources_panel.title, sources_panel.lines, width, height=8, unicode=self.unicode))
            if warnings:
                lines.extend(render_panel(warnings_panel.title, warnings_panel.lines, width, height=min(8, len(warning_lines) + 3), unicode=self.unicode))
            lines.extend(render_panel(events_panel.title, events_panel.lines, width, height=7, unicode=self.unicode))
        else:
            compact_panels = [main_panel, zone2_panel, now_panel, sources_panel]
            if warnings:
                compact_panels.append(warnings_panel)
            compact_panels.append(events_panel)
            for panel in compact_panels:
                panel_height = 8 if panel.title == "Sources" else None
                lines.extend(render_panel(panel.title, panel.lines, width, height=panel_height, unicode=self.unicode))

        return "\n".join(lines[:height])

    def _header_lines(self, snapshot: DashboardSnapshot, width: int, warning_count: int) -> list[str]:
        provider = display_value(snapshot.provider)
        receiver = display_value(snapshot.receiver)
        ip = display_value(snapshot.ip)
        summary = " / ".join((
            display_value(snapshot.main.power),
            display_value(snapshot.main.source),
            display_value(snapshot.main.volume),
        ))
        left = f"{receiver} @ {ip}"
        right = f"{provider} | {snapshot.timestamp.strftime('%H:%M:%S')}"
        if warning_count:
            right = f"{right} | {warning_count} warning{'s' if warning_count != 1 else ''}"
        if width >= 72:
            gap = max(1, width - visible_width(left) - visible_width(right))
            first = f"{left}{' ' * gap}{right}"
        else:
            first = f"{left} | {right}"
        return [
            self._color(pad_text(first, width), "1;36"),
            pad_text(summary, width),
        ]

    def _zone_rows(self, zone: ZoneSnapshot | None) -> list[str]:
        if zone is None:
            return ["No Zone 2 data available"]
        return [
            render_status_kv("Power", zone.power, 0),
            render_status_kv("Source", f"{display_value(zone.source)}{self._index_suffix(zone.source_index)}", 0),
            render_status_kv("Volume", zone.volume, 0),
            render_status_kv("Mute", zone.mute, 0),
        ]

    def _now_rows(self, snapshot: DashboardSnapshot) -> list[str]:
        now = snapshot.now_playing
        return [
            render_status_kv("Title", now.title or "No metadata for current source", 0),
            render_status_kv("Artist", now.artist, 0),
            render_status_kv("Album", now.album, 0),
            render_status_kv("State", now.state, 0),
            render_status_kv("Type", now.media_type, 0),
        ]

    def _source_rows(self, snapshot: DashboardSnapshot) -> list[str]:
        if not snapshot.sources:
            return ["No sources available"]
        rows = []
        for source in snapshot.sources[:12]:
            marker = "*" if source.active else " "
            rows.append(f"{marker} {source.index:>2}  {display_value(source.name)}")
        if len(snapshot.sources) > 12:
            rows.append(f"... {len(snapshot.sources) - 12} more")
        return rows

    def _index_suffix(self, source_index: str | None) -> str:
        text = _clean(source_index)
        return f" ({text})" if text else ""

    def _dedupe_lines(self, lines: Sequence[str]) -> tuple[str, ...]:
        return _bounded_unique([line for line in lines if _clean(line)], limit=12)

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
    parser = argparse.ArgumentParser(
        prog="denon dashboard-alt",
        description=(
            "Experimental Python dashboard preview. The existing 'denon dashboard' "
            "command remains the stable default dashboard."
        ),
        epilog=(
            "Examples:\n"
            "  denon dashboard-alt --provider auto\n"
            "  denon dashboard-alt --provider direct --json\n"
            "  denon dashboard-alt --compare-providers\n\n"
            "--json is one-shot only and cannot be combined with --watch or "
            "--compare-providers."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--watch", action="store_true", help="redraw until interrupted")
    parser.add_argument("--interval", type=float, default=5.0, help="watch refresh interval in seconds")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    parser.add_argument("--provider", choices=("auto", "direct", "shell"), default="auto")
    parser.add_argument("--compare-providers", action="store_true", help="compare direct and shell provider snapshots")
    parser.add_argument("--json", action="store_true", help="print one snapshot as JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--unicode", action="store_true", help="reserve for Unicode rendering")
    mode.add_argument("--ascii", action="store_true", help="force ASCII rendering")
    parser.add_argument("--script", default=str(Path(__file__).with_name("denon.sh")), help=argparse.SUPPRESS)
    return parser


def build_provider(mode: str, script: str | Path) -> DashboardProvider:
    shell_provider = ShellDashboardProvider(script)
    if mode == "shell":
        return shell_provider
    if mode == "direct":
        return DirectDashboardProvider(strict=False)
    return FallbackDashboardProvider(
        DirectDashboardProvider(strict=True),
        shell_provider,
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.json and args.watch:
        print("Error: --json cannot be combined with --watch", file=sys.stderr)
        return 2
    if args.json and args.compare_providers:
        print("Error: --json cannot be combined with --compare-providers", file=sys.stderr)
        return 2
    if args.compare_providers:
        return run_provider_comparison(args.script)
    if args.interval <= 0:
        print("Error: --interval must be greater than zero", file=sys.stderr)
        return 2
    provider = build_provider(args.provider, args.script)
    if args.json:
        snapshot = provider.collect()
        print(json.dumps(snapshot_to_dict(snapshot), ensure_ascii=False, sort_keys=True))
        return 1 if snapshot.errors else 0
    renderer = DashboardRenderer(color=args.color, unicode=args.unicode and not args.ascii)
    tracker = DashboardEventTracker()
    app = DashboardApp(provider, renderer, tracker, interval=args.interval)
    return app.run(watch=args.watch)


if __name__ == "__main__":
    raise SystemExit(main())
