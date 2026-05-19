"""
Regression tests for dashboard panel alignment with multi-byte UTF-8 content.

Verifies that em-dashes, smart quotes, and other 3-byte UTF-8 codepoints
do not cause the right border to drift leftward.  The root cause was that
bash's printf %-Ns pads to N *bytes* not N display columns; _denon_dashboard_fit
now uses _denon_dashboard_display_width (bytes - continuation bytes) instead.
"""

import os
import re
import subprocess
import textwrap
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "denon_release_candidate.sh"
SCRIPT_STR = str(SCRIPT)

# U+2014 EM DASH, U+201C/201D smart quotes — Python Unicode literals so
# they're sent to bash as proper UTF-8 bytes via subprocess text encoding.
EM_DASH = "—"
LQUOTE  = "“"
RQUOTE  = "”"


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


def _strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)


def _display_width(s: str) -> int:
    """Byte count minus UTF-8 continuation bytes (0x80–0xBF), same logic as shell helper."""
    b = s.encode("utf-8")
    cont = sum(1 for byte in b if 0x80 <= byte <= 0xBF)
    return len(b) - cont


class TestDashboardDisplayWidth:
    """Unit tests for the _denon_dashboard_display_width helper."""

    def test_ascii(self):
        r = _bash('_denon_dashboard_display_width "hello"')
        assert r.returncode == 0
        assert r.stdout.strip() == "5"

    def test_em_dash(self):
        # Use Python raw string so bash receives the literal $'\xe2\x80\x94' escape
        r = _bash(r"_denon_dashboard_display_width $'Song \xe2\x80\x94 Artist'")
        assert r.returncode == 0
        assert r.stdout.strip() == "13"  # "Song — Artist" = 13 display cols

    def test_mixed_multibyte(self):
        # Three em-dashes: each is 3 bytes / 1 column → display width 3
        r = _bash(r"_denon_dashboard_display_width $'\xe2\x80\x94\xe2\x80\x94\xe2\x80\x94'")
        assert r.returncode == 0
        assert r.stdout.strip() == "3"


class TestDashboardFit:
    """_denon_dashboard_fit must emit exactly `width` display columns."""

    def _fit_width(self, text_bash_literal: str, width: int) -> int:
        code = textwrap.dedent(f"""\
            result=$(_denon_dashboard_fit {text_bash_literal} {width})
            printf '%s' "$result"
        """)
        r = _bash(code)
        assert r.returncode == 0
        raw = _strip_ansi(r.stdout)
        return _display_width(raw)

    def test_ascii_padded(self):
        assert self._fit_width('"hello"', 20) == 20

    def test_em_dash_padded(self):
        # "Song — Artist" is 13 display cols; padded to 30 must be exactly 30
        assert self._fit_width(r"$'Song \xe2\x80\x94 Artist'", 30) == 30

    def test_multiple_em_dashes(self):
        # "A — B — C" = 9 display cols; padded to 20 must be exactly 20
        assert self._fit_width(r"$'A \xe2\x80\x94 B \xe2\x80\x94 C'", 20) == 20

    def test_truncation_with_em_dash(self):
        # Long string containing an em-dash; truncated result must be exactly width cols
        assert self._fit_width(r"$'Track Title \xe2\x80\x94 Very Long Artist Name Here'", 15) == 15


class TestRenderCardAlignment:
    """
    Render a full card whose body mixes ASCII-only and em-dash lines; every
    rendered line must have the same display width (straight right border).
    """

    def test_uniform_line_width(self):
        body_lines = [
            "Plain ASCII line",
            f"Song {EM_DASH} Artist",
            f"Another {EM_DASH} Line {EM_DASH} Here",
            "Normal text again",
            f"{LQUOTE}Quoted{RQUOTE} song",
        ]
        body = "\n".join(body_lines)

        # Pass the body through an env var to avoid any shell quoting issues
        # with multi-byte characters.  Call _denon_dashboard_set_borders to
        # initialise dash_tl / dash_v / dash_h etc. before rendering.
        code = textwrap.dedent("""\
            _denon_dashboard_set_borders
            _denon_dashboard_render_card "Test Panel" "$BODY" 40 8
        """)
        r = _bash(code, env_extra={"BODY": body})
        assert r.returncode == 0, f"bash error: {r.stderr}"

        output = _strip_ansi(r.stdout)
        lines = [ln for ln in output.split("\n") if ln]
        assert lines, "expected rendered output"

        widths = [_display_width(ln) for ln in lines]
        assert len(set(widths)) == 1, (
            f"Misaligned right borders — line widths differ: {widths}\n"
            "Lines:\n" + "\n".join(f"  {w:3d}  {repr(ln)}" for w, ln in zip(widths, lines))
        )
