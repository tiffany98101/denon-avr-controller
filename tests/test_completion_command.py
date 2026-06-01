import os
import subprocess
from pathlib import Path


SCRIPT = Path(__file__).parent.parent / "denon.sh"


def _run_denon(*args: str, home: Path | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["HOME"] = str(home) if home is not None else env.get("HOME", "")
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        text=True,
        capture_output=True,
        env=env,
        timeout=15,
        check=False,
    )


def _target(home: Path, shell: str) -> Path:
    if shell == "bash":
        return home / ".local/share/bash-completion/completions/denon"
    if shell == "zsh":
        return home / ".local/share/zsh/site-functions/_denon"
    if shell == "fish":
        return home / ".config/fish/completions/denon.fish"
    raise AssertionError(f"unexpected shell: {shell}")


def test_completion_usage_lists_subcommands() -> None:
    result = _run_denon("completion")

    assert result.returncode == 0, result.stderr
    assert "denon completion bash" in result.stdout
    assert "denon completion zsh" in result.stdout
    assert "denon completion fish" in result.stdout
    assert "denon completion install" in result.stdout


def test_completion_bash_prints_content() -> None:
    result = _run_denon("completion", "bash")

    assert result.returncode == 0, result.stderr
    assert "# bash completion for denon-avr-controller" in result.stdout
    assert "complete -F _denon_complete denon" in result.stdout
    assert "completion" in result.stdout


def test_completion_zsh_prints_content() -> None:
    result = _run_denon("completion", "zsh")

    assert result.returncode == 0, result.stderr
    assert "#compdef denon" in result.stdout
    assert "completion:Generate shell completion scripts" in result.stdout


def test_completion_fish_prints_content() -> None:
    result = _run_denon("completion", "fish")

    assert result.returncode == 0, result.stderr
    assert "# fish completion for denon-avr-controller" in result.stdout
    assert "complete -c denon" in result.stdout
    assert "-l shell" in result.stdout


def test_completion_install_selects_user_paths(tmp_path: Path) -> None:
    for shell in ("bash", "zsh", "fish"):
        home = tmp_path / shell
        result = _run_denon("completion", "install", "--shell", shell, home=home)
        target = _target(home, shell)

        assert result.returncode == 0, result.stderr
        assert target.is_file()
        assert str(target) in result.stdout
        assert "Restart" in result.stdout


def test_completion_install_does_not_overwrite_different_file(tmp_path: Path) -> None:
    target = _target(tmp_path, "bash")
    target.parent.mkdir(parents=True)
    target.write_text("# user custom completion\n", encoding="utf-8")

    result = _run_denon("completion", "install", "--shell", "bash", home=tmp_path)

    assert result.returncode == 1
    assert "already exists and differs" in result.stderr
    assert "--force" in result.stderr
    assert target.read_text(encoding="utf-8") == "# user custom completion\n"


def test_completion_install_force_overwrites(tmp_path: Path) -> None:
    target = _target(tmp_path, "bash")
    target.parent.mkdir(parents=True)
    target.write_text("# user custom completion\n", encoding="utf-8")

    result = _run_denon(
        "completion", "install", "--shell", "bash", "--force", home=tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert "Installed bash completion" in result.stdout
    assert "complete -F _denon_complete denon" in target.read_text(encoding="utf-8")


def test_completion_install_is_idempotent_when_identical(tmp_path: Path) -> None:
    first = _run_denon("completion", "install", "--shell", "fish", home=tmp_path)
    second = _run_denon("completion", "install", "--shell", "fish", home=tmp_path)

    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert "already installed" in second.stdout
