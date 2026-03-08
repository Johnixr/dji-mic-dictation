import json
import os
import shutil
import sqlite3
import subprocess
import sys
import textwrap
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "dictation-enter.sh"


def iso_timestamp(offset_seconds=0):
    dt = datetime.now(timezone.utc) + timedelta(seconds=offset_seconds)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


@dataclass
class HistoryRow:
    rowid: int
    status: str
    created_at: str
    updated_at: str
    refined_text: str


class DictationHarness:
    def __init__(self, tmp_path: Path):
        self.tmp_path = tmp_path
        self.state_dir = tmp_path / "state"
        self.state_dir.mkdir()
        self.log_file = self.state_dir / "debug.log"
        self.db_path = tmp_path / "typeless.db"
        self.home_dir = tmp_path / "home"
        self.home_dir.mkdir()
        self.config_dir = self.home_dir / ".config" / "dji-mic-dictation"
        self.bin_dir = tmp_path / "bin"
        self.bin_dir.mkdir()
        self.tmux_log = tmp_path / "tmux.log"
        self.osa_log = tmp_path / "osascript.log"
        self.kcli_log = tmp_path / "karabiner_cli.log"
        self.afplay_log = tmp_path / "afplay.log"
        self.hud_log = tmp_path / "hud.log"
        self.swiftc_log = tmp_path / "swiftc.log"

        self._create_db()
        self._write_stub_bins()

        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home_dir),
                "STATE_DIR": str(self.state_dir),
                "LOG": str(self.log_file),
                "TYPELESS_DB": str(self.db_path),
                "TMUX_BIN": str(self.bin_dir / "tmux"),
                "KCLI": str(self.bin_dir / "karabiner_cli"),
                "OSASCRIPT_BIN": str(self.bin_dir / "osascript"),
                "AFPLAY_BIN": str(self.bin_dir / "afplay"),
                "SWIFTC_BIN": str(self.bin_dir / "swiftc"),
                "PYTHON3_BIN": sys.executable,
                "WATCH_POLL_INTERVAL": "0.01",
                "WATCH_MAX_POLLS": "40",
                "NO_RECORD_LOG_AFTER_POLLS": "3",
                "NO_RECORD_LOG_LABEL": "test-threshold",
                "STALE_CHECK_EVERY_POLLS": "2",
                "STALE_SECONDS": "0.01",
                "CONFIRM_WINDOW": "0.4",
                "PRECONFIRM_GRACE_INTERVAL": "0.01",
                "PRECONFIRM_GRACE_POLLS": "4",
                "DELIVERY_DELAY": "0",
                "FAKE_FRONT_BUNDLE": "com.google.Chrome",
                "FAKE_ITERM_WINDOW": "↣ test",
                "FAKE_TMUX_LIST_PANES_OUTPUT": "1 1 1 %1\n",
                "TMUX_LOG_FILE": str(self.tmux_log),
                "OSA_LOG_FILE": str(self.osa_log),
                "KCLI_LOG_FILE": str(self.kcli_log),
                "AFPLAY_LOG_FILE": str(self.afplay_log),
                "HUD_LOG_FILE": str(self.hud_log),
                "SWIFTC_LOG_FILE": str(self.swiftc_log),
                "FAKE_WIN_POS": "100 200",
            }
        )

    def _create_db(self):
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                CREATE TABLE history (
                    status TEXT,
                    created_at TEXT,
                    updated_at TEXT,
                    refined_text TEXT
                )
                """
            )

    def _write_executable(self, name: str, content: str):
        path = self.bin_dir / name
        path.write_text(textwrap.dedent(content))
        path.chmod(0o755)

    def _write_stub_bins(self):
        python = sys.executable

        self._write_executable(
            "karabiner_cli",
            f"""#!/usr/bin/env {python}
import os
import shlex
import sys

log = os.environ["KCLI_LOG_FILE"]
with open(log, "a", encoding="utf-8") as fh:
    fh.write(" ".join(shlex.quote(arg) for arg in sys.argv[1:]) + "\\n")
""",
        )

        self._write_executable(
            "tmux",
            f"""#!/usr/bin/env {python}
import os
import shlex
import sys

log = os.environ["TMUX_LOG_FILE"]
with open(log, "a", encoding="utf-8") as fh:
    fh.write(" ".join(shlex.quote(arg) for arg in sys.argv[1:]) + "\\n")

if len(sys.argv) > 1 and sys.argv[1] == "list-panes":
    sys.stdout.write(os.environ.get("FAKE_TMUX_LIST_PANES_OUTPUT", ""))
""",
        )

        self._write_executable(
            "afplay",
            f"""#!/usr/bin/env {python}
import os
import shlex
import sys

log = os.environ["AFPLAY_LOG_FILE"]
with open(log, "a", encoding="utf-8") as fh:
    fh.write(" ".join(shlex.quote(arg) for arg in sys.argv[1:]) + "\\n")
""",
        )

        self._write_executable(
            "swiftc",
            f"""#!/usr/bin/env {python}
import os
import shlex
import sys
import time
from pathlib import Path

compile_log = os.environ["SWIFTC_LOG_FILE"]
with open(compile_log, "a", encoding="utf-8") as fh:
    fh.write(" ".join(shlex.quote(arg) for arg in sys.argv[1:]) + "\\n")

time.sleep(float(os.environ.get("SWIFTC_STUB_SLEEP", "0")))

args = sys.argv[1:]
output_path = args[args.index("-o") + 1]
script = Path(output_path)
script.write_text({repr(textwrap.dedent(f'''#!/usr/bin/env {python}
import os
from pathlib import Path
import signal
import shlex
import sys
import time

log = os.environ["HUD_LOG_FILE"]

def append(entry):
	with open(log, "a", encoding="utf-8") as fh:
		fh.write(entry + "\\n")

args = sys.argv[1:]
append(" ".join(shlex.quote(arg) for arg in args))

if "--daemon" in args:
	idx = args.index("--daemon")
	control_path = Path(args[idx + 1])
	ready_path = Path(args[idx + 2])
	ready_path.write_text("ready", encoding="utf-8")
	running = [True]

	def handle_command(_signum, _frame):
		command = control_path.read_text(encoding="utf-8").strip() if control_path.exists() else ""
		append(f"command {{command}}")
		if command == "stop":
			running[0] = False

	def handle_term(_signum, _frame):
		running[0] = False

	signal.signal(signal.SIGUSR1, handle_command)
	signal.signal(signal.SIGTERM, handle_term)
	while running[0]:
		time.sleep(0.01)
	if ready_path.exists():
		ready_path.unlink()
	sys.exit(0)

duration = os.environ.get("HUD_STUB_SLEEP")
if duration is None:
	visible_args = [arg for arg in args if arg != "--warmup"]
	duration = visible_args[0] if visible_args else "0"
time.sleep(float(duration))
'''))}, encoding="utf-8")
script.chmod(0o755)
""",
        )

        self._write_executable(
            "osascript",
            f"""#!/usr/bin/env {python}
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
stdin = sys.stdin.read()
log = os.environ["OSA_LOG_FILE"]
with open(log, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({{"args": args, "stdin": stdin}}, ensure_ascii=False) + "\\n")

if "-e" in args:
    expr = args[args.index("-e") + 1]
    if "bundle identifier of first application process whose frontmost is true" in expr:
        sys.stdout.write(os.environ.get("FAKE_FRONT_BUNDLE", "com.google.Chrome"))
    elif "name of current window" in expr:
        sys.stdout.write(os.environ.get("FAKE_ITERM_WINDOW", "↣ test"))
elif args[:2] == ["-l", "JavaScript"]:
    if not (len(args) >= 3 and args[2] == "-"):
        state_dir = Path(os.environ["STATE_DIR"])
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "win_pos").write_text(os.environ.get("FAKE_WIN_POS", "100 200"), encoding="utf-8")
        sys.stdout.write("ok")
""",
        )

    def run(self, *args, check=True, env=None):
        merged_env = self.env.copy()
        if env:
            merged_env.update(env)
        return subprocess.run(
            [str(SCRIPT_PATH), *args],
            cwd=REPO_ROOT,
            env=merged_env,
            text=True,
            capture_output=True,
            check=check,
        )

    def popen(self, *args, env=None):
        merged_env = self.env.copy()
        if env:
            merged_env.update(env)
        return subprocess.Popen(
            [str(SCRIPT_PATH), *args],
            cwd=REPO_ROOT,
            env=merged_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def insert_history(self, status="", created_at=None, updated_at=None, refined_text=""):
        created_at = created_at or iso_timestamp(-1)
        updated_at = updated_at or created_at
        with sqlite3.connect(self.db_path) as conn:
            cursor = conn.execute(
                "INSERT INTO history (status, created_at, updated_at, refined_text) VALUES (?, ?, ?, ?)",
                (status, created_at, updated_at, refined_text),
            )
            rowid = cursor.lastrowid
        return HistoryRow(rowid=rowid, status=status, created_at=created_at, updated_at=updated_at, refined_text=refined_text)

    def update_history(self, rowid, *, status=None, updated_at=None, refined_text=None):
        fields = []
        values = []
        if status is not None:
            fields.append("status = ?")
            values.append(status)
        if updated_at is not None:
            fields.append("updated_at = ?")
            values.append(updated_at)
        if refined_text is not None:
            fields.append("refined_text = ?")
            values.append(refined_text)
        if not fields:
            return
        values.append(rowid)
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(f"UPDATE history SET {', '.join(fields)} WHERE rowid = ?", values)

    def get_history(self, rowid):
        with sqlite3.connect(self.db_path) as conn:
            row = conn.execute(
                "SELECT rowid, COALESCE(status, ''), created_at, updated_at, COALESCE(refined_text, '') FROM history WHERE rowid = ?",
                (rowid,),
            ).fetchone()
        return HistoryRow(*row)

    def read_state(self, name):
        path = self.state_dir / name
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def write_state(self, name, value):
        (self.state_dir / name).write_text(value, encoding="utf-8")

    def write_app_config(self, **entries):
        self.config_dir.mkdir(parents=True, exist_ok=True)
        lines = [f"{key}={value}" for key, value in entries.items()]
        (self.config_dir / "config.env").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def log_text(self):
        return self.log_file.read_text(encoding="utf-8") if self.log_file.exists() else ""

    def read_lines(self, path: Path):
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def tmux_calls(self):
        return self.read_lines(self.tmux_log)

    def osascript_calls(self):
        return [json.loads(line) for line in self.read_lines(self.osa_log)]

    def kcli_calls(self):
        return self.read_lines(self.kcli_log)

    def afplay_calls(self):
        return self.read_lines(self.afplay_log)

    def hud_calls(self):
        return self.read_lines(self.hud_log)

    def swiftc_calls(self):
        return self.read_lines(self.swiftc_log)


class RealTmuxHarness(DictationHarness):
    def __init__(self, tmp_path: Path):
        super().__init__(tmp_path)
        self.real_tmux_bin = shutil.which("tmux")
        if not self.real_tmux_bin:
            raise RuntimeError("tmux not found")
        self.tmux_socket_name = f"dji-smoke-{uuid.uuid4().hex[:8]}"
        self.session_name = f"smoke-{uuid.uuid4().hex[:8]}"
        self.tmux_output_file = tmp_path / "tmux-output.txt"
        self.env.update(
            {
                "REAL_TMUX_BIN": self.real_tmux_bin,
                "TMUX_SOCKET_NAME": self.tmux_socket_name,
                "FAKE_FRONT_BUNDLE": "com.googlecode.iterm2",
                "FAKE_ITERM_WINDOW": "↣ smoke",
            }
        )
        self._write_real_tmux_wrapper()
        self._start_tmux_session()

    def _write_real_tmux_wrapper(self):
        python = sys.executable
        self._write_executable(
            "tmux",
            f"""#!/usr/bin/env {python}
import os
import shlex
import subprocess
import sys

args = sys.argv[1:]
log = os.environ["TMUX_LOG_FILE"]
with open(log, "a", encoding="utf-8") as fh:
    fh.write(" ".join(shlex.quote(arg) for arg in args) + "\\n")

if args and args[0] == "list-panes" and os.environ.get("FAKE_ACTIVE_TMUX_PANE"):
    sys.stdout.write(f"1 1 1 {{os.environ['FAKE_ACTIVE_TMUX_PANE']}}\\n")
    raise SystemExit(0)

cmd = [os.environ["REAL_TMUX_BIN"], "-L", os.environ["TMUX_SOCKET_NAME"], *args]
proc = subprocess.run(cmd, text=True, capture_output=True)
sys.stdout.write(proc.stdout)
sys.stderr.write(proc.stderr)
raise SystemExit(proc.returncode)
""",
        )

    def real_tmux(self, *args, check=True):
        return subprocess.run(
            [self.real_tmux_bin, "-L", self.tmux_socket_name, *args],
            text=True,
            capture_output=True,
            check=check,
        )

    def _start_tmux_session(self):
        self.real_tmux("new-session", "-d", "-s", self.session_name, "/bin/sh")
        time.sleep(0.05)
        pane = self.real_tmux("display-message", "-p", "-t", f"{self.session_name}:0.0", "#{pane_id}")
        self.pane_id = pane.stdout.strip()
        self.env["FAKE_ACTIVE_TMUX_PANE"] = self.pane_id

    def queue_pane_command(self, command: str):
        self.real_tmux("send-keys", "-t", self.pane_id, command)

    def pane_output_contains(self, text: str) -> bool:
        return self.tmux_output_file.exists() and text in self.tmux_output_file.read_text(encoding="utf-8")

    def wait_for_pane_output(self, text: str, timeout: float = 1.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.pane_output_contains(text):
                return True
            time.sleep(0.02)
        return self.pane_output_contains(text)

    def cleanup_tmux(self):
        self.real_tmux("kill-server", check=False)


@pytest.fixture
def harness(tmp_path):
    return DictationHarness(tmp_path)


@pytest.fixture
def tmux_harness(tmp_path):
    harness = RealTmuxHarness(tmp_path)
    try:
        yield harness
    finally:
        harness.cleanup_tmux()
