import os
import subprocess
import textwrap
from pathlib import Path


SCRIPT = Path(__file__).parent.parent / "denon.sh"
SCRIPT_STR = str(SCRIPT)


def _bash(code: str, env_extra: dict | None = None, timeout: int = 15) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["DENON_UNIT_TEST"] = "1"
    if env_extra:
        env.update(env_extra)
    full = f"source {SCRIPT_STR}\n{code}"
    return subprocess.run(
        ["bash", "-c", full],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
    )


def _write_fake_curl(bin_dir: Path) -> None:
    curl = bin_dir / "curl"
    curl.write_text(
        textwrap.dedent("""\
            #!/usr/bin/env bash
            log="${DENON_TEST_LOCK_LOG:?}"
            args="$*"
            if [[ "$args" == *"get_config"* ]]; then
              if [[ "$args" == *"type=12"* ]]; then
                printf 'get_volume %s\\n' "$(date +%s%N)" >>"$log"
                printf '%s\\n' '<listGlobals><MainZone><Volume>450</Volume><Mute>2</Mute></MainZone></listGlobals>'
                exit 0
              fi
              printf '%s\\n' '<FriendlyName>Denon AVR-X1600H</FriendlyName>'
              exit 0
            fi
            if [[ "$args" == *"set_config"* ]]; then
              payload="unknown"
              prev=""
              for arg in "$@"; do
                if [[ "$prev" == "data=data" ]]; then
                  payload="$arg"
                  break
                fi
                prev="$arg"
              done
              printf 'start %s %s\\n' "$payload" "$(date +%s%N)" >>"$log"
              sleep 0.35
              printf 'end %s %s\\n' "$payload" "$(date +%s%N)" >>"$log"
              printf '%s' '200'
              exit 0
            fi
            exit 0
        """)
    )
    curl.chmod(0o755)


def test_no_verify_skips_volume_verify_poll(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_fake_curl(bin_dir)
    log = tmp_path / "calls.log"
    code = textwrap.dedent(f"""\
        DENON_IP=192.0.2.10 denon vol -40 --no-verify
        cat '{log}'
    """)
    env = {
        "HOME": str(tmp_path),
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "DENON_TEST_LOCK_LOG": str(log),
    }
    r = _bash(code, env)
    assert r.returncode == 0, r.stderr
    events = [line.split()[0] for line in log.read_text().splitlines()]
    assert events == ["start", "end"]
    assert "Volume set to -40 dB (unverified)" in r.stdout


def test_no_verify_json_reports_unverified():
    code = textwrap.dedent("""\
        _denon_set_config() { return 0; }
        _denon_main_volume_raw() { printf '999'; }
        DENON_NO_VERIFY_ACTIVE=1 _denon_set_volume_db -40 --json
    """)
    r = _bash(code)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == '{"volumeDb":-40,"verified":false}'


def test_denon_lock_serializes_concurrent_writes(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_fake_curl(bin_dir)
    log = tmp_path / "lock.log"
    code = textwrap.dedent("""\
        DENON_LOCK=1 DENON_IP=192.0.2.10 denon raw set 12 '<A></A>' &
        p1=$!
        DENON_LOCK=1 DENON_IP=192.0.2.10 denon raw set 12 '<B></B>' &
        p2=$!
        wait "$p1"
        wait "$p2"
    """)
    env = {
        "HOME": str(tmp_path),
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "DENON_TEST_LOCK_LOG": str(log),
    }
    r = _bash(code, env, timeout=20)
    assert r.returncode == 0, r.stderr
    events = [line.split()[0] for line in log.read_text().splitlines()]
    assert events == ["start", "end", "start", "end"]


def test_denon_lock_without_flock_warns_and_proceeds(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_fake_curl(bin_dir)
    log = tmp_path / "noflock.log"
    code = textwrap.dedent("""\
        command() {
          if [[ "${1:-}" == "-v" && "${2:-}" == "flock" ]]; then
            return 1
          fi
          builtin command "$@"
        }
        DENON_LOCK=1 DENON_IP=192.0.2.10 denon raw set 12 '<A></A>'
    """)
    env = {
        "HOME": str(tmp_path),
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "DENON_TEST_LOCK_LOG": str(log),
    }
    r = _bash(code, env)
    assert r.returncode == 0, r.stderr
    assert "Warning: DENON_LOCK=1 requested but flock is not available; proceeding without serialization" in r.stderr
    assert "Sent raw set_config type=12" in r.stdout
    assert log.exists()


def test_no_verify_does_not_persist_across_calls(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_fake_curl(bin_dir)
    log = tmp_path / "calls.log"
    code = textwrap.dedent(f"""\
        DENON_IP=192.0.2.10 denon vol -40 --no-verify
        : >'{log}'  # truncate; we only want the second call's calls
        DENON_IP=192.0.2.10 denon vol -30
    """)
    env = {
        "HOME": str(tmp_path),
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "DENON_TEST_LOCK_LOG": str(log),
    }
    r = _bash(code, env)
    assert r.returncode == 0, r.stderr
    events = [line.split()[0] for line in log.read_text().splitlines()]
    # Second call did NOT pass --no-verify, so it must do a verify readback.
    # That means we expect a get_volume call in the log.
    assert "get_volume" in events, (
        f"second call should verify but did not; --no-verify leaked across calls. "
        f"log events: {events}"
    )
    # And the pretty output for the second call must not be marked unverified.
    assert "(unverified)" not in r.stdout.splitlines()[-1]
