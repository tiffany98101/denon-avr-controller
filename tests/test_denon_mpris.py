import importlib
import sys
import types
from pathlib import Path


ROOT = Path(__file__).parent.parent


class _FakeVariant:
    def __init__(self, signature, value):
        self.signature = signature
        self.value = value


class _FakeGLib:
    Variant = _FakeVariant

    @staticmethod
    def idle_add(func, *args, **kwargs):
        return func(*args, **kwargs)


def _load_mpris(monkeypatch, *, auto_switch: str = "0"):
    monkeypatch.setenv("DENON_MPRIS_AUTO_SWITCH", auto_switch)
    monkeypatch.setitem(sys.modules, "pydbus", types.SimpleNamespace(SessionBus=lambda: None))
    monkeypatch.setitem(sys.modules, "pydbus.generic", types.SimpleNamespace(signal=lambda: object()))
    monkeypatch.setitem(sys.modules, "gi", types.SimpleNamespace())
    monkeypatch.setitem(sys.modules, "gi.repository", types.SimpleNamespace(GLib=_FakeGLib))
    monkeypatch.syspath_prepend(str(ROOT))
    sys.modules.pop("denon_mpris", None)
    return importlib.import_module("denon_mpris")


def _prime_state(mpris, *, source: str = "TV Audio") -> None:
    mpris._st.power = True
    mpris._st.source = source
    mpris._st.heos_ok = True
    mpris._st.heos_pid = "123"
    mpris._st.play_state = "pause"
    mpris._st.title = "Queued Track"
    mpris._st.media_type = "song"


def test_mpris_play_does_not_send_heos_command_off_heos_source_by_default(monkeypatch):
    mpris = _load_mpris(monkeypatch)
    _prime_state(mpris, source="TV Audio")
    calls = []
    monkeypatch.setattr(mpris, "_heos_fire", lambda ip, path: calls.append((ip, path)))

    bridge = mpris.DenonBridge("192.0.2.10", loop=None)
    bridge.Play()

    assert calls == []
    assert bridge.CanPlay is False
    assert bridge.Metadata["xesam:title"].value == "Queued Track"


def test_mpris_auto_switch_opt_in_restores_heos_transport(monkeypatch):
    mpris = _load_mpris(monkeypatch, auto_switch="1")
    _prime_state(mpris, source="TV Audio")
    calls = []
    monkeypatch.setattr(mpris, "_heos_fire", lambda ip, path: calls.append((ip, path)))

    bridge = mpris.DenonBridge("192.0.2.10", loop=None)
    bridge.Play()

    assert calls == [
        ("192.0.2.10", "player/set_play_state?pid=123&state=play"),
    ]
    assert bridge.CanPlay is True


def test_mpris_transport_allowed_when_receiver_is_already_on_heos(monkeypatch):
    mpris = _load_mpris(monkeypatch)
    _prime_state(mpris, source="HEOS Music")
    calls = []
    monkeypatch.setattr(mpris, "_heos_fire", lambda ip, path: calls.append((ip, path)))

    bridge = mpris.DenonBridge("192.0.2.10", loop=None)
    bridge.Next()

    assert calls == [("192.0.2.10", "player/play_next?pid=123")]
    assert bridge.CanGoNext is True
