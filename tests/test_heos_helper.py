import pytest
import sys
import socket
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import denon_heos_helper as heos


class _FakeHeosSocket:
    def __init__(self, chunks):
        self._chunks = list(chunks)
        self.sent = b""

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def settimeout(self, timeout):
        self.timeout = timeout

    def sendall(self, data):
        self.sent += data

    def recv(self, size):
        if self._chunks:
            return self._chunks.pop(0)
        raise socket.timeout()


def test_get_pid_selects_player_matching_receiver_ip(monkeypatch):
    players = [
        {"pid": "111", "ip": "192.0.2.11", "name": "Other HEOS"},
        {"pid": "-222", "ip": "192.0.2.10", "name": "Denon AVR-X1600H"},
    ]

    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    monkeypatch.setattr(heos, "get_players", lambda ip: players)

    assert heos.get_pid("192.0.2.10") == "-222"


def test_get_pid_does_not_choose_default_player_when_multiple_do_not_match(monkeypatch):
    players = [
        {"pid": "111", "ip": "192.0.2.11", "name": "Other HEOS"},
        {"pid": "222", "ip": "192.0.2.12", "name": "Kitchen HEOS"},
    ]

    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    monkeypatch.setattr(heos, "get_players", lambda ip: players)

    with pytest.raises(RuntimeError, match="no HEOS player for receiver"):
        heos.get_pid("192.0.2.10")


def test_get_pid_accepts_single_player_when_receiver_lists_only_one(monkeypatch):
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    monkeypatch.setattr(
        heos,
        "get_players",
        lambda ip: [{"pid": "-1012224017", "ip": "192.168.1.162", "name": "Denon AVR-X1600H"}],
    )

    assert heos.get_pid("192.168.1.162") == "-1012224017"


def test_status_snapshot_uses_selected_player_for_state_and_metadata(monkeypatch):
    players = [
        {"pid": "111", "ip": "192.0.2.11", "name": "Other HEOS"},
        {
            "pid": "-222",
            "ip": "192.0.2.10",
            "name": "Denon AVR-X1600H",
            "model": "Denon AVR-X1600H",
            "version": "3.88.614",
            "network": "wifi",
        },
    ]
    paths = []

    def fake_send(ip, path):
        paths.append(path)
        if path == "player/get_players":
            return {"heos": {"result": "success"}, "payload": players}
        if path == "player/get_now_playing_media?pid=-222":
            return {
                "heos": {"result": "success"},
                "payload": {
                    "song": "Song One",
                    "artist": "Artist One",
                    "album": "Album One",
                    "station": "Station One",
                    "mid": "spotify:media:1",
                    "qid": 1,
                    "sid": 4,
                    "type": "station",
                },
            }
        if path == "player/get_play_state?pid=-222":
            return {"heos": {"result": "success", "message": "pid=-222&state=play"}}
        raise AssertionError(path)

    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    monkeypatch.setattr(heos, "send", fake_send)

    snapshot = heos.status_snapshot("192.0.2.10")

    assert snapshot["pid"] == "-222"
    assert snapshot["player_ip"] == "192.0.2.10"
    assert snapshot["song"] == "Song One"
    assert snapshot["state"] == "play"
    assert "player/get_now_playing_media?pid=111" not in paths


def test_send_parses_large_payload_incrementally(monkeypatch):
    payload = b'{"heos":{"result":"success"},"payload":"' + (b"a" * 200000) + b'"}\r\n'
    chunks = [payload[index : index + 257] for index in range(0, len(payload), 257)]
    fake_socket = _FakeHeosSocket(chunks)

    def fake_create_connection(address, timeout):
        assert address == ("192.0.2.10", 1255)
        return fake_socket

    monkeypatch.setattr(heos.socket, "create_connection", fake_create_connection)

    data = heos.send("192.0.2.10", "player/get_players")

    assert data["heos"]["result"] == "success"
    assert len(data["payload"]) == 200000
    assert fake_socket.sent == b"heos://player/get_players\r\n"
