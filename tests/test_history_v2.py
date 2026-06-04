"""Regression coverage for the Typeless 1.6.x `history_v2` schema migration.

Typeless moved transcripts out of the legacy `history` table (done status
`transcript`) into `history_v2` (done status `completed`). Before the fix the
watcher polled the now-frozen `history` table forever, so "press to send" queued
a `pending_confirm` that never fired. These tests exercise the migrated schema
end to end via the `v2_harness` fixture.
"""

import sqlite3
import threading
import time

from conftest import iso_timestamp


def _seed_frozen_legacy_history(harness):
    """Recreate a real migrated database: a populated-but-frozen legacy `history`
    table coexisting with the active `history_v2`. The fix must anchor on
    `history_v2` and ignore this stale table — the unfixed script anchored here
    and never detected a new transcript."""
    with sqlite3.connect(harness.db_path) as conn:
        conn.execute(
            "CREATE TABLE history (status TEXT, created_at TEXT, updated_at TEXT, refined_text TEXT)"
        )
        conn.execute(
            "INSERT INTO history (status, created_at, updated_at, refined_text) VALUES (?, ?, ?, ?)",
            (
                "transcript",
                "2026-05-26T03:28:06.788Z",
                "2026-05-26T03:28:06.788Z",
                "frozen legacy row",
            ),
        )


def test_v2_save_detects_history_v2_schema_and_anchors(v2_harness):
    h = v2_harness
    h.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    row = h.insert_history(status="completed", refined_text="hello v2")

    h.run("save")

    assert h.read_state("mode") == "gui"
    assert h.read_state("db_anchor_rowid") == str(row.rowid)
    assert h.read_state("db_anchor_updated_at") == row.updated_at
    assert "table=history_v2" in h.log_text()


def test_v2_preconfirm_sends_immediately_when_completed_already_ready(v2_harness):
    h = v2_harness
    h.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    h.run("save")
    h.insert_history(status="completed", refined_text="ready now in v2")

    h.run("preconfirm")

    log_text = h.log_text()
    assert "preconfirm gui send_enter" in log_text
    assert h.read_state("mode") == ""
    assert any(
        "keystroke return" in " ".join(call["args"]) for call in h.osascript_calls()
    )


def test_v2_watch_gui_queued_preconfirm_sends_when_completed_arrives(v2_harness):
    """The exact reported failure: press-to-send fires while Typeless is still
    transcribing, so it queues; the transcript then lands in `history_v2` as
    `completed` and the watcher must deliver the queued Enter. Fails on the
    unfixed script (it polled the frozen legacy `history`)."""
    h = v2_harness
    _seed_frozen_legacy_history(h)
    h.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    h.env["CONFIRM_WINDOW"] = "0.4"
    row = h.insert_history(status="", refined_text="")  # Typeless' in-progress row
    h.run("save")

    def queue_preconfirm_then_complete():
        time.sleep(0.03)
        h.run("preconfirm")  # press-to-send arrives before transcript settles
        time.sleep(0.03)
        h.update_history(
            row.rowid,
            status="completed",
            updated_at=iso_timestamp(),
            refined_text="v2 late completed",
        )

    worker = threading.Thread(target=queue_preconfirm_then_complete)
    worker.start()
    proc = h.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = h.log_text()
    assert "table=history_v2" in log_text
    assert "preconfirm queued" in log_text
    assert "watch gui transcript_detected" in log_text
    assert "watch gui preconfirm_send" in log_text
    assert any(
        "keystroke return" in " ".join(call["args"]) for call in h.osascript_calls()
    )


def test_v2_watch_gui_late_completed_opens_ready_window(v2_harness):
    h = v2_harness
    h.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    h.env["CONFIRM_WINDOW"] = "0.4"
    h.run("save")

    def insert_late_completed():
        time.sleep(0.05)
        h.insert_history(status="completed", refined_text="late but still sendable")

    worker = threading.Thread(target=insert_late_completed)
    worker.start()
    proc = h.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = h.log_text()
    assert "watch gui transcript_detected" in log_text
    assert "watch gui content_settled" in log_text
    assert any(
        '{"dji_watching":0,"dji_ready_to_send":1}' in call for call in h.kcli_calls()
    )
