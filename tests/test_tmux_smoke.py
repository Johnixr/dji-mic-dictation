import threading
import time

import pytest

from conftest import iso_timestamp


def _pending_command(path, marker):
    return f"printf '{marker}\\n' >> {path}"


@pytest.mark.smoke
def test_tmux_smoke_confirm_sends_enter_to_real_pane(tmux_harness):
    tmux_harness.run("save")
    tmux_harness.queue_pane_command(
        _pending_command(tmux_harness.tmux_output_file, "confirm-smoke")
    )

    tmux_harness.run("confirm")

    assert tmux_harness.wait_for_pane_output("confirm-smoke")
    assert "confirm tmux send_enter" in tmux_harness.log_text()


@pytest.mark.smoke
def test_tmux_smoke_watch_preconfirm_send_hits_real_pane(tmux_harness):
    row = tmux_harness.insert_history(status="", refined_text="")
    tmux_harness.run("save")
    tmux_harness.queue_pane_command(
        _pending_command(tmux_harness.tmux_output_file, "watch-smoke")
    )

    def update_row_and_queue_preconfirm():
        time.sleep(0.05)
        tmux_harness.update_history(
            row.rowid,
            status="transcript",
            updated_at=iso_timestamp(),
            refined_text="watch smoke text",
        )
        time.sleep(0.02)
        tmux_harness.run("preconfirm")

    worker = threading.Thread(target=update_row_and_queue_preconfirm)
    worker.start()
    proc = tmux_harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=3)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert tmux_harness.wait_for_pane_output("watch-smoke")
    log_text = tmux_harness.log_text()
    assert "watch tmux transcript_detected" in log_text or "preconfirm tmux send_enter" in log_text
    assert "watch tmux preconfirm_send" in log_text or "preconfirm tmux send_enter" in log_text
