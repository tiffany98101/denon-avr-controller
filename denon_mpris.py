#!/usr/bin/env python3
"""
denon_mpris.py — MPRIS2 D-Bus bridge for Denon AVR-X1600H.

Publishes org.mpris.MediaPlayer2.denon on the session bus so Plasma 6's
media-controller widget, lock-screen media keys, and KDE Connect relay
all work with the receiver automatically.

System deps (present on Fedora KDE by default):
    python3-pydbus  python3-gobject3

Environment:
    DENON_IP                  Receiver IP (or use 'denon discover' cache)
    DENON_DEFAULT_IP          Fallback IP if DENON_IP is unset
    DENON_MAX_VOLUME_DB       dB that maps to MPRIS Volume=1.0  (default 0)
    DENON_MPRIS_POLL_INTERVAL AVR HTTP poll interval in seconds (default 10)
    DENON_MPRIS_AUTO_SWITCH   Allow MPRIS transport control to wake/switch HEOS (default 0)
    DENON_HEOS_PID            Override HEOS player ID (skip auto-resolution)
    DENON_DEBUG               Set to 1 for verbose logging
"""
from __future__ import annotations

import http.client
import base64
import json
import logging
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any

try:
    import pydbus
    from pydbus.generic import signal as _dbus_signal
    from gi.repository import GLib
except ImportError:
    sys.exit(
        "Missing runtime deps — install: sudo dnf install python3-pydbus python3-gobject3"
    )

# ── Logging ───────────────────────────────────────────────────────────────────

log = logging.getLogger("denon-mpris")
_h = logging.StreamHandler(sys.stderr)
_h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
log.addHandler(_h)
log.setLevel(logging.DEBUG if os.getenv("DENON_DEBUG") == "1" else logging.INFO)

# ── Constants ─────────────────────────────────────────────────────────────────

BUS_NAME     = "org.mpris.MediaPlayer2.denon"
OBJ_PATH     = "/org/mpris/MediaPlayer2"
IFACE_MPRIS  = "org.mpris.MediaPlayer2"
IFACE_PLAYER = "org.mpris.MediaPlayer2.Player"
IFACE_PROPS  = "org.freedesktop.DBus.Properties"

AVR_PORT          = 10443
HEOS_PORT         = 1255
MIN_DB              = -80.0
HEOS_BACKOFF_BASE   = 2.0
HEOS_BACKOFF_MAX    = 60.0
VOL_SUPPRESS_SECS   = 2.5   # ignore stale polled volume for this long after a Set

_MAX_DB   = float(os.environ.get("DENON_MAX_VOLUME_DB") or "0")
_POLL_INT = float(os.environ.get("DENON_MPRIS_POLL_INTERVAL") or "10")
_MPRIS_AUTO_SWITCH = os.environ.get("DENON_MPRIS_AUTO_SWITCH", "0").strip().lower() in (
    "1", "true", "yes", "on", "enabled",
)

# ── Ground-truth state (mutated only on the GLib main thread) ─────────────────

@dataclass
class _State:
    avr_ok:   bool = False
    power:    bool = False
    source:   str  = ""
    vol_raw:  int  = 0
    mute:     bool = False
    avr_name: str  = "Denon AVR"

    heos_ok:    bool = False
    heos_pid:   str  = ""
    play_state: str  = "stop"   # play | pause | stop
    title:      str  = ""
    artist:     str  = ""
    album:      str  = ""
    art_url:    str  = ""
    media_type: str  = ""       # non-empty ⟹ HEOS has current content
    repeat:     str  = "off"    # off | on_all | on_one
    shuffle:    str  = "off"


_st = _State()

# Suppression windows — set by Volume.setter; read by _apply on main thread only.
# Prevents polled stale values from snapping back after an optimistic setter update.
_vol_suppress:  tuple[int, float]  | None = None
_mute_suppress: tuple[bool, float] | None = None

# ── AVR HTTP client (stdlib, self-signed cert) ────────────────────────────────

def _build_ssl_context() -> tuple[ssl.SSLContext, str]:
    pinned = os.environ.get("DENON_CURL_PINNEDPUBKEY", "")
    if "DENON_CURL_PINNEDPUBKEY" in os.environ and not pinned:
        raise RuntimeError("DENON_CURL_PINNEDPUBKEY is set but empty")
    cacert = os.environ.get("DENON_CURL_CACERT", "")
    if "DENON_CURL_CACERT" in os.environ and not cacert:
        raise RuntimeError("DENON_CURL_CACERT is set but empty")

    if os.environ.get("DENON_CURL_INSECURE") == "1" or (
        os.environ.get("DENON_CURL_INSECURE") != "0" and not cacert
    ):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    elif cacert:
        context = ssl.create_default_context(cafile=cacert)
    else:
        context = ssl.create_default_context()
    return context, pinned


def _peer_public_key_pin(sock: ssl.SSLSocket) -> str:
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
    except ImportError as exc:
        raise RuntimeError("DENON_CURL_PINNEDPUBKEY requires python3-cryptography") from exc

    cert = sock.getpeercert(binary_form=True)
    if not cert:
        raise RuntimeError("TLS peer certificate is unavailable")
    public_key = x509.load_der_x509_certificate(cert).public_key()
    spki = public_key.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    digest = hashes.Hash(hashes.SHA256())
    digest.update(spki)
    return "sha256//" + base64.b64encode(digest.finalize()).decode("ascii")


def _verify_pinned_public_key(sock: ssl.SSLSocket, pinned: str) -> None:
    if not pinned:
        return
    if not pinned.startswith("sha256//"):
        raise RuntimeError("DENON_CURL_PINNEDPUBKEY must use sha256// format")
    actual = _peer_public_key_pin(sock)
    if actual != pinned:
        raise RuntimeError("TLS pinned public key mismatch")


_SSL, _PINNED_PUBLIC_KEY = _build_ssl_context()


def _avr_get(ip: str, type_: int, timeout: float = 4.0) -> str:
    conn = http.client.HTTPSConnection(ip, AVR_PORT, context=_SSL, timeout=timeout)
    try:
        conn.connect()
        if conn.sock is not None:
            _verify_pinned_public_key(conn.sock, _PINNED_PUBLIC_KEY)
        conn.request("GET", f"/ajax/globals/get_config?type={type_}")
        return conn.getresponse().read().decode("utf-8", "replace")
    finally:
        conn.close()


def _avr_set(ip: str, type_: int, data: str, timeout: float = 4.0) -> None:
    qs   = urllib.parse.urlencode({"type": str(type_), "data": data})
    conn = http.client.HTTPSConnection(ip, AVR_PORT, context=_SSL, timeout=timeout)
    try:
        conn.connect()
        if conn.sock is not None:
            _verify_pinned_public_key(conn.sock, _PINNED_PUBLIC_KEY)
        conn.request("GET", f"/ajax/globals/set_config?{qs}")
        conn.getresponse().read()
    finally:
        conn.close()

# ── AVR reachability check ────────────────────────────────────────────────────

def _verify_avr(ip: str, timeout: float = 3.0) -> bool:
    try:
        return "Denon" in _avr_get(ip, 3, timeout=timeout)
    except Exception:
        return False


def _avahi_discover() -> str | None:
    _CACHE = os.path.expanduser("~/.cache/denon_ip")
    for svc in ("_heos-audio._tcp", "_airplay._tcp"):
        try:
            proc = subprocess.run(
                ["avahi-browse", "-rtp", svc],
                capture_output=True, text=True, timeout=5.0,
            )
        except FileNotFoundError:
            return None          # avahi-browse not installed
        except subprocess.TimeoutExpired:
            continue

        candidates: list[str] = []
        for line in proc.stdout.splitlines():
            if not line.startswith("="):
                continue
            parts = line.split(";", 9)
            if len(parts) < 9:
                continue
            proto, address = parts[2], parts[7]
            if proto != "IPv4" or not address:
                continue
            if svc == "_airplay._tcp":
                txt = parts[9] if len(parts) > 9 else ""
                if "manufacturer=Denon" not in txt:
                    continue
            candidates.append(address)

        if not candidates:
            continue

        if len(candidates) > 1:
            log.warning(
                "Multiple Denon receivers found via Avahi (%s): %s — using first; set DENON_IP to pin one",
                svc, candidates,
            )

        for ip in candidates:
            if _verify_avr(ip):
                cache_dir = os.path.dirname(_CACHE)
                if cache_dir:
                    os.makedirs(cache_dir, exist_ok=True)
                with open(_CACHE, "w") as f:
                    f.write(ip)
                log.info("AVR discovered via Avahi at %s", ip)
                return ip

    return None


# ── XML parsers (mirror bash script's sed/awk) ────────────────────────────────

def _tag(xml: str, name: str) -> str:
    m = re.search(rf"<{re.escape(name)}>([^<]*)</{re.escape(name)}>", xml)
    return m.group(1).strip() if m else ""


def _zone_tag(xml: str, zone: str, tag: str) -> str:
    """First occurrence of <tag> inside <zone>…</zone>."""
    zm = re.search(rf"<{re.escape(zone)}>(.*?)</{re.escape(zone)}>", xml, re.DOTALL)
    if not zm:
        return ""
    tm = re.search(rf"<{re.escape(tag)}>([^<]*)</{re.escape(tag)}>", zm.group(1))
    return tm.group(1).strip() if tm else ""


def _parse_power(xml: str) -> bool:
    return _zone_tag(xml, "MainZone", "Power") == "1"


def _parse_vol_mute(xml: str) -> tuple[int, bool]:
    raw  = _zone_tag(xml, "MainZone", "Volume")
    mute = _zone_tag(xml, "MainZone", "Mute").lower()
    # GET response: 1 or "on" = muted; 2 or "off" = not muted.
    return (int(raw) if raw.isdigit() else 0), mute in ("1", "on", "true")


def _parse_source(xml: str) -> str:
    """Display name of the active main-zone source from type-7 XML."""
    m = re.search(r'<Zone\s+zone="1"\s+index="(\d+)"', xml)
    if not m:
        return ""
    idx = m.group(1)
    zm  = re.search(r'<Zone\s+zone="1"[^>]*>(.*?)</Zone>', xml, re.DOTALL)
    if not zm:
        return ""
    sm  = re.search(
        rf'<Source\s+index="{re.escape(idx)}"[^>]*>.*?<Name>([^<]*)</Name>',
        zm.group(1), re.DOTALL,
    )
    return sm.group(1).strip() if sm else ""

# ── Volume math ───────────────────────────────────────────────────────────────

def _raw_to_db(raw: int) -> float:
    return raw / 10.0 - 80.0


def _db_to_raw(db: float) -> int:
    return round((db + 80.0) * 10.0)


def _db_to_mpris(db: float) -> float:
    span = _MAX_DB - MIN_DB
    return max(0.0, min(1.0, (db - MIN_DB) / span)) if span > 0 else 0.0


def _mpris_to_db(vol: float) -> float:
    return MIN_DB + vol * (_MAX_DB - MIN_DB)

# ── Derived MPRIS2 values ─────────────────────────────────────────────────────

def _is_heos(s: _State) -> bool:
    """True when the active source is a HEOS network source."""
    if s.media_type:                   # HEOS has content → primary signal
        return True
    return "heos" in s.source.lower() # source-name fallback


def _active_source_is_heos(s: _State) -> bool:
    """True when the AVR source itself is HEOS/network audio."""
    return "heos" in s.source.lower()


def _mpris_transport_allowed(action: str) -> bool:
    """Allow MPRIS-originated HEOS writes only when they cannot steal input."""
    if _active_source_is_heos(_st) or _MPRIS_AUTO_SWITCH:
        return True
    log.info(
        "Ignoring MPRIS %s while AVR source is %r; set DENON_MPRIS_AUTO_SWITCH=1 to restore automatic HEOS/source activation",
        action, _st.source or "unknown",
    )
    return False


def _can_control_heos(s: _State) -> bool:
    return bool(s.heos_pid) and (_active_source_is_heos(s) or _MPRIS_AUTO_SWITCH)


def _playback_status(s: _State) -> str:
    if not s.power or not (_active_source_is_heos(s) or _MPRIS_AUTO_SWITCH):
        return "Stopped"
    return {"play": "Playing", "pause": "Paused"}.get(s.play_state.lower(), "Stopped")


def _loop_status(s: _State) -> str:
    return {"on_all": "Playlist", "on_one": "Track"}.get(s.repeat, "None")


def _metadata(s: _State) -> dict[str, Any]:
    if _is_heos(s) and (s.title or s.artist):
        meta: dict[str, Any] = {
            "mpris:trackid": GLib.Variant("o", "/org/denon/mpris/track/1"),
            "xesam:title":   GLib.Variant("s", s.title or s.source),
        }
        if s.artist:
            meta["xesam:artist"] = GLib.Variant("as", [s.artist])
        if s.album:
            meta["xesam:album"] = GLib.Variant("s", s.album)
        if s.art_url:
            meta["mpris:artUrl"] = GLib.Variant("s", s.art_url)
        return meta
    return {
        "mpris:trackid": GLib.Variant("o", "/org/denon/mpris/track/0"),
        "xesam:title":   GLib.Variant("s", s.source or s.avr_name),
    }

# ── IP discovery ──────────────────────────────────────────────────────────────

def _find_ip() -> str:
    for key in ("DENON_IP", "DENON_DEFAULT_IP"):
        v = os.environ.get(key, "").strip()
        if v:
            return v
    cache = os.path.expanduser("~/.cache/denon_ip")
    if os.path.isfile(cache):
        v = open(cache).read().strip()
        if v and _verify_avr(v):
            log.info("Using cached AVR IP: %s", v)
            return v
        if v:
            log.info("Cached IP %s did not respond — trying Avahi", v)
    ip = _avahi_discover()
    if ip:
        return ip
    sys.exit(
        "No AVR IP found. Set DENON_IP, run 'denon discover', or install avahi-tools."
    )

def _effective_volume(s: _State) -> float:
    """MPRIS Volume as seen by clients: 0.0 when muted, real level otherwise."""
    return 0.0 if s.mute else _db_to_mpris(_raw_to_db(s.vol_raw))


# ── PropertiesChanged (called from GLib main thread only) ─────────────────────

_bus: pydbus.Bus | None = None


def _emit_changed(iface: str, props: dict[str, Any]) -> None:
    if not props or _bus is None:
        return
    try:
        _bus.con.emit_signal(
            None, OBJ_PATH, IFACE_PROPS, "PropertiesChanged",
            GLib.Variant("(sa{sv}as)", (iface, props, [])),
        )
    except Exception as exc:
        log.debug("PropertiesChanged: %s", exc)

# ── State apply (GLib.idle_add target → always on main thread) ────────────────

def _apply(delta: dict[str, Any]) -> bool:
    """Merge delta into _st; emit PropertiesChanged for any derived changes."""
    global _vol_suppress, _mute_suppress
    s = _st

    # Suppression: ignore stale polled values while the AVR is still catching up
    # after a user Set.  _vol_optimistic=True bypasses both windows (setter only).
    is_vol_optimistic = delta.pop("_vol_optimistic", False)
    if "vol_raw" in delta and _vol_suppress is not None and not is_vol_optimistic:
        exp_raw, set_time = _vol_suppress
        if time.monotonic() - set_time > VOL_SUPPRESS_SECS:
            _vol_suppress = None
        elif delta["vol_raw"] == exp_raw:
            _vol_suppress = None
        else:
            del delta["vol_raw"]          # stale poll — drop to avoid snap-back
    if "mute" in delta and _mute_suppress is not None and not is_vol_optimistic:
        exp_mute, set_time = _mute_suppress
        if time.monotonic() - set_time > VOL_SUPPRESS_SECS:
            _mute_suppress = None
        elif delta["mute"] == exp_mute:
            _mute_suppress = None
        else:
            del delta["mute"]             # stale poll — drop to avoid snap-back

    old_ps   = _playback_status(s)
    old_vol  = _effective_volume(s)
    old_loop = _loop_status(s)
    old_sh   = s.shuffle == "on"
    old_control = _can_control_heos(s)
    old_meta = (s.title, s.artist, s.album, s.art_url, s.source)

    for k, v in delta.items():
        if hasattr(s, k):
            setattr(s, k, v)

    player: dict[str, Any] = {}

    new_ps = _playback_status(s)
    if new_ps != old_ps:
        player["PlaybackStatus"] = GLib.Variant("s", new_ps)

    new_vol = _effective_volume(s)
    if abs(new_vol - old_vol) > 1e-9:
        player["Volume"] = GLib.Variant("d", new_vol)

    new_loop = _loop_status(s)
    if new_loop != old_loop:
        player["LoopStatus"] = GLib.Variant("s", new_loop)

    if (s.shuffle == "on") != old_sh:
        player["Shuffle"] = GLib.Variant("b", s.shuffle == "on")

    new_control = _can_control_heos(s)
    if new_control != old_control:
        for prop in ("CanPlay", "CanPause", "CanGoNext", "CanGoPrevious"):
            player[prop] = GLib.Variant("b", new_control)

    if (s.title, s.artist, s.album, s.art_url, s.source) != old_meta:
        player["Metadata"] = GLib.Variant("a{sv}", _metadata(s))

    _emit_changed(IFACE_PLAYER, player)
    return False  # remove from idle queue

# ── HEOS helpers ──────────────────────────────────────────────────────────────

def _msg_val(data: dict[str, Any], key: str) -> str:
    msg = data.get("heos", {}).get("message", "")
    for part in str(msg).split("&"):
        if "=" in part:
            k, v = part.split("=", 1)
            if k.strip() == key:
                return v.strip()
    return ""


def _heos_one(ip: str, path: str, timeout: float = 4.0) -> dict[str, Any]:
    """Open a fresh HEOS socket, send one command, return the response."""
    with socket.create_connection((ip, HEOS_PORT), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(f"heos://{path}\r\n".encode())
        buf = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            for line in buf.split(b"\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    # Skip any interleaved event notifications
                    if not d.get("heos", {}).get("command", "").startswith("event/"):
                        return d
                except json.JSONDecodeError:
                    pass
    raise RuntimeError(f"no HEOS response for {path}")


def _heos_fire(ip: str, path: str) -> None:
    """Send a HEOS control command on a background thread (non-blocking)."""
    def _go() -> None:
        try:
            _heos_one(ip, path)
        except Exception as exc:
            log.debug("HEOS %s: %s", path.split("?")[0], exc)
    threading.Thread(target=_go, daemon=True, name="heos-cmd").start()

# ── HEOS persistent client ────────────────────────────────────────────────────

class _HEOSClient:
    """
    Maintains a persistent HEOS TCP connection with automatic reconnect and
    exponential backoff.  Posts state updates to the GLib main loop via
    GLib.idle_add so _apply always runs on the main thread.
    """

    def __init__(self, ip: str) -> None:
        self._ip    = ip
        self._pid   = os.environ.get("DENON_HEOS_PID", "").strip()
        self._sock: socket.socket | None = None
        self._wlock = threading.Lock()   # serialises socket writes
        self._stop  = threading.Event()
        self._thread = threading.Thread(
            target=self._run, daemon=True, name="heos-reader",
        )

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._wlock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass

    # ── internals ─────────────────────────────────────────────────────────────

    def _run(self) -> None:
        backoff = HEOS_BACKOFF_BASE
        while not self._stop.is_set():
            try:
                self._connect()
                backoff = HEOS_BACKOFF_BASE
                self._read_loop()
            except Exception as exc:
                log.info("HEOS disconnected (%s) — retry in %.0fs", exc, backoff)
                GLib.idle_add(_apply, {
                    "heos_ok": False, "media_type": "", "play_state": "stop",
                })
            if not self._stop.is_set():
                self._stop.wait(backoff)
                backoff = min(backoff * 2, HEOS_BACKOFF_MAX)

    def _rr(self, sock: socket.socket, path: str, timeout: float = 5.0) -> dict[str, Any]:
        """Synchronous send-receive used during setup before the read loop starts."""
        sock.sendall(f"heos://{path}\r\n".encode())
        buf = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                raise RuntimeError("connection closed during setup")
            buf += chunk
            for line in buf.split(b"\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    if not d.get("heos", {}).get("command", "").startswith("event/"):
                        return d
                except json.JSONDecodeError:
                    pass
        raise RuntimeError(f"no response for heos://{path}")

    def _connect(self) -> None:
        sock = socket.create_connection((self._ip, HEOS_PORT), timeout=5.0)
        sock.settimeout(5.0)

        if not self._pid:
            resp    = self._rr(sock, "player/get_players")
            players = resp.get("payload") or []
            if not players:
                sock.close()
                raise RuntimeError("no HEOS players found")
            self._pid = str(players[0]["pid"])
            log.debug("HEOS PID resolved: %s", self._pid)

        self._rr(sock, "system/register_for_change_events?enable=on")

        pid_q   = urllib.parse.quote(self._pid)
        st      = self._rr(sock, f"player/get_play_state?pid={pid_q}")
        np      = self._rr(sock, f"player/get_now_playing_media?pid={pid_q}")
        pm      = self._rr(sock, f"player/get_play_mode?pid={pid_q}")
        payload = np.get("payload") or {}

        with self._wlock:
            if self._sock:
                try:
                    self._sock.close()
                except OSError:
                    pass
            self._sock = sock

        GLib.idle_add(_apply, {
            "heos_ok":    True,
            "heos_pid":   self._pid,
            "play_state": _msg_val(st, "state") or "stop",
            "title":      payload.get("song") or payload.get("station") or payload.get("name") or "",
            "artist":     payload.get("artist") or "",
            "album":      payload.get("album") or "",
            "art_url":    payload.get("image_url") or "",
            "media_type": payload.get("type") or "",
            "repeat":     _msg_val(pm, "repeat") or "off",
            "shuffle":    _msg_val(pm, "shuffle") or "off",
        })
        log.info("HEOS connected (pid=%s)", self._pid)

    def _read_loop(self) -> None:
        buf = b""
        while not self._stop.is_set():
            with self._wlock:
                sock = self._sock
            if sock is None:
                break
            sock.settimeout(30.0)
            try:
                chunk = sock.recv(65536)
                if not chunk:
                    raise RuntimeError("HEOS socket EOF")
                buf += chunk
            except socket.timeout:
                # Keepalive heartbeat
                with self._wlock:
                    if self._sock:
                        try:
                            self._sock.sendall(b"heos://system/heart_beat\r\n")
                        except OSError as exc:
                            raise RuntimeError("heartbeat failed") from exc
                continue

            lines = buf.split(b"\n")
            buf   = lines[-1]           # last segment may be incomplete
            for raw_line in lines[:-1]:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    self._handle(json.loads(raw_line))
                except json.JSONDecodeError:
                    pass

    def _handle(self, data: dict[str, Any]) -> None:
        cmd = data.get("heos", {}).get("command", "")

        if cmd == "event/player_state_changed":
            GLib.idle_add(_apply, {"play_state": _msg_val(data, "state")})

        elif cmd == "event/player_now_playing_changed":
            # Re-fetch on a separate thread so the read loop is not blocked.
            ip    = self._ip
            pid_q = urllib.parse.quote(self._pid)
            path  = f"player/get_now_playing_media?pid={pid_q}"

            def _fetch() -> None:
                try:
                    np      = _heos_one(ip, path)
                    payload = np.get("payload") or {}
                    GLib.idle_add(_apply, {
                        "title":      payload.get("song") or payload.get("station") or payload.get("name") or "",
                        "artist":     payload.get("artist") or "",
                        "album":      payload.get("album") or "",
                        "art_url":    payload.get("image_url") or "",
                        "media_type": payload.get("type") or "",
                    })
                except Exception as exc:
                    log.debug("now-playing re-poll: %s", exc)

            threading.Thread(target=_fetch, daemon=True, name="heos-nowplaying").start()

        elif cmd == "event/repeat_mode_changed":
            GLib.idle_add(_apply, {"repeat": _msg_val(data, "repeat")})

        elif cmd == "event/shuffle_mode_changed":
            GLib.idle_add(_apply, {"shuffle": _msg_val(data, "shuffle")})

# ── AVR HTTP poller (dedicated worker thread — AVR can hang for seconds) ──────

def _avr_poll(ip: str, stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            id_xml  = _avr_get(ip, 3)
            pwr_xml = _avr_get(ip, 4)
            src_xml = _avr_get(ip, 7)
            vol_xml = _avr_get(ip, 12)
            raw_v, is_muted = _parse_vol_mute(vol_xml)
            GLib.idle_add(_apply, {
                "avr_ok":   True,
                "avr_name": _tag(id_xml, "FriendlyName") or "Denon AVR",
                "power":    _parse_power(pwr_xml),
                "source":   _parse_source(src_xml),
                "vol_raw":  raw_v,
                "mute":     is_muted,
            })
        except Exception as exc:
            log.debug("AVR poll: %s", exc)
            GLib.idle_add(_apply, {"avr_ok": False})
        stop.wait(_POLL_INT)

# ── pydbus MPRIS2 object ──────────────────────────────────────────────────────

class DenonBridge:
    """
    <node>
      <interface name="org.mpris.MediaPlayer2">
        <method name="Raise"/>
        <method name="Quit"/>
        <property name="CanQuit"             type="b"    access="read"/>
        <property name="CanRaise"            type="b"    access="read"/>
        <property name="HasTrackList"        type="b"    access="read"/>
        <property name="Identity"            type="s"    access="read"/>
        <property name="DesktopEntry"        type="s"    access="read"/>
        <property name="SupportedUriSchemes" type="as"   access="read"/>
        <property name="SupportedMimeTypes"  type="as"   access="read"/>
      </interface>
      <interface name="org.mpris.MediaPlayer2.Player">
        <method name="Next"/>
        <method name="Previous"/>
        <method name="Pause"/>
        <method name="PlayPause"/>
        <method name="Stop"/>
        <method name="Play"/>
        <method name="Seek">
          <arg direction="in" type="x" name="Offset"/>
        </method>
        <method name="SetPosition">
          <arg direction="in" type="o" name="TrackId"/>
          <arg direction="in" type="x" name="Position"/>
        </method>
        <method name="OpenUri">
          <arg direction="in" type="s" name="Uri"/>
        </method>
        <signal name="Seeked">
          <arg type="x" name="Position"/>
        </signal>
        <property name="PlaybackStatus" type="s"     access="read"/>
        <property name="LoopStatus"     type="s"     access="readwrite"/>
        <property name="Rate"           type="d"     access="readwrite"/>
        <property name="Shuffle"        type="b"     access="readwrite"/>
        <property name="Metadata"       type="a{sv}" access="read"/>
        <property name="Volume"         type="d"     access="readwrite"/>
        <property name="Position"       type="x"     access="read"/>
        <property name="MinimumRate"    type="d"     access="read"/>
        <property name="MaximumRate"    type="d"     access="read"/>
        <property name="CanGoNext"      type="b"     access="read"/>
        <property name="CanGoPrevious"  type="b"     access="read"/>
        <property name="CanPlay"        type="b"     access="read"/>
        <property name="CanPause"       type="b"     access="read"/>
        <property name="CanSeek"        type="b"     access="read"/>
        <property name="CanControl"     type="b"     access="read"/>
      </interface>
    </node>
    """

    Seeked = _dbus_signal()  # required by pydbus even though CanSeek=false

    def __init__(self, ip: str, loop: GLib.MainLoop) -> None:
        self._ip   = ip
        self._loop = loop

    # ── org.mpris.MediaPlayer2 ────────────────────────────────────────────────

    def Raise(self) -> None:
        pass  # headless service; no window to raise

    def Quit(self) -> None:
        self._loop.quit()

    @property
    def CanQuit(self) -> bool:
        return False

    @property
    def CanRaise(self) -> bool:
        return False

    @property
    def HasTrackList(self) -> bool:
        return False

    @property
    def Identity(self) -> str:
        return _st.avr_name

    @property
    def DesktopEntry(self) -> str:
        return "denon-mpris"

    @property
    def SupportedUriSchemes(self) -> list[str]:
        return []

    @property
    def SupportedMimeTypes(self) -> list[str]:
        return []

    # ── org.mpris.MediaPlayer2.Player — properties ────────────────────────────

    @property
    def PlaybackStatus(self) -> str:
        return _playback_status(_st)

    @property
    def LoopStatus(self) -> str:
        return _loop_status(_st)

    @LoopStatus.setter
    def LoopStatus(self, value: str) -> None:
        repeat_map = {"None": "off", "Track": "on_one", "Playlist": "on_all"}
        repeat = repeat_map.get(value)
        if repeat is None or not _st.heos_pid or not _mpris_transport_allowed("LoopStatus"):
            return
        pid_q = urllib.parse.quote(_st.heos_pid)
        _heos_fire(
            self._ip,
            f"player/set_play_mode?pid={pid_q}"
            f"&repeat={urllib.parse.quote(repeat)}"
            f"&shuffle={urllib.parse.quote(_st.shuffle)}",
        )

    @property
    def Rate(self) -> float:
        return 1.0

    @Rate.setter
    def Rate(self, _: float) -> None:
        pass

    @property
    def Shuffle(self) -> bool:
        return _st.shuffle == "on"

    @Shuffle.setter
    def Shuffle(self, value: bool) -> None:
        if not _st.heos_pid or not _mpris_transport_allowed("Shuffle"):
            return
        pid_q = urllib.parse.quote(_st.heos_pid)
        _heos_fire(
            self._ip,
            f"player/set_play_mode?pid={pid_q}"
            f"&repeat={urllib.parse.quote(_st.repeat)}"
            f"&shuffle={urllib.parse.quote('on' if value else 'off')}",
        )

    @property
    def Metadata(self) -> dict[str, Any]:
        return _metadata(_st)

    @property
    def Volume(self) -> float:
        return _effective_volume(_st)

    @Volume.setter
    def Volume(self, value: float) -> None:
        global _vol_suppress, _mute_suppress
        value = max(0.0, min(1.0, float(value)))
        ip = self._ip
        was_muted = _st.mute

        if value == 0.0:
            if not was_muted:
                _mute_suppress = (True, time.monotonic())
                GLib.idle_add(_apply, {"mute": True, "_vol_optimistic": True})
                def _mute() -> None:
                    try:
                        _avr_set(ip, 12, "<MainZone><Mute>1</Mute></MainZone>")
                    except Exception as exc:
                        log.warning("Mute set failed: %s", exc)
                threading.Thread(target=_mute, daemon=True, name="avr-mute").start()
            return

        raw = _db_to_raw(_mpris_to_db(value))
        _vol_suppress = (raw, time.monotonic())
        if was_muted:
            _mute_suppress = (False, time.monotonic())
            GLib.idle_add(_apply, {"vol_raw": raw, "mute": False, "_vol_optimistic": True})
        else:
            GLib.idle_add(_apply, {"vol_raw": raw, "_vol_optimistic": True})

        def _go() -> None:
            try:
                if was_muted:
                    _avr_set(ip, 12, "<MainZone><Mute>2</Mute></MainZone>")
                    time.sleep(0.4)   # AVR needs a moment after unmute before accepting volume
                _avr_set(ip, 12, f"<MainZone><Volume>{raw}</Volume></MainZone>")
            except Exception as exc:
                log.warning("Volume set failed: %s", exc)

        threading.Thread(target=_go, daemon=True, name="avr-setvol").start()

    @property
    def Position(self) -> int:
        return 0  # HEOS has no position API

    @property
    def MinimumRate(self) -> float:
        return 1.0

    @property
    def MaximumRate(self) -> float:
        return 1.0

    @property
    def CanGoNext(self) -> bool:
        return _can_control_heos(_st)

    @property
    def CanGoPrevious(self) -> bool:
        return _can_control_heos(_st)

    @property
    def CanPlay(self) -> bool:
        return _can_control_heos(_st)

    @property
    def CanPause(self) -> bool:
        return _can_control_heos(_st)

    @property
    def CanSeek(self) -> bool:
        return False

    @property
    def CanControl(self) -> bool:
        return True

    # ── org.mpris.MediaPlayer2.Player — control methods ───────────────────────

    def _play_state(self, state: str) -> None:
        if _st.heos_pid and _mpris_transport_allowed(state):
            pid_q = urllib.parse.quote(_st.heos_pid)
            _heos_fire(self._ip, f"player/set_play_state?pid={pid_q}&state={state}")

    def Play(self) -> None:
        self._play_state("play")

    def Pause(self) -> None:
        self._play_state("pause")

    def PlayPause(self) -> None:
        self._play_state("pause" if _playback_status(_st) == "Playing" else "play")

    def Stop(self) -> None:
        self._play_state("stop")

    def Next(self) -> None:
        if _st.heos_pid and _mpris_transport_allowed("Next"):
            _heos_fire(self._ip, f"player/play_next?pid={urllib.parse.quote(_st.heos_pid)}")

    def Previous(self) -> None:
        if _st.heos_pid and _mpris_transport_allowed("Previous"):
            _heos_fire(self._ip, f"player/play_previous?pid={urllib.parse.quote(_st.heos_pid)}")

    def Seek(self, Offset: int) -> None:
        pass  # HEOS has no seek API

    def SetPosition(self, TrackId: str, Position: int) -> None:
        pass

    def OpenUri(self, Uri: str) -> None:
        pass

# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    global _bus
    ip = _find_ip()
    log.info(
        "denon-mpris starting  ip=%s  poll=%.0fs  max_db=%.0fdB  auto_switch=%s",
        ip, _POLL_INT, _MAX_DB, int(_MPRIS_AUTO_SWITCH),
    )

    loop   = GLib.MainLoop()
    _bus   = pydbus.SessionBus()
    bridge = DenonBridge(ip, loop)

    avr_stop = threading.Event()
    avr_thr  = threading.Thread(
        target=_avr_poll, args=(ip, avr_stop), daemon=True, name="avr-poll",
    )
    heos = _HEOSClient(ip)

    with _bus.publish(BUS_NAME, (OBJ_PATH, bridge)):
        avr_thr.start()
        heos.start()
        try:
            loop.run()
        except KeyboardInterrupt:
            pass
        finally:
            avr_stop.set()
            heos.stop()


if __name__ == "__main__":
    main()
