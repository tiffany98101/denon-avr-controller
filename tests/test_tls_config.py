import os
import subprocess
import textwrap
from pathlib import Path


ROOT = Path(__file__).parent.parent
SCRIPT = ROOT / "denon.sh"


def _bash(code: str, env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["DENON_UNIT_TEST"] = "1"
    for key in ("DENON_CURL_INSECURE", "DENON_CURL_CACERT", "DENON_CURL_PINNEDPUBKEY"):
        env.pop(key, None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", "-c", f"source {SCRIPT}\n{code}"],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
    )


def _tls_args(env_extra: dict | None = None) -> list[str]:
    code = textwrap.dedent("""\
        _denon_curl_tls_args || exit $?
        if (( ${#DENON_CURL_TLS_ARGS[@]} > 0 )); then
          printf '%s\\n' "${DENON_CURL_TLS_ARGS[@]}"
        fi
    """)
    r = _bash(code, env_extra)
    assert r.returncode == 0, r.stderr
    return r.stdout.splitlines()


def _doctor_output(tmp_path: Path, env_extra: dict | None = None) -> str:
    code = textwrap.dedent("""\
        _denon_known_hosts() { return 0; }
        _denon_probe_candidate() { return 1; }
        _denon_ms_now() { printf '0'; }
        _denon_doctor || true
    """)
    env = {"HOME": str(tmp_path)}
    if env_extra:
        env.update(env_extra)
    r = _bash(code, env)
    assert r.returncode == 0, r.stderr
    return r.stdout


def test_default_tls_mode_includes_insecure_flag():
    assert _tls_args() == ["-k"]


def test_explicit_insecure_mode_includes_insecure_flag():
    assert _tls_args({"DENON_CURL_INSECURE": "1"}) == ["-k"]


def test_strict_tls_mode_omits_insecure_flag():
    assert _tls_args({"DENON_CURL_INSECURE": "0"}) == []


def test_custom_ca_adds_cacert_and_omits_insecure_by_default():
    assert _tls_args({"DENON_CURL_CACERT": "/tmp/avr cert.pem"}) == [
        "--cacert",
        "/tmp/avr cert.pem",
    ]


def test_pinned_public_key_is_added_to_default_mode():
    assert _tls_args({"DENON_CURL_PINNEDPUBKEY": "sha256//BASE64HASH"}) == [
        "-k",
        "--pinnedpubkey",
        "sha256//BASE64HASH",
    ]


def test_explicit_insecure_overrides_custom_ca_precedence():
    assert _tls_args({"DENON_CURL_INSECURE": "1", "DENON_CURL_CACERT": "/tmp/ca.pem"}) == ["-k"]


def test_curl_uses_tls_args_before_timeouts(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "curl.log"
    curl = bin_dir / "curl"
    curl.write_text(
        textwrap.dedent(f"""\
            #!/usr/bin/env bash
            printf '%s\\n' "$*" >'{log}'
        """),
        encoding="utf-8",
    )
    curl.chmod(0o755)
    r = _bash(
        "_denon_curl https://192.0.2.10/test >/dev/null",
        {"PATH": f"{bin_dir}:{os.environ['PATH']}", "DENON_CURL_INSECURE": "0"},
    )
    assert r.returncode == 0, r.stderr
    args = log.read_text(encoding="utf-8")
    assert "-k" not in args
    assert "--connect-timeout 2 --max-time 4 https://192.0.2.10/test" in args


def test_doctor_reports_default_insecure_mode(tmp_path):
    output = _doctor_output(tmp_path)
    assert "TLS verification:      insecure compatibility mode (-k)" in output
    assert "TLS pinned public key: unset" in output
    assert "Warning: HTTPS certificate verification is disabled for AVR compatibility" in output


def test_doctor_reports_strict_system_trust_mode(tmp_path):
    output = _doctor_output(tmp_path, {"DENON_CURL_INSECURE": "0"})
    assert "TLS verification:      system trust" in output
    assert "HTTPS certificate verification is disabled" not in output


def test_doctor_reports_custom_ca_mode(tmp_path):
    output = _doctor_output(tmp_path, {"DENON_CURL_CACERT": "/tmp/avr-ca.pem"})
    assert "TLS verification:      custom CA certificate" in output
    assert "TLS CA certificate:    /tmp/avr-ca.pem" in output
    assert "HTTPS certificate verification is disabled" not in output


def test_doctor_reports_pinned_public_key(tmp_path):
    output = _doctor_output(tmp_path, {"DENON_CURL_PINNEDPUBKEY": "sha256//BASE64HASH"})
    assert "TLS verification:      insecure compatibility mode (-k)" in output
    assert "TLS pinned public key: configured" in output
