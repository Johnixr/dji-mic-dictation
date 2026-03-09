import subprocess
import sys
import threading
import time

from conftest import iso_timestamp


def _is_send_window_hud_call(call):
    return call.strip() != ""


def _visible_send_window_hud_calls(harness):
    calls = []
    for call in harness.hud_calls():
        stripped = call.strip()
        if not stripped or stripped == "--warmup" or stripped.startswith("--daemon "):
            continue
        if stripped.startswith("command show|"):
            calls.append(stripped.split("|", 1)[1])
        elif not stripped.startswith("command "):
            calls.append(stripped)
    return calls


def _warmup_hud_calls(harness):
    return [call for call in harness.hud_calls() if call.startswith("--daemon ") or "--warmup" in call]


def _wait_for_hud_warmup(harness, timeout=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        calls = _warmup_hud_calls(harness)
        if calls:
            return calls
        time.sleep(0.01)
    return _warmup_hud_calls(harness)


def _wait_for_log_text(harness, needle, timeout=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in harness.log_text():
            return True
        time.sleep(0.01)
    return needle in harness.log_text()


def _wait_for_condition(predicate, timeout=1.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


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


def test_wakeword_toggle_routes_start_stop_and_confirm(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.googlecode.iterm2"
    harness.env["FAKE_ITERM_WINDOW"] = "↣ test"
    harness.insert_history(status="", refined_text="")

    harness.run("wakeword-toggle")
    assert harness.read_state("workflow_state") == "dictation_active"
    assert harness.read_state("session_origin") == "wakeword"
    assert harness.fn_calls() == ["fn"]

    harness.run("wakeword-toggle")
    assert _wait_for_condition(lambda: harness.read_state("workflow_state") == "watching")
    assert harness.fn_calls() == ["fn", "fn"]
    assert "wakeword toggle stop_watch" in harness.log_text()

    harness.write_state("workflow_state", "ready_to_send")
    harness.write_state("mode", "tmux")
    harness.write_state("pane_id", "%1")

    harness.run("wakeword-toggle")
    assert any("send-keys -t %1 Enter" in call for call in harness.tmux_calls())
    assert "confirm tmux send_enter pane=%1" in harness.log_text()


def test_manual_save_marks_session_origin_and_wakeword_toggle_can_stop_dictation(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"

    harness.run("save")

    assert harness.read_state("workflow_state") == "dictation_active"
    assert harness.read_state("session_origin") == "manual"

    harness.run("wakeword-toggle")

    assert _wait_for_condition(lambda: harness.read_state("workflow_state") == "watching")
    assert harness.fn_calls() == ["fn"]
    assert "wakeword toggle stop_watch" in harness.log_text()


def test_wakeword_rearm_window_blocks_immediate_toggle_and_cancel_after_save(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["WAKEWORD_REARM_DELAY"] = "2.0"

    harness.run("save")

    assert harness.read_state("wakeword_arm_until") != ""

    harness.run("wakeword-toggle")
    assert harness.read_state("workflow_state") == "dictation_active"
    assert "wakeword toggle ignored state=dictation_active reason=arm_window" in harness.log_text()

    harness.run("wakeword-cancel")
    assert harness.read_state("workflow_state") == "dictation_active"
    assert "wakeword cancel ignored state=dictation_active reason=arm_window" in harness.log_text()
    assert harness.fn_calls() == []


def test_wakeword_cancel_clears_ready_state_and_sends_escape(harness):
    harness.write_state("workflow_state", "ready_to_send")
    harness.write_state("mode", "tmux")
    harness.write_state("pane_id", "%1")
    harness.write_state("session_id", "session-1")

    harness.run("wakeword-cancel")

    assert harness.read_state("workflow_state") == "idle"
    assert harness.read_state("mode") == ""
    assert any("send-keys -t %1 Escape" in call for call in harness.tmux_calls())
    assert "wakeword_cancel tmux send_escape pane=%1" in harness.log_text()


def test_wakeword_cancel_is_noop_in_idle(harness):
    harness.write_state("workflow_state", "idle")

    harness.run("wakeword-cancel")

    assert harness.read_state("workflow_state") == "idle"
    assert harness.fn_calls() == []
    assert harness.tmux_calls() == []
    assert harness.osascript_calls() == []


def test_wakeword_cancel_stops_active_manual_session_and_sends_escape(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"

    harness.run("save")
    harness.run("wakeword-cancel")

    assert harness.read_state("workflow_state") == "idle"
    assert harness.read_state("session_origin") == ""
    assert harness.fn_calls() == ["fn"]
    assert any("key code 53" in " ".join(call["args"]) for call in harness.osascript_calls())
    assert "wakeword cancel state=dictation_active" in harness.log_text()
    assert "wakeword cancel stop_then_escape delay=0s" in harness.log_text()


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
    assert "watch tmux transcript_detected" in log_text or "preconfirm tmux send_enter pane=%1" in log_text
    assert "watch tmux preconfirm_send" in log_text or "preconfirm tmux send_enter" in log_text
    assert any("send-keys -t %1 Enter" in call for call in harness.tmux_calls())


def test_watch_gui_logs_still_no_record_then_completes(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["CONFIRM_WINDOW"] = "0.8"
    harness.env["NO_RECORD_LOG_AFTER_POLLS"] = "1"
    harness.env["NO_RECORD_LOG_LABEL"] = "first-poll"
    harness.run("save")

    proc = harness.popen("watch")
    assert _wait_for_log_text(harness, "watch gui still_no_record_after_first-poll", timeout=1.0)
    harness.insert_history(status="transcript", refined_text="late transcript")
    stdout, stderr = proc.communicate(timeout=2)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = harness.log_text()
    assert "watch gui still_no_record_after_first-poll" in log_text
    assert "watch gui transcript_detected" in log_text
    assert "watch gui content_settled" in log_text
    assert "watch gui window_expired" in log_text
    assert harness.afplay_calls() == []


def test_watch_gui_late_transcript_still_opens_ready_window(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["CONFIRM_WINDOW"] = "0.4"
    harness.run("save")

    def insert_late_transcript():
        time.sleep(0.26)
        harness.insert_history(status="transcript", refined_text="late but still sendable")

    worker = threading.Thread(target=insert_late_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = harness.log_text()
    assert "watch gui transcript_detected" in log_text
    assert "watch gui content_settled" in log_text
    assert any('{"dji_watching":0,"dji_ready_to_send":1}' in call for call in harness.kcli_calls())


def test_watch_waits_briefly_for_save_state_before_exiting(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=0,
    )

    def populate_state_then_transcript():
        time.sleep(0.03)
        harness.write_state("mode", "gui")
        harness.write_state("save_ts", iso_timestamp())
        harness.write_state("db_anchor_rowid", "0")
        harness.write_state("db_anchor_updated_at", "")
        time.sleep(0.03)
        harness.insert_history(status="transcript", refined_text="late state ready")

    worker = threading.Thread(target=populate_state_then_transcript)
    worker.start()
    proc = harness.popen("route", "fn-watch", "watch")
    stdout, stderr = proc.communicate(timeout=3)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = harness.log_text()
    assert "watch unknown mode, exit" not in log_text
    assert "watch mode=gui" in log_text


def test_mixed_trigger_restart_keeps_new_ready_window_hud_intact(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["CONFIRM_WINDOW"] = "1.2"
    harness.env["HUD_STUB_SLEEP"] = "2"

    def insert_first_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="first ready window")

    harness.run("route", "dji-save", "save")
    first_worker = threading.Thread(target=insert_first_transcript)
    first_worker.start()
    first_proc = harness.popen("route", "dji-watch", "watch")
    assert _wait_for_log_text(harness, "watch gui content_settled", timeout=1.0)
    first_worker.join(timeout=1)

    time.sleep(0.4)

    def insert_second_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="second ready window")

    prior_ready_windows = harness.log_text().count("watch gui content_settled")
    harness.run("route", "fn-save", "save")
    second_worker = threading.Thread(target=insert_second_transcript)
    second_worker.start()
    second_proc = harness.popen("route", "fn-watch", "watch")
    assert _wait_for_condition(
        lambda: harness.log_text().count("watch gui content_settled") >= prior_ready_windows + 1,
        timeout=1.0,
    )
    second_worker.join(timeout=1)

    ready_hud_pid = harness.read_state("ready_hud.pid")
    assert ready_hud_pid != ""

    time.sleep(0.7)

    assert harness.read_state("ready_hud.pid") == ready_hud_pid
    harness.run("confirm")

    try:
        first_stdout, first_stderr = first_proc.communicate(timeout=1)
        second_stdout, second_stderr = second_proc.communicate(timeout=1)
    finally:
        if first_proc.poll() is None:
            first_proc.kill()
            first_proc.communicate(timeout=1)
        if second_proc.poll() is None:
            second_proc.kill()
            second_proc.communicate(timeout=1)

    assert first_proc.returncode in (0, -9), (first_stdout, first_stderr)
    assert second_proc.returncode in (0, -9), (second_stdout, second_stderr)
    log_text = harness.log_text()
    assert "branch_hit dji-watch" in log_text
    assert "branch_hit dji-save" in log_text
    assert "branch_hit fn-watch" in log_text
    assert "branch_hit fn-save" in log_text


def test_preconfirm_immediate_send_stops_tmux_watcher_before_window_expiry(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.googlecode.iterm2"
    harness.env["FAKE_ITERM_WINDOW"] = "↣ test"
    harness.env["CONFIRM_WINDOW"] = "1.0"
    row = harness.insert_history(status="", refined_text="")
    harness.run("save")

    def publish_transcript():
        time.sleep(0.05)
        harness.update_history(
            row.rowid,
            status="transcript",
            updated_at=iso_timestamp(),
            refined_text="ready now",
        )

    worker = threading.Thread(target=publish_transcript)
    worker.start()
    proc = harness.popen("watch")
    assert _wait_for_log_text(harness, "watch tmux transcript_detected", timeout=1.0)

    harness.run("preconfirm")

    stdout, stderr = proc.communicate(timeout=0.3)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    log_text = harness.log_text()
    assert "preconfirm tmux send_enter pane=%1" in log_text
    assert "watch tmux window_expired" not in log_text


def test_watch_gui_uses_configured_sound_and_can_disable_ready_hud(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=0,
    )
    harness.run("save")

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="configured sound")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert harness.afplay_calls() == []
    assert harness.hud_calls() == []


def test_watch_gui_ready_feedback_is_visual_only(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )
    harness.run("save")

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="no ready sound")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert harness.afplay_calls() == []


def test_watch_gui_ready_feedback_shows_send_window_hud_when_enabled(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )
    harness.run("save")

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="ready without preconfirm")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert harness.afplay_calls() == []
    assert any(_is_send_window_hud_call(call) for call in _visible_send_window_hud_calls(harness))
    assert _visible_send_window_hud_calls(harness) == [harness.env["CONFIRM_WINDOW"]]
    assert harness.swiftc_calls() != []


def test_open_window_shows_ready_hud_before_watch_and_watch_reuses_it(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("save")
    harness.run("open-window")

    first_deadline = harness.read_state("window_deadline")
    assert first_deadline != ""
    assert _visible_send_window_hud_calls(harness) == [harness.env["CONFIRM_WINDOW"]]
    assert "command hide" not in harness.hud_calls()

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="reuse existing send window")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert _visible_send_window_hud_calls(harness) == [harness.env["CONFIRM_WINDOW"]]
    assert "watch gui send_window_reused" in harness.log_text()


def test_save_reuses_existing_hud_daemon_without_restart(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("save")
    daemon_calls = [call for call in _wait_for_hud_warmup(harness, timeout=3.0) if call.startswith("--daemon ")]
    first_daemon_pid = harness.read_state("send-window-hud.pid")

    harness.run("save")

    assert [call for call in _warmup_hud_calls(harness) if call.startswith("--daemon ")] == daemon_calls
    assert harness.read_state("send-window-hud.pid") == first_daemon_pid


def test_save_prepares_ready_hud_before_watch_to_avoid_cold_start_delay(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["SWIFTC_STUB_SLEEP"] = "0.2"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("save")
    compile_count_after_save = len(harness.swiftc_calls())
    hud_source = (harness.state_dir / "send-window-hud.swift").read_text(encoding="utf-8")
    assert any(call.startswith("--daemon ") for call in _wait_for_hud_warmup(harness))

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="first message should still show hud")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert compile_count_after_save == 1
    assert len(harness.swiftc_calls()) == compile_count_after_save
    assert "Press to send" in hud_source
    assert "progressFillLayer" in hud_source
    assert "alpha: 0.25" in hud_source
    assert any(_is_send_window_hud_call(call) for call in _visible_send_window_hud_calls(harness))


def test_watch_uses_prepared_hud_binary_without_requiring_swiftc(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("save")
    compile_count_after_save = len(harness.swiftc_calls())
    harness.env["SWIFTC_BIN"] = ""

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="prepared binary should show immediately")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert compile_count_after_save == 1
    assert len(harness.swiftc_calls()) == compile_count_after_save
    assert any(call.startswith("--daemon ") for call in _wait_for_hud_warmup(harness))
    assert any(_is_send_window_hud_call(call) for call in _visible_send_window_hud_calls(harness))


def test_watch_rebuilds_hud_when_binary_cache_is_missing(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.env["SWIFTC_STUB_SLEEP"] = "0"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("save")
    compile_count_after_save = len(harness.swiftc_calls())
    (harness.state_dir / "send-window-hud").unlink()

    def insert_transcript():
        time.sleep(0.05)
        harness.insert_history(status="transcript", refined_text="rebuild missing hud binary")

    worker = threading.Thread(target=insert_transcript)
    worker.start()
    proc = harness.popen("watch")
    stdout, stderr = proc.communicate(timeout=2)
    worker.join(timeout=1)

    assert proc.returncode == 0, (stdout, stderr)
    assert len(harness.swiftc_calls()) == compile_count_after_save + 1
    assert any(_is_send_window_hud_call(call) for call in _visible_send_window_hud_calls(harness))


def test_preconfirm_plays_sound_but_does_not_show_ready_hud(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("preconfirm")

    assert any("Sosumi.aiff" in call for call in harness.afplay_calls())
    assert harness.hud_calls() == []


def test_preconfirm_skips_sound_when_preconfirm_sound_is_disabled(harness):
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("preconfirm")

    assert harness.afplay_calls() == []


def test_confirm_plays_feedback_sound(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.write_app_config(
        DJI_ENABLE_AUDIO_FEEDBACK=1,
        DJI_PRECONFIRM_SOUND_NAME="Sosumi",
        DJI_ENABLE_READY_HUD=1,
    )

    harness.run("save")
    harness.run("confirm")

    assert any("Sosumi.aiff" in call for call in harness.afplay_calls())
    assert "confirm gui send_enter" in harness.log_text()


def test_preconfirm_sends_immediately_when_transcript_is_already_ready_in_gui(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.google.Chrome"
    harness.run("save")
    harness.insert_history(status="transcript", refined_text="ready now")

    harness.run("preconfirm")

    log_text = harness.log_text()
    assert "preconfirm gui send_enter" in log_text
    assert harness.read_state("mode") == ""
    calls = harness.osascript_calls()
    assert any(
        "keystroke return" in " ".join(call["args"])
        or "write text" in " ".join(call["args"])
        for call in calls
    )


def test_preconfirm_sends_immediately_when_transcript_is_already_ready_in_tmux(harness):
    harness.env["FAKE_FRONT_BUNDLE"] = "com.googlecode.iterm2"
    harness.env["FAKE_ITERM_WINDOW"] = "↣ test"
    harness.run("save")
    harness.insert_history(status="transcript", refined_text="ready now")

    harness.run("preconfirm")

    log_text = harness.log_text()
    assert "preconfirm tmux send_enter pane=%1" in log_text
    assert harness.read_state("mode") == ""
    assert any("send-keys -t %1 Enter" in call for call in harness.tmux_calls())


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
    ready_hud = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    harness.write_state("ready_hud.pid", str(ready_hud.pid))

    try:
        harness.run("confirm")
        ready_hud.wait(timeout=1)
    finally:
        if ready_hud.poll() is None:
            ready_hud.kill()
            ready_hud.wait(timeout=1)

    log_text = harness.log_text()
    assert "confirm gui send_enter" in log_text
    assert harness.read_state("mode") == ""
    assert harness.read_state("ready_hud.pid") == ""
    calls = harness.osascript_calls()
    assert any(
        "keystroke return" in " ".join(call["args"])
        or "write text" in " ".join(call["args"])
        for call in calls
    )
