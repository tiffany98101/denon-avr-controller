import os
import subprocess
import textwrap
from pathlib import Path


ROOT = Path(__file__).parent.parent
SCRIPT = ROOT / "denon.sh"
README = ROOT / "README.md"
ARCHITECTURE = ROOT / "ARCHITECTURE.md"
MANPAGE = ROOT / "man" / "denon.1"


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


def _write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")
    path.chmod(0o755)


def test_xml_split_tags_splits_compact_xml_between_tags():
    code = textwrap.dedent("""\
        printf '%s' '<a><b>1</b><c>2</c></a>' | _denon_xml_split_tags
    """)
    r = _bash(code)
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == ["<a>", "<b>1</b>", "<c>2</c>", "</a>"]


def test_source_rows_from_compact_xml_still_parse():
    code = textwrap.dedent("""\
        xml='<SourceList><Zone zone="1" index="13"><Source index="6"><Name>TV Audio</Name></Source><Source index="13"><Name>HEOS Music</Name></Source></Zone></SourceList>'
        _denon_source_rows_from_xml 1 "$xml"
    """)
    r = _bash(code)
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == ["6\tTV Audio", "13\tHEOS Music"]


def test_iso_now_uses_portable_date_format_not_gnu_dash_is(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "date.log"
    _write_executable(
        bin_dir / "date",
        f"""\
        #!/usr/bin/env bash
        printf '%s\\n' "$*" >>'{log}'
        if [[ "$1" == "-Is" ]]; then
          exit 99
        fi
        if [[ "$1" == "+%Y-%m-%dT%H:%M:%S%z" ]]; then
          printf '%s\\n' '2026-05-31T23:59:58-0700'
          exit 0
        fi
        exit 98
        """,
    )
    r = _bash("_denon_iso_now", {"PATH": f"{bin_dir}:{os.environ['PATH']}"})
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "2026-05-31T23:59:58-0700"
    assert "-Is" not in log.read_text(encoding="utf-8")
    assert "date -Is" not in SCRIPT.read_text(encoding="utf-8")


def test_ms_now_accepts_numeric_date_output(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_executable(
        bin_dir / "date",
        """\
        #!/usr/bin/env bash
        if [[ "$1" == "+%s%3N" ]]; then
          printf '%s\\n' '1700000000123'
          exit 0
        fi
        exit 98
        """,
    )
    _write_executable(
        bin_dir / "python3",
        """\
        #!/usr/bin/env bash
        printf '%s\\n' 'python should not be used'
        exit 99
        """,
    )
    r = _bash("_denon_ms_now", {"PATH": f"{bin_dir}:{os.environ['PATH']}"})
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "1700000000123"


def test_ms_now_rejects_literal_percent_3n_and_uses_python_fallback(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_executable(
        bin_dir / "date",
        """\
        #!/usr/bin/env bash
        if [[ "$1" == "+%s%3N" ]]; then
          printf '%s\\n' '1700000000%3N'
          exit 0
        fi
        exit 98
        """,
    )
    _write_executable(
        bin_dir / "python3",
        """\
        #!/usr/bin/env bash
        printf '%s\\n' '1700000000999'
        """,
    )
    r = _bash("_denon_ms_now", {"PATH": f"{bin_dir}:{os.environ['PATH']}"})
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "1700000000999"


def test_ms_now_rejects_nonnumeric_python_fallback(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_executable(
        bin_dir / "date",
        """\
        #!/usr/bin/env bash
        printf '%s\\n' '1700000000%3N'
        """,
    )
    _write_executable(
        bin_dir / "python3",
        """\
        #!/usr/bin/env bash
        printf '%s\\n' 'not-a-timestamp'
        """,
    )
    r = _bash("_denon_ms_now", {"PATH": f"{bin_dir}:{os.environ['PATH']}"})
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "0"


def test_close_fd_rejects_tainted_input_and_no_unvalidated_eval_remains():
    r = _bash("_denon_close_fd '10;echo unsafe'")
    assert r.returncode == 1
    text = SCRIPT.read_text(encoding="utf-8")
    assert 'eval "exec ${' not in text


def test_close_fd_numeric_path_closes_open_fd():
    code = textwrap.dedent("""\
        tmp=$(mktemp)
        exec {fd}>>"$tmp"
        fd_path=""
        [[ -e "/proc/$$/fd/$fd" ]] && fd_path="/proc/$$/fd/$fd"
        [[ -z "$fd_path" && -e "/dev/fd/$fd" ]] && fd_path="/dev/fd/$fd"
        before=unchecked
        after=unchecked
        [[ -n "$fd_path" ]] && before=open
        _denon_close_fd "$fd"
        rc=$?
        if [[ -n "$fd_path" ]]; then
          [[ -e "$fd_path" ]] && after=open || after=closed
        fi
        printf 'rc=%s before=%s after=%s\\n' "$rc" "$before" "$after"
    """)
    r = _bash(code)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() in {
        "rc=0 before=open after=closed",
        "rc=0 before=unchecked after=unchecked",
    }


def test_help_mentions_bash_runtime_and_shell_completions():
    r = subprocess.run(
        ["bash", str(SCRIPT), "help"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert r.returncode == 0, r.stderr
    assert "runtime script requires bash" in r.stdout
    assert "Shell completions are available for bash, zsh, and fish" in r.stdout
    assert "sourced from bash/zsh" not in r.stdout


def test_docs_clarify_bash_runtime_vs_zsh_fish_completions():
    readme = README.read_text(encoding="utf-8")
    architecture = ARCHITECTURE.read_text(encoding="utf-8")
    manpage = MANPAGE.read_text(encoding="utf-8")
    assert "runtime script requires bash" in readme
    assert "does not mean `denon.sh` is sourced or executed as zsh/fish" in readme
    assert "Bash runtime, not POSIX `sh` or native zsh/fish" in architecture
    assert "zsh and fish support is provided through shell completion files" in manpage
