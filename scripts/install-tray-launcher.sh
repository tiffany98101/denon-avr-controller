#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-tray-launcher.sh [--autostart] [--uninstall] [--help]

Installs a per-user Denon dashboard tray launcher. No root access is required.

Options:
  --autostart   Also install a desktop autostart entry.
  --uninstall   Remove files installed by this script.
  --help        Show this help.
EOF
}

want_autostart=0
uninstall=0

while (($#)); do
  case "$1" in
    --autostart) want_autostart=1 ;;
    --uninstall) uninstall=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

bin_dir="${HOME}/.local/bin"
applications_dir="${HOME}/.local/share/applications"
autostart_dir="${HOME}/.config/autostart"
tray_script="${bin_dir}/denon-tray-launcher"
desktop_file="${applications_dir}/denon-tray-launcher.desktop"
autostart_file="${autostart_dir}/denon-tray-launcher.desktop"

if (( uninstall )); then
  rm -f "$tray_script" "$desktop_file" "$autostart_file"
  echo "Removed:"
  echo "  $tray_script"
  echo "  $desktop_file"
  echo "  $autostart_file"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required for the tray launcher." >&2
  echo "Fedora hint: sudo dnf install python3" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
repo_root="$(cd -- "${script_dir}/.." >/dev/null 2>&1 && pwd)"
repo_cli="${repo_root}/denon_release_candidate.sh"

if command -v denon >/dev/null 2>&1; then
  denon_command="denon dashboard --color always --unicode --watch"
elif [[ -x "$repo_cli" ]]; then
  printf -v quoted_cli '%q' "$repo_cli"
  denon_command="${quoted_cli} dashboard --color always --unicode --watch"
else
  echo "Error: could not find 'denon' on PATH or executable repo CLI at: $repo_cli" >&2
  exit 1
fi

mkdir -p "$bin_dir" "$applications_dir"

{
  printf '#!/usr/bin/env python3\n'
  python3 -c 'import json, sys; print("DENON_COMMAND = " + json.dumps(sys.argv[1]))' "$denon_command"
  cat <<'PYEOF'

import os
import shutil
import signal
import subprocess
import sys


APP_NAME = "Denon Dashboard"


def import_qt():
    try:
        from PyQt6.QtGui import QAction, QIcon
        from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon
        return QApplication, QMenu, QSystemTrayIcon, QAction, QIcon
    except ImportError:
        try:
            from PyQt5.QtGui import QIcon
            from PyQt5.QtWidgets import QAction, QApplication, QMenu, QSystemTrayIcon
            return QApplication, QMenu, QSystemTrayIcon, QAction, QIcon
        except ImportError:
            print("Missing Qt bindings for Python.", file=sys.stderr)
            print("Fedora KDE hints: sudo dnf install python3-qt6 konsole", file=sys.stderr)
            print("Fallback package: sudo dnf install python3-qt5 konsole", file=sys.stderr)
            sys.exit(1)


QApplication, QMenu, QSystemTrayIcon, QAction, QIcon = import_qt()
dashboard_process = None


def terminal_command():
    shell_cmd = DENON_COMMAND
    if shutil.which("konsole"):
        return ["konsole", "--new-tab", "-p", f"tabtitle={APP_NAME}", "-e", "bash", "-lc", shell_cmd]
    if shutil.which("x-terminal-emulator"):
        return ["x-terminal-emulator", "-e", "bash", "-lc", shell_cmd]
    if shutil.which("gnome-terminal"):
        return ["gnome-terminal", "--", "bash", "-lc", shell_cmd]
    if shutil.which("xterm"):
        return ["xterm", "-T", APP_NAME, "-e", "bash", "-lc", shell_cmd]
    print("No supported terminal found. Install konsole for Fedora KDE.", file=sys.stderr)
    return None


def open_dashboard():
    global dashboard_process
    cmd = terminal_command()
    if not cmd:
        return
    dashboard_process = subprocess.Popen(cmd, start_new_session=True)


def restart_dashboard():
    global dashboard_process
    if dashboard_process and dashboard_process.poll() is None:
        try:
            os.killpg(dashboard_process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    open_dashboard()


def is_trigger(reason):
    trigger = getattr(QSystemTrayIcon, "ActivationReason", QSystemTrayIcon).Trigger
    return reason == trigger


def main():
    app = QApplication(sys.argv)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("System tray is not available in this desktop session.", file=sys.stderr)
        sys.exit(1)

    tray = QSystemTrayIcon(QIcon.fromTheme("audio-card"), app)
    tray.setToolTip(APP_NAME)

    menu = QMenu()
    open_action = QAction("Open Dashboard", menu)
    restart_action = QAction("Redraw/Restart Dashboard", menu)
    quit_action = QAction("Quit Tray Launcher", menu)

    open_action.triggered.connect(open_dashboard)
    restart_action.triggered.connect(restart_dashboard)
    quit_action.triggered.connect(app.quit)

    menu.addAction(open_action)
    menu.addAction(restart_action)
    menu.addSeparator()
    menu.addAction(quit_action)
    tray.setContextMenu(menu)
    tray.activated.connect(lambda reason: open_dashboard() if is_trigger(reason) else None)
    tray.show()
    run = app.exec if hasattr(app, "exec") else app.exec_
    sys.exit(run())


if __name__ == "__main__":
    main()
PYEOF
} >"$tray_script"
chmod +x "$tray_script"

cat >"$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Denon Dashboard Tray
Comment=Open the Denon AVR dashboard from the system tray
Exec=${tray_script}
Icon=audio-card
Terminal=false
Categories=AudioVideo;Utility;
X-GNOME-Autostart-enabled=true
EOF

if (( want_autostart )); then
  mkdir -p "$autostart_dir"
  cp "$desktop_file" "$autostart_file"
fi

echo "Installed:"
echo "  $tray_script"
echo "  $desktop_file"
if (( want_autostart )); then
  echo "  $autostart_file"
else
  echo "Autostart not enabled. Re-run with --autostart to install:"
  echo "  $autostart_file"
fi

echo
echo "Dashboard command:"
echo "  $denon_command"
echo
echo "Dependency hints for Fedora KDE:"
echo "  sudo dnf install konsole python3-qt6"
echo "  sudo dnf install python3-qt5    # fallback if PyQt6 is unavailable"
