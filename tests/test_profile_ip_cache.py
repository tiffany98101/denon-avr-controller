import os
import subprocess
import textwrap
from pathlib import Path


SCRIPT = Path(__file__).parent.parent / "denon.sh"
SCRIPT_STR = str(SCRIPT)


def _bash(code: str, env_extra: dict | None = None) -> subprocess.CompletedProcess:
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
        timeout=15,
    )


def test_unscoped_cache_path_is_unchanged_when_profile_unset(tmp_path):
    code = textwrap.dedent("""\
        unset DENON_PROFILE
        _denon_is_receiver() { return 0; }
        denon setip 192.0.2.10 >/dev/null
        [[ -f "$HOME/.cache/denon_ip" ]] || exit 10
        [[ ! -f "$HOME/.cache/denon_ip.livingroom" ]] || exit 11
        printf '%s\n' "$(<"$HOME/.cache/denon_ip")"
    """)
    r = _bash(code, {"HOME": str(tmp_path)})
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "192.0.2.10"


def test_profile_cache_path_is_scoped_to_active_profile(tmp_path):
    code = textwrap.dedent("""\
        DENON_PROFILE=livingroom
        _denon_is_receiver() { return 0; }
        denon setip 192.0.2.11 >/dev/null
        [[ -f "$HOME/.cache/denon_ip.livingroom" ]] || exit 10
        [[ ! -f "$HOME/.cache/denon_ip" ]] || exit 11
        printf '%s\n' "$(<"$HOME/.cache/denon_ip.livingroom")"
    """)
    r = _bash(code, {"HOME": str(tmp_path)})
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "192.0.2.11"


def test_invalid_profile_name_is_rejected_before_cache_path_use(tmp_path):
    code = textwrap.dedent("""\
        DENON_PROFILE='../../etc/passwd'
        _denon_is_receiver() { return 0; }
        denon setip 192.0.2.12
    """)
    r = _bash(code, {"HOME": str(tmp_path)})
    assert r.returncode != 0
    assert "profile name must not contain '/'" in r.stderr
    assert not (tmp_path / ".cache" / "denon_ip").exists()


def test_profile_cache_ttl_gate_still_applies(tmp_path):
    code = textwrap.dedent("""\
        DENON_PROFILE=den
        DENON_DEFAULT_IP=192.0.2.99
        DENON_CACHE_TTL_SECONDS=1
        mkdir -p "$HOME/.cache"

        printf '%s' 192.0.2.20 >"$HOME/.cache/denon_ip.den"
        touch "$HOME/.cache/denon_ip.den"
        _denon_is_receiver() { return 0; }
        fresh=$(_denon_discover)

        printf '%s' 192.0.2.21 >"$HOME/.cache/denon_ip.den"
        touch -d '10 seconds ago' "$HOME/.cache/denon_ip.den"
        stale=$(_denon_discover)

        printf '%s\n%s\n%s\n' "$fresh" "$stale" "$(<"$HOME/.cache/denon_ip.den")"
    """)
    r = _bash(code, {"HOME": str(tmp_path)})
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == ["192.0.2.20", "192.0.2.99", "192.0.2.99"]
