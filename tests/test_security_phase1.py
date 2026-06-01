import importlib.util
import os
import subprocess
import textwrap
from collections.abc import Iterable
from pathlib import Path


ROOT = Path(__file__).parent.parent
SCRIPT = ROOT / "denon.sh"
HELPER = ROOT / "denon_heos_helper.py"


def _bash(code: str, env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["DENON_UNIT_TEST"] = "1"
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", "-c", f"source {SCRIPT}\n{code}"],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
    )


def _load_heos_helper():
    spec = importlib.util.spec_from_file_location("denon_heos_helper", HELPER)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _fake_heos_sender(monkeypatch, helper, responses: dict[str, dict] | Iterable[dict]):
    sent = []
    if isinstance(responses, dict):
        response_iter = None
    else:
        response_iter = iter(responses)

    def fake_send(ip, path):
        sent.append((ip, path))
        if response_iter is not None:
            return next(response_iter)
        return responses[path]

    monkeypatch.setattr(helper, "send", fake_send)
    return sent


def test_valid_numeric_heos_pid_is_accepted():
    r = _bash("_denon_is_heos_pid 12345")
    assert r.returncode == 0


def test_valid_signed_numeric_heos_pid_is_accepted():
    r = _bash("_denon_is_heos_pid -1012224017")
    assert r.returncode == 0


def test_empty_heos_pid_is_rejected():
    r = _bash("_denon_is_heos_pid ''")
    assert r.returncode == 1


def test_heos_pid_with_crlf_is_rejected():
    r = _bash("_denon_is_heos_pid $'123\\r\\nplayer/play_next?pid=123'")
    assert r.returncode == 1


def test_heos_pid_with_quotes_or_semicolon_is_rejected():
    r = _bash("_denon_is_heos_pid $'123\";player/play_next'")
    assert r.returncode == 1


def test_rejected_dashboard_pid_does_not_send_player_heos_command(tmp_path):
    log = tmp_path / "heos.log"
    code = textwrap.dedent("""\
        IP=192.0.2.10
        _denon_dashboard_heos_command() {
          printf '%s\\n' "$1" >>"$DENON_TEST_HEOS_LOG"
          if [[ "$1" == "heos://player/get_players" ]]; then
            printf '%s\\n' '{"heos":{"command":"player/get_players","result":"success"},"payload":[{"pid":"123\\r\\nplayer/play_next?pid=123","model":"AVR"}]}'
          fi
        }
        _denon_dashboard_heos_status >/dev/null
    """)
    r = _bash(code, {"DENON_TEST_HEOS_LOG": str(log)})
    assert r.returncode == 0, r.stderr
    assert log.read_text() == "heos://player/get_players\n"


def test_set_config_http_failure_returns_nonzero():
    code = textwrap.dedent("""\
        BASE=http://192.0.2.10
        _denon_curl() { printf '%s' '500'; return 0; }
        _denon_set_config 12 '<MainZone><Mute>1</Mute></MainZone>'
    """)
    r = _bash(code)
    assert r.returncode == 1


def test_info_zone2_volume_text_displays_db_not_raw_only():
    code = textwrap.dedent("""\
        IP=192.0.2.10
        _denon_get_identity_xml() { printf '%s' '<Device><FriendlyName>Denon AVR-X1600H</FriendlyName></Device>'; }
        _denon_get_power_xml() { printf '%s' '<listGlobals><MainZone><Power>1</Power></MainZone><Zone2><Power>1</Power></Zone2></listGlobals>'; }
        _denon_get_source_xml() { printf '%s' '<SourceList><Zone zone="1" index="6"></Zone><Zone zone="2" index="1"></Zone></SourceList>'; }
        _denon_get_vol_xml() { printf '%s' '<listGlobals><MainZone><Volume>490</Volume><Mute>2</Mute></MainZone><Zone2><Volume>650</Volume><Mute>2</Mute></Zone2></listGlobals>'; }
        _denon_query_main_mute_raw() { return 1; }
        _denon_query_zone2_mute_raw() { return 1; }
        _denon_alias_for_source() { return 1; }
        _denon_source_name_by_idx() { [[ "$1" == "2" ]] && printf '%s' 'Phono' || printf '%s' 'TV Audio'; }
        _denon_sources() { return 0; }
        _denon_info
    """)
    r = _bash(code)
    assert r.returncode == 0, r.stderr
    assert "Zone 2 Volume: -15.0 dB" in r.stdout
    assert "Zone 2 Volume Raw:" not in r.stdout


def test_python_helper_rejects_invalid_pid_before_sending(monkeypatch):
    helper = _load_heos_helper()
    sent = []

    def fake_send(ip, path):
        sent.append((ip, path))
        return {"heos": {"result": "success", "message": "level=53"}}

    monkeypatch.setattr(helper, "send", fake_send)
    assert helper.main(["192.0.2.10", "get-volume", "123\r\nplayer/play_next?pid=123"]) == 1
    assert sent == []


def test_heos_groups_without_env_pid_does_not_validate_player_pid(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {"group/get_groups": {"heos": {"result": "success"}, "payload": []}},
    )

    assert helper.main(["192.0.2.10", "groups"]) == 0
    assert sent == [("192.0.2.10", "group/get_groups")]
    assert "invalid HEOS player id" not in capsys.readouterr().err


def test_heos_group_info_without_env_pid_does_not_validate_player_pid(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {
            "group/get_groups": {
                "heos": {"result": "success"},
                "payload": [{"gid": "9", "name": "Everywhere"}],
            },
            "group/get_group_info?gid=9": {
                "heos": {"result": "success"},
                "payload": [{"gid": "9", "name": "Everywhere"}],
            },
        },
    )

    assert helper.main(["192.0.2.10", "group", "info"]) == 0
    assert sent == [
        ("192.0.2.10", "group/get_groups"),
        ("192.0.2.10", "group/get_group_info?gid=9"),
    ]
    assert "invalid HEOS player id" not in capsys.readouterr().err


def test_heos_now_without_env_pid_discovers_numeric_pid(monkeypatch):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {
            "player/get_players": {
                "heos": {"result": "success"},
                "payload": [{"pid": "1234", "name": "AVR"}],
            },
            "player/get_now_playing_media?pid=1234": {
                "heos": {"result": "success"},
                "payload": {"song": "Track", "artist": "Artist"},
            },
            "player/get_play_state?pid=1234": {
                "heos": {"result": "success", "message": "pid=1234&state=play"},
            },
        },
    )

    assert helper.main(["192.0.2.10", "now"]) == 0
    assert sent == [
        ("192.0.2.10", "player/get_players"),
        ("192.0.2.10", "player/get_now_playing_media?pid=1234"),
        ("192.0.2.10", "player/get_play_state?pid=1234"),
    ]


def test_heos_get_volume_without_env_pid_reports_missing_discovery_not_invalid(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {"player/get_players": {"heos": {"result": "success"}, "payload": []}},
    )

    assert helper.main(["192.0.2.10", "get-volume"]) == 1
    assert sent == [("192.0.2.10", "player/get_players")]
    err = capsys.readouterr().err
    assert "no HEOS player id configured or discovered" in err
    assert "invalid HEOS player id" not in err


def test_heos_get_volume_with_missing_discovered_pid_reports_missing_not_invalid(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {"player/get_players": {"heos": {"result": "success"}, "payload": [{"name": "AVR"}]}},
    )

    assert helper.main(["192.0.2.10", "get-volume"]) == 1
    assert sent == [("192.0.2.10", "player/get_players")]
    err = capsys.readouterr().err
    assert "no HEOS player id configured or discovered" in err
    assert "invalid HEOS player id" not in err


def test_env_pid_with_crlf_is_rejected_before_any_heos_command(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.setenv("DENON_HEOS_PID", "1234\r\nheos://player/clear_queue?pid=1234")
    sent = _fake_heos_sender(monkeypatch, helper, {})

    assert helper.main(["192.0.2.10", "now"]) == 1
    assert sent == []
    assert "invalid HEOS player id" in capsys.readouterr().err


def test_env_pid_with_letters_is_rejected(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.setenv("DENON_HEOS_PID", "abc")
    sent = _fake_heos_sender(monkeypatch, helper, {})

    assert helper.main(["192.0.2.10", "get-volume"]) == 1
    assert sent == []
    assert "invalid HEOS player id" in capsys.readouterr().err


def test_discovered_numeric_pid_is_accepted_for_get_volume(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {
            "player/get_players": {
                "heos": {"result": "success"},
                "payload": [{"pid": "4321", "name": "AVR"}],
            },
            "player/get_volume?pid=4321": {
                "heos": {"result": "success", "message": "pid=4321&level=53"},
            },
        },
    )

    assert helper.main(["192.0.2.10", "get-volume"]) == 0
    assert sent == [
        ("192.0.2.10", "player/get_players"),
        ("192.0.2.10", "player/get_volume?pid=4321"),
    ]
    assert capsys.readouterr().out.strip() == "53"


def test_discovered_signed_numeric_pid_is_accepted_for_get_volume(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {
            "player/get_players": {
                "heos": {"result": "success"},
                "payload": [{"pid": -1012224017, "name": "AVR"}],
            },
            "player/get_volume?pid=-1012224017": {
                "heos": {"result": "success", "message": "pid=-1012224017&level=53"},
            },
        },
    )

    assert helper.main(["192.0.2.10", "get-volume"]) == 0
    assert sent == [
        ("192.0.2.10", "player/get_players"),
        ("192.0.2.10", "player/get_volume?pid=-1012224017"),
    ]
    assert capsys.readouterr().out.strip() == "53"


def test_discovered_malicious_pid_is_rejected_before_command_construction(monkeypatch, capsys):
    helper = _load_heos_helper()
    monkeypatch.delenv("DENON_HEOS_PID", raising=False)
    sent = _fake_heos_sender(
        monkeypatch,
        helper,
        {
            "player/get_players": {
                "heos": {"result": "success"},
                "payload": [{"pid": "1234\r\nheos://player/clear_queue?pid=1234"}],
            },
        },
    )

    assert helper.main(["192.0.2.10", "get-volume"]) == 1
    assert sent == [("192.0.2.10", "player/get_players")]
    assert "invalid HEOS player id" in capsys.readouterr().err


def test_heos_helper_failure_propagates_to_cli_status(tmp_path):
    helper = tmp_path / "fake_heos_helper.py"
    helper.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(7)\n")
    helper.chmod(0o755)
    code = textwrap.dedent("""\
        IP=192.0.2.10
        _denon_discover() { printf '%s' "$IP"; }
        denon heos get-volume
    """)
    r = _bash(code, {"DENON_HEOS_HELPER": str(helper)})
    assert r.returncode == 1
