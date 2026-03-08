import threading
import time

from conftest import iso_timestamp


def test_save_records_tmux_anchor_and_mode(harness):
    row = harness.insert_history(status="transcript", refined_text="hello")
    harness.env["FAKE_FRONT_BUNDLE"] = "com.googlecode.iterm2"
    harness.env["FAKE_ITERM_WINDOW"] = "↣ test"

    harness.run("save")

    assert harness.read_state("mode") == "tmux"
    assert harness.read_state("pane_id") == "%1"
    assert harness.read_state("db_anchor_rowid") == str(row.rowid)
    assert harness.read_state("db_anchor_updated_at") == row.updated_at
    assert "save mode=tmux" in harness.log_text()


def test_watch_tmux_preconfirm_send_handles_reused_row_update(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.googlecode.iterm2"
    harness.env["FAKE_ITERM_WINDOW"] = "↣ test"
    row = harness.insert_history(status="", refined_text="")
    harness.run("save")

    def produce_transcript_and_preconfirm():
        time.sleep(0.06)
        harness.update_history(
            row.rowid,
            status="transcript",
            updated_at=iso_timestamp(),
            refined_text="hello world",
        )
        time.sleep(0.03)
        harness.run("preconfirm")

    worker = threading.Thread(target=produce_transcript_and_preconfirm)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = harness.log_text()
    assert "watch tmux transcript_detected" in log_text
    assert "watch tmux preconfirm_send" in log_text
    assert any("send-keys -t %1 Enter" in call for call in harness.tmux_calls())


def test_watch_gui_logs_still_no_record_then_completes(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["NO_RECORD_LOG_AFTER_POLLS"] = "1"
    harness.env["NO_RECORD_LOG_LABEL"] = "first-poll"
    harness.run("save")

    def insert_late_transcript():
        time.sleep(0.12)
        harness.insert_history(status="transcript", refined_text="late transcript")

    worker = threading.Thread(target=insert_late_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = harness.log_text()
    assert "watch gui still_no_record_after_first-poll" in log_text
    assert "watch gui transcript_detected" in log_text
    assert "watch gui content_settled" in log_text
    assert "watch gui window_expired" in log_text
    assert any("Tink.aiff" in call for call in harness.afplay_calls())


def test_watch_tmux_aborts_on_stale_record(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.googlecode.iterm2"
    harness.env["FAKE_ITERM_WINDOW"] = "↣ test"
    harness.run("save")
    harness.insert_history(
        status="",
        created_at="2000-01-01T00:00:00.000Z",
        updated_at="2000-01-01T00:00:00.000Z",
        refined_text="",
    )

    harness.run("watch")

    log_text = harness.log_text()
    assert "watch tmux record_detected" in log_text
    assert "watch tmux stale_record" in log_text


def test_confirm_gui_sends_enter_and_cleans_up(harness):
    harness.write_state("mode", "gui")
    harness.write_state("win_pos", "10 20")

    harness.run("confirm")

    log_text = harness.log_text()
    assert "confirm gui send_enter" in log_text
    assert harness.read_state("mode") == ""
    calls = harness.osascript_calls()
    assert any(call["args"][:2] == ["-l", "JavaScript"] for call in calls)
    assert any(
        "keystroke return" in " ".join(call["args"])
        or "write text" in " ".join(call["args"])
        for call in calls
    )
