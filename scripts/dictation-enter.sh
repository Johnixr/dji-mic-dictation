#!/bin/bash
# DJI MIC MINI dictation helper — tmux + GUI mode
#
# Usage (called by Karabiner):
#   dictation-enter.sh save       — 1st press: detect mode (tmux or gui)
#   dictation-enter.sh watch      — 2nd press: poll for content change
#   dictation-enter.sh preconfirm — press during transcription: queue send on arrival
#   dictation-enter.sh confirm    — press after content settled: send Enter now
#
# tmux mode: poll capture-pane, send via send-keys
# gui mode:  poll Typeless DB, send via osascript keystroke return

STATE_DIR="${STATE_DIR:-/tmp/dji-dictation}"
LOG="${LOG:-$STATE_DIR/debug.log}"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)}"
KCLI="${KCLI:-/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli}"
TYPELESS_DB="${TYPELESS_DB:-$HOME/Library/Application Support/Typeless/typeless.db}"
CONFIRM_WINDOW="${CONFIRM_WINDOW:-4}"
PRECONFIRM_GRACE_INTERVAL="${PRECONFIRM_GRACE_INTERVAL:-0.02}"
PRECONFIRM_GRACE_POLLS="${PRECONFIRM_GRACE_POLLS:-4}"
DELIVERY_DELAY="${DELIVERY_DELAY:-0.05}"
WATCH_POLL_INTERVAL="${WATCH_POLL_INTERVAL:-0.1}"
WATCH_MAX_POLLS="${WATCH_MAX_POLLS:-300}"
WATCH_STATE_READY_INTERVAL="${WATCH_STATE_READY_INTERVAL:-0.01}"
WATCH_STATE_READY_POLLS="${WATCH_STATE_READY_POLLS:-20}"
WATCHER_STOP_INTERVAL="${WATCHER_STOP_INTERVAL:-0.01}"
WATCHER_STOP_POLLS="${WATCHER_STOP_POLLS:-20}"
NO_RECORD_LOG_AFTER_POLLS="${NO_RECORD_LOG_AFTER_POLLS:-100}"
NO_RECORD_LOG_LABEL="${NO_RECORD_LOG_LABEL:-10s}"
STALE_CHECK_EVERY_POLLS="${STALE_CHECK_EVERY_POLLS:-50}"
STALE_SECONDS="${STALE_SECONDS:-5}"
PYTHON3_BIN="${PYTHON3_BIN:-$(command -v python3 2>/dev/null)}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-/usr/bin/osascript}"
AFPLAY_BIN="${AFPLAY_BIN:-/usr/bin/afplay}"
SWIFTC_BIN="${SWIFTC_BIN:-$(command -v swiftc 2>/dev/null)}"
DJI_CONFIG_DIR="${DJI_CONFIG_DIR:-$HOME/.config/dji-mic-dictation}"
DJI_CONFIG_FILE="${DJI_CONFIG_FILE:-$DJI_CONFIG_DIR/config.env}"
DJI_ENABLE_AUDIO_FEEDBACK="${DJI_ENABLE_AUDIO_FEEDBACK:-1}"
DJI_PRECONFIRM_SOUND_NAME="${DJI_PRECONFIRM_SOUND_NAME:-Sosumi}"
DJI_ENABLE_READY_HUD="${DJI_ENABLE_READY_HUD:-1}"
HUD_SWIFT_SOURCE="${HUD_SWIFT_SOURCE:-$STATE_DIR/send-window-hud.swift}"
HUD_BIN="${HUD_BIN:-$STATE_DIR/send-window-hud}"
HUD_DAEMON_PID_FILE="${HUD_DAEMON_PID_FILE:-$STATE_DIR/send-window-hud.pid}"
HUD_DAEMON_COMMAND_FILE="${HUD_DAEMON_COMMAND_FILE:-$STATE_DIR/send-window-hud.command}"
HUD_DAEMON_READY_FILE="${HUD_DAEMON_READY_FILE:-$STATE_DIR/send-window-hud.ready}"
HUD_DAEMON_READY_INTERVAL="${HUD_DAEMON_READY_INTERVAL:-0.01}"
HUD_DAEMON_READY_POLLS="${HUD_DAEMON_READY_POLLS:-50}"

/bin/mkdir -p "$STATE_DIR"

load_optional_config() {
	[ -f "$DJI_CONFIG_FILE" ] || return 0
	# shellcheck disable=SC1090
	. "$DJI_CONFIG_FILE"
}

normalize_toggle() {
	case "${1:-}" in
	1 | true | TRUE | yes | YES | on | ON) echo 1 ;;
	0 | false | FALSE | no | NO | off | OFF) echo 0 ;;
	*) echo "$2" ;;
	esac
}

normalize_sound_name() {
	case "${1:-}" in
	'' | off | OFF | none | NONE) echo '' ;;
	*.aiff) echo "${1%.aiff}" ;;
	*.AIFF) echo "${1%.AIFF}" ;;
	*) echo "$1" ;;
	esac
}

play_feedback_sound() {
	local sound_name="$1"
	[ "$DJI_ENABLE_AUDIO_FEEDBACK" = "1" ] || return 0
	[ -n "$sound_name" ] || return 0
	"$AFPLAY_BIN" -v 0.3 "/System/Library/Sounds/${sound_name}.aiff" &
}

dismiss_ready_hud() {
	local expected_session_id="${1:-}"
	local pid
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	pid="$(read_file ready_hud.pid)"
	if hud_daemon_is_running; then
		[ -n "$pid" ] || return 0
		send_hud_daemon_command hide >/dev/null 2>&1 || true
		/bin/rm -f "$STATE_DIR/ready_hud.pid"
		return 0
	fi
	[ -n "$pid" ] && /bin/kill "$pid" 2>/dev/null
	/bin/rm -f "$STATE_DIR/ready_hud.pid"
}

write_send_window_hud_source() {
	local output_path="$1"
	cat >"$output_path" <<'SWIFT'
import AppKit
import Foundation
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
	let duration: TimeInterval
	let warmup: Bool
	let daemon: Bool
	let controlPath: String?
	let readyPath: String?
	let width: CGFloat = 132
	let height: CGFloat = 34
	let cornerRadius: CGFloat = 17
	let fillBleed: CGFloat = 1.0
	var panel: NSPanel?
	var progressFillLayer: CALayer?
	var hideWorkItem: DispatchWorkItem?
	var signalSource: DispatchSourceSignal?

	init(duration: TimeInterval, warmup: Bool, daemon: Bool, controlPath: String?, readyPath: String?) {
		self.duration = max(0.1, duration)
		self.warmup = warmup
		self.daemon = daemon
		self.controlPath = controlPath
		self.readyPath = readyPath
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.appearance = NSAppearance(named: .darkAqua)
		if warmup {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
				NSApp.terminate(nil)
			}
			return
		}

		if daemon {
			guard let readyPath else {
				NSApp.terminate(nil)
				return
			}
			setupCommandHandler()
			FileManager.default.createFile(atPath: readyPath, contents: Data(), attributes: nil)
			return
		}

		showPanel(duration: duration, terminateOnHide: true)
	}

	func applicationWillTerminate(_ notification: Notification) {
		if let readyPath {
			try? FileManager.default.removeItem(atPath: readyPath)
		}
	}

	func setupCommandHandler() {
		signal(SIGUSR1, SIG_IGN)
		let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
		source.setEventHandler { [weak self] in
			self?.handleCommandSignal()
		}
		source.resume()
		signalSource = source
	}

	func handleCommandSignal() {
		guard let controlPath,
			let command = try? String(contentsOfFile: controlPath, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!command.isEmpty
		else {
			return
		}

		let parts = command.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
		switch parts.first {
		case "show":
			let requestedDuration = TimeInterval(parts.dropFirst().first ?? "") ?? duration
			showPanel(duration: requestedDuration, terminateOnHide: false)
		case "hide":
			hidePanel()
		case "stop":
			hidePanel()
			NSApp.terminate(nil)
		default:
			break
		}
	}

	func showPanel(duration: TimeInterval, terminateOnHide: Bool) {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		hidePanel()

		let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]

		let panel = NSPanel(
			contentRect: NSRect(x: 0, y: 0, width: width, height: height),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.level = .statusBar
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

		let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
		view.wantsLayer = true
		view.layer?.backgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: 1).cgColor
		view.layer?.cornerRadius = cornerRadius
		view.layer?.borderWidth = 1
		view.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
		view.layer?.masksToBounds = true
		panel.contentView = view

		let fillColor = NSColor(red: 242/255, green: 241/255, blue: 240/255, alpha: 0.25)
		let textColor = NSColor(red: 242/255, green: 241/255, blue: 240/255, alpha: 0.56)

		let progressFillLayer = CALayer()
		progressFillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
		progressFillLayer.position = CGPoint(x: -fillBleed, y: height / 2)
		progressFillLayer.bounds = NSRect(x: 0, y: 0, width: 0, height: height + fillBleed * 2)
		progressFillLayer.backgroundColor = fillColor.cgColor
		view.layer?.addSublayer(progressFillLayer)
		self.progressFillLayer = progressFillLayer

		let label = NSTextField(labelWithString: "Press to send")
		label.textColor = textColor
		label.font = .systemFont(ofSize: 13, weight: .regular)
		label.alignment = .center
		label.isBezeled = false
		label.isBordered = false
		label.drawsBackground = false
		label.isEditable = false
		label.isSelectable = false
		label.frame = NSRect(x: 0, y: 8, width: width, height: 18)
		view.addSubview(label)

		let visible = screen.visibleFrame
		panel.setFrameOrigin(NSPoint(
			x: visible.origin.x + round((visible.size.width - width) / 2),
			y: visible.origin.y + 50
		))
		panel.orderFrontRegardless()
		self.panel = panel

		startProgressAnimation(duration: duration)
		let workItem = DispatchWorkItem { [weak self] in
			self?.hidePanel()
			if terminateOnHide {
				NSApp.terminate(nil)
			}
		}
		hideWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
	}

	func hidePanel() {
		progressFillLayer?.removeAllAnimations()
		progressFillLayer = nil
		panel?.orderOut(nil)
		panel?.close()
		panel = nil
	}

	func startProgressAnimation(duration: TimeInterval) {
		let maxFillWidth = width + fillBleed
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		progressFillLayer?.bounds = NSRect(x: 0, y: 0, width: maxFillWidth, height: height + fillBleed * 2)
		CATransaction.commit()

		let animation = CABasicAnimation(keyPath: "bounds.size.width")
		animation.fromValue = 0
		animation.toValue = maxFillWidth
		animation.duration = duration
		animation.timingFunction = CAMediaTimingFunction(name: .linear)
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		progressFillLayer?.add(animation, forKey: "progress")
	}
}

let arguments = Array(CommandLine.arguments.dropFirst())
var warmup = false
var daemon = false
var duration: TimeInterval = 3
var controlPath: String?
var readyPath: String?

var index = 0
while index < arguments.count {
	let argument = arguments[index]
	switch argument {
	case "--warmup":
		warmup = true
	case "--daemon":
		daemon = true
		if index + 1 < arguments.count {
			controlPath = arguments[index + 1]
			index += 1
		}
		if index + 1 < arguments.count {
			readyPath = arguments[index + 1]
			index += 1
		}
	default:
		if let parsedDuration = TimeInterval(argument) {
			duration = parsedDuration
		}
	}
	index += 1
}

let app = NSApplication.shared
let delegate = AppDelegate(duration: duration, warmup: warmup, daemon: daemon, controlPath: controlPath, readyPath: readyPath)
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
SWIFT
}

ensure_send_window_hud_binary() {
	[ -n "$SWIFTC_BIN" ] || {
		log "hud compile skipped: swiftc_missing"
		return 1
	}
	local tmp_source
	tmp_source="$STATE_DIR/send-window-hud.$$.swift.tmp"
	write_send_window_hud_source "$tmp_source"
	if [ ! -f "$HUD_SWIFT_SOURCE" ] || ! cmp -s "$tmp_source" "$HUD_SWIFT_SOURCE"; then
		/bin/mv "$tmp_source" "$HUD_SWIFT_SOURCE"
	else
		/bin/rm -f "$tmp_source"
	fi
	if [ ! -x "$HUD_BIN" ] || [ "$HUD_SWIFT_SOURCE" -nt "$HUD_BIN" ]; then
		local tmp_bin
		tmp_bin="$STATE_DIR/send-window-hud.$$.tmp"
		"$SWIFTC_BIN" "$HUD_SWIFT_SOURCE" -o "$tmp_bin" >/dev/null 2>&1 || {
			log "hud compile failed"
			/bin/rm -f "$tmp_bin" "$HUD_BIN"
			return 1
		}
		/bin/chmod +x "$tmp_bin"
		/bin/mv "$tmp_bin" "$HUD_BIN"
	fi
	[ -x "$HUD_BIN" ]
}

stop_send_window_hud_daemon() {
	local pid
	pid="$(hud_daemon_pid)"
	if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
		write_path_file "$HUD_DAEMON_COMMAND_FILE" stop
		/bin/kill -USR1 "$pid" 2>/dev/null
		if ! wait_for_process_exit "$pid" "$HUD_DAEMON_READY_POLLS" "$HUD_DAEMON_READY_INTERVAL"; then
			/bin/kill -9 "$pid" 2>/dev/null
			wait_for_process_exit "$pid" 5 "$HUD_DAEMON_READY_INTERVAL" >/dev/null 2>&1
		fi
	fi
	/bin/rm -f "$HUD_DAEMON_PID_FILE" "$HUD_DAEMON_COMMAND_FILE" "$HUD_DAEMON_READY_FILE"
}

start_send_window_hud_daemon() {
	[ -x "$HUD_BIN" ] || return 1
	stop_send_window_hud_daemon
	"$HUD_BIN" --daemon "$HUD_DAEMON_COMMAND_FILE" "$HUD_DAEMON_READY_FILE" >/dev/null 2>&1 &
	write_path_file "$HUD_DAEMON_PID_FILE" "$!"
	if ! wait_for_path "$HUD_DAEMON_READY_FILE"; then
		stop_send_window_hud_daemon
		log "hud daemon start failed"
		return 1
	fi
	log "hud daemon started pid=$(hud_daemon_pid)"
	return 0
}

ensure_send_window_hud_daemon() {
	hud_daemon_is_running && [ -f "$HUD_DAEMON_READY_FILE" ] && return 0
	start_send_window_hud_daemon
}

send_hud_daemon_command() {
	local command="$1"
	local pid
	ensure_send_window_hud_daemon || return 1
	pid="$(hud_daemon_pid)"
	[ -n "$pid" ] || return 1
	write_path_file "$HUD_DAEMON_COMMAND_FILE" "$command"
	/bin/kill -USR1 "$pid" 2>/dev/null
}

warmup_send_window_hud() {
	[ -x "$HUD_BIN" ] || return 0
	ensure_send_window_hud_daemon || return 0
}

prepare_send_window_hud_if_enabled() {
	[ "$DJI_ENABLE_READY_HUD" = "1" ] || return 0
	ensure_send_window_hud_binary || return 0
	warmup_send_window_hud
}

show_send_window_hud() {
	local duration="$1"
	local expected_session_id="${2:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	if [ ! -x "$HUD_BIN" ]; then
		ensure_send_window_hud_binary || {
			log "hud show skipped: binary_missing"
			return 0
		}
	fi
	if send_hud_daemon_command "show|$duration"; then
		write_file ready_hud.pid "$(hud_daemon_pid)"
		return 0
	fi
	stop_send_window_hud_daemon >/dev/null 2>&1 || true
	"$HUD_BIN" "$duration" >/dev/null 2>&1 &
	write_file ready_hud.pid "$!"
}

show_send_window_hud_if_enabled() {
	[ "$DJI_ENABLE_READY_HUD" = "1" ] || return 0
	show_send_window_hud "$1" "$2"
}

load_optional_config
DJI_ENABLE_AUDIO_FEEDBACK="$(normalize_toggle "$DJI_ENABLE_AUDIO_FEEDBACK" 1)"
DJI_PRECONFIRM_SOUND_NAME="$(normalize_sound_name "$DJI_PRECONFIRM_SOUND_NAME")"
DJI_ENABLE_READY_HUD="$(normalize_toggle "$DJI_ENABLE_READY_HUD" 1)"

timestamp() {
	if [ -n "$PYTHON3_BIN" ]; then
		"$PYTHON3_BIN" - <<'PY' 2>/dev/null
import time
t = time.time()
lt = time.localtime(t)
print(time.strftime("%H:%M:%S", lt) + f".{int((t - int(t)) * 1000):03d}")
PY
	else
		/bin/date +%H:%M:%S
	fi
}

utc_timestamp_ms() {
	"$PYTHON3_BIN" -c "from datetime import datetime,timezone;t=datetime.now(timezone.utc);print(t.strftime('%Y-%m-%dT%H:%M:%S.')+f'{t.microsecond//1000:03d}Z')" 2>/dev/null
}

log() { /usr/bin/printf '%s %s\n' "$(timestamp)" "$*" >>"$LOG"; }

read_file() { /bin/cat "$STATE_DIR/$1" 2>/dev/null; }
write_file() { /usr/bin/printf '%s' "$2" >"$STATE_DIR/$1"; }
write_path_file() { /usr/bin/printf '%s' "$2" >"$1"; }

wait_for_path() {
	local path="$1"
	local polls="${2:-$HUD_DAEMON_READY_POLLS}"
	local interval="${3:-$HUD_DAEMON_READY_INTERVAL}"
	local i=0
	while [ $i -lt "$polls" ]; do
		[ -e "$path" ] && return 0
		/bin/sleep "$interval"
		i=$((i + 1))
	done
	return 1
}

hud_daemon_pid() {
	/bin/cat "$HUD_DAEMON_PID_FILE" 2>/dev/null
}

hud_daemon_is_running() {
	local pid
	pid="$(hud_daemon_pid)"
	[ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null
}

generate_session_id() {
	if [ -n "$PYTHON3_BIN" ]; then
		"$PYTHON3_BIN" - <<'PY' 2>/dev/null
import os, time
print(f"{int(time.time() * 1000)}-{os.getpid()}")
PY
	else
		/bin/date +%s
	fi
}

current_session_id() { read_file session_id; }

session_is_current() {
	local expected_session_id="$1"
	[ -n "$expected_session_id" ] || return 1
	[ "$(current_session_id)" = "$expected_session_id" ]
}

wait_for_state_value() {
	local name="$1"
	local polls="${2:-$WATCH_STATE_READY_POLLS}"
	local interval="${3:-$WATCH_STATE_READY_INTERVAL}"
	local value=""
	local i=0
	while [ $i -lt "$polls" ]; do
		value="$(read_file "$name")"
		if [ -n "$value" ]; then
			printf '%s' "$value"
			return 0
		fi
		/bin/sleep "$interval"
		i=$((i + 1))
	done
	return 1
}

wait_for_process_exit() {
	local pid="$1"
	local polls="${2:-$WATCHER_STOP_POLLS}"
	local interval="${3:-$WATCHER_STOP_INTERVAL}"
	local i=0
	while [ $i -lt "$polls" ]; do
		/bin/kill -0 "$pid" 2>/dev/null || return 0
		/bin/sleep "$interval"
		i=$((i + 1))
	done
	/bin/kill -0 "$pid" 2>/dev/null && return 1
	return 0
}

kill_old_watcher() {
	local pid
	pid="$(read_file watcher.pid)"
	if [ -n "$pid" ]; then
		/bin/kill "$pid" 2>/dev/null
		if ! wait_for_process_exit "$pid"; then
			/bin/kill -9 "$pid" 2>/dev/null
			wait_for_process_exit "$pid" 5 "$WATCHER_STOP_INTERVAL" >/dev/null 2>&1
		fi
	fi
	/bin/rm -f "$STATE_DIR/watcher.pid"
}

cleanup() {
	local expected_session_id="${1:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	/bin/rm -f "$STATE_DIR"/{mode,pane_id,watcher.pid,pending_confirm,save_ts,db_anchor_rowid,db_anchor_updated_at,ready_hud.pid,session_id,window_deadline}
}

set_vars() { "$KCLI" --set-variables "$1" 2>/dev/null; }

clear_watch_state() {
	local expected_session_id="${1:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	set_vars '{"dji_watching":0,"dji_ready_to_send":0}'
}

window_deadline_timestamp() {
	local duration="$1"
	if [ -n "$PYTHON3_BIN" ]; then
		WINDOW_DURATION="$duration" "$PYTHON3_BIN" - <<'PY' 2>/dev/null
import os, time
duration = float(os.environ.get('WINDOW_DURATION', '0'))
print(f"{time.time() + max(0.0, duration):.3f}")
PY
	else
		/bin/date +%s
	fi
}

remaining_deadline_seconds() {
	local deadline="$1"
	if [ -n "$PYTHON3_BIN" ]; then
		WINDOW_DEADLINE="$deadline" "$PYTHON3_BIN" - <<'PY' 2>/dev/null
import os, time
deadline = float(os.environ.get('WINDOW_DEADLINE', '0') or 0)
print(f"{max(0.0, deadline - time.time()):.3f}")
PY
	else
		echo 0
	fi
}

deadline_has_remaining() {
	local deadline="$1"
	local remaining
	remaining="$(remaining_deadline_seconds "$deadline")"
	awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'
}

sleep_until_deadline() {
	local deadline="$1"
	local remaining
	remaining="$(remaining_deadline_seconds "$deadline")"
	if awk -v remaining="$remaining" 'BEGIN { exit !(remaining > 0) }'; then
		/bin/sleep "$remaining"
	fi
}

open_send_window() {
	local log_label="$1"
	local expected_session_id="${2:-}"
	local deadline
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	show_send_window_hud_if_enabled "$CONFIRM_WINDOW" "$expected_session_id"
	deadline="$(window_deadline_timestamp "$CONFIRM_WINDOW")"
	write_file window_deadline "$deadline"
	log "${log_label} send_window_started window=${CONFIRM_WINDOW}s deadline=${deadline}"
	printf '%s' "$deadline"
}

reuse_or_open_send_window() {
	local log_label="$1"
	local expected_session_id="${2:-}"
	local deadline
	deadline="$(read_file window_deadline)"
	if [ -n "$deadline" ] && deadline_has_remaining "$deadline"; then
		log "${log_label} send_window_reused window=${CONFIRM_WINDOW}s deadline=${deadline}"
		printf '%s' "$deadline"
		return 0
	fi
	open_send_window "$log_label" "$expected_session_id"
}

expire_send_window() {
	local mode="$1"
	local keep_watcher="${2:-0}"
	local expected_session_id="${3:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	/bin/rm -f "$STATE_DIR/window_deadline"
	set_vars '{"dji_watching":0,"dji_ready_to_send":0}'
	log "watch ${mode} window_expired"
	if [ "$keep_watcher" != "1" ]; then
		/bin/rm -f "$STATE_DIR/watcher.pid"
	fi
}

enter_ready_window() {
	local mode="$1"
	local deadline="$2"
	local polls="$3"
	local grace_polls="${4:-0}"
	local expected_session_id="${5:-}"
	local remaining_window
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	remaining_window="$(remaining_deadline_seconds "$deadline")"
	if ! awk -v remaining="$remaining_window" 'BEGIN { exit !(remaining > 0) }'; then
		expire_send_window "$mode" 0 "$expected_session_id"
		return
	fi
	set_vars '{"dji_watching":0,"dji_ready_to_send":1}'
	log "watch ${mode} content_settled (${polls} polls ~$((polls / 10))s grace_polls=${grace_polls}) remaining=${remaining_window}s"
	sleep_until_deadline "$deadline"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	set_vars '{"dji_ready_to_send":0}'
	expire_send_window "$mode" 0 "$expected_session_id"
}

wait_for_pending_confirm() {
	pending_confirm_polls=0
	while [ $pending_confirm_polls -lt "$PRECONFIRM_GRACE_POLLS" ]; do
		[ -f "$STATE_DIR/pending_confirm" ] && return 0
		/bin/sleep "$PRECONFIRM_GRACE_INTERVAL"
		pending_confirm_polls=$((pending_confirm_polls + 1))
	done
	[ -f "$STATE_DIR/pending_confirm" ]
}

active_tmux_pane() {
	$TMUX_BIN list-panes -a \
		-F '#{session_attached} #{window_active} #{pane_active} #{pane_id}' 2>/dev/null |
		awk '$1==1 && $2==1 && $3==1 {print $4; exit}'
}

typeless_last_rowid() {
	sqlite3 "$TYPELESS_DB" "SELECT COALESCE(MAX(rowid), 0) FROM history;" 2>/dev/null
}

typeless_row_updated_at() {
	local rowid="$1"
	sqlite3 "$TYPELESS_DB" \
		"SELECT COALESCE(updated_at, '') FROM history WHERE rowid = ${rowid:-0} LIMIT 1;" 2>/dev/null
}

typeless_check_done() {
	local anchor_rowid="$1"
	local anchor_updated_at="$2"
	sqlite3 "$TYPELESS_DB" \
		"SELECT status FROM history WHERE (rowid > ${anchor_rowid:-0} OR (rowid = ${anchor_rowid:-0} AND COALESCE(updated_at, '') > '${anchor_updated_at}')) AND status IN ('transcript','dismissed') ORDER BY rowid ASC LIMIT 1;" 2>/dev/null
}

typeless_has_record() {
	local anchor_rowid="$1"
	local anchor_updated_at="$2"
	sqlite3 "$TYPELESS_DB" \
		"SELECT 1 FROM history WHERE rowid > ${anchor_rowid:-0} OR (rowid = ${anchor_rowid:-0} AND COALESCE(updated_at, '') > '${anchor_updated_at}') LIMIT 1;" 2>/dev/null
}

typeless_check_stale() {
	local anchor_rowid="$1"
	local anchor_updated_at="$2"
	local stale_seconds="$STALE_SECONDS"
	sqlite3 "$TYPELESS_DB" \
		"SELECT 1 FROM history WHERE (rowid > ${anchor_rowid:-0} OR (rowid = ${anchor_rowid:-0} AND COALESCE(updated_at, '') > '${anchor_updated_at}')) AND COALESCE(status, '') = '' AND (julianday('now') - julianday(updated_at)) * 86400 > $stale_seconds LIMIT 1;" 2>/dev/null
}

gui_send_enter() {
	local bundle
	bundle="$("$OSASCRIPT_BIN" -e \
		'tell application "System Events"
			set bid to bundle identifier of first application process whose frontmost is true
			if bid is not "com.googlecode.iterm2" then keystroke return
			return bid
		end tell' 2>/dev/null)"
	if [ "$bundle" = "com.googlecode.iterm2" ]; then
		"$OSASCRIPT_BIN" -e \
			'tell application "iTerm2" to tell current window to tell current session to write text ""' 2>/dev/null
	fi
	log "gui_send_enter: $bundle"
}

transcript_ready_since_save() {
	[ -f "$STATE_DIR/save_ts" ] || return 1
	local anchor_rowid
	local anchor_updated_at
	local done_status
	anchor_rowid="$(read_file db_anchor_rowid)"
	[ -n "$anchor_rowid" ] || anchor_rowid=0
	anchor_updated_at="$(read_file db_anchor_updated_at)"
	done_status="$(typeless_check_done "$anchor_rowid" "$anchor_updated_at")"
	[ "$done_status" = "transcript" ]
}

send_current_mode_enter() {
	local source="$1"
	local mode
	local pane
	mode="$(read_file mode)"
	if [ "$mode" = "tmux" ]; then
		pane="$(read_file pane_id)"
		if [ -n "$pane" ]; then
			$TMUX_BIN send-keys -t "$pane" Enter 2>/dev/null
			log "$source tmux send_enter pane=${pane}"
			return 0
		fi
		log "$source tmux no_pane"
		return 1
	elif [ "$mode" = "gui" ]; then
		gui_send_enter
		log "$source gui send_enter"
		return 0
	fi
	log "$source unknown mode"
	return 1
}

if [ "$1" = "route" ]; then
	branch="$2"
	action="$3"
	shift 3
	log "branch_hit $branch"
	set -- "$action" "$@"
fi

case "$1" in
save)
	kill_old_watcher
	set_vars '{"dji_ready_to_send":0,"dji_watching":0}'
	cleanup
	save_ts="$(utc_timestamp_ms)"
	[ -n "$save_ts" ] || save_ts="$(/bin/date -u +%Y-%m-%dT%H:%M:%S.000Z)"
	anchor_rowid="$(typeless_last_rowid)"
	[ -n "$anchor_rowid" ] || anchor_rowid=0
	anchor_updated_at="$(typeless_row_updated_at "$anchor_rowid")"
	session_id="$(generate_session_id)"
	[ -n "$session_id" ] || session_id="$$-$(/bin/date +%s)"
	write_file save_ts "$save_ts"
	write_file db_anchor_rowid "$anchor_rowid"
	write_file db_anchor_updated_at "$anchor_updated_at"
	write_file session_id "$session_id"

	front_bundle="$("$OSASCRIPT_BIN" -e \
		'tell application "System Events" to return bundle identifier of first application process whose frontmost is true' 2>/dev/null)"

	pane=""
	case "$front_bundle" in
	com.googlecode.iterm2)
		iterm_win="$("$OSASCRIPT_BIN" -e 'tell app "iTerm" to name of current window' 2>/dev/null)"
		case "$iterm_win" in
		"↣"*) pane="$(active_tmux_pane)" ;;
		esac
		;;
	net.kovidgoyal.kitty | io.alacritty | com.apple.Terminal)
		pane="$(active_tmux_pane)"
		;;
	esac

	if [ -n "$pane" ]; then
		write_file mode tmux
		write_file pane_id "$pane"
		log "save mode=tmux pane=${pane} app=${front_bundle} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at}"
	else
		write_file mode gui
		log "save mode=gui app=${front_bundle} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at}"
	fi
	prepare_send_window_hud_if_enabled
	;;

watch)
	kill_old_watcher
	set_vars '{"dji_ready_to_send":0}'
	watch_session_id="$(wait_for_state_value session_id)"
	trap 'clear_watch_state "$watch_session_id"' EXIT
	trap 'clear_watch_state "$watch_session_id"; exit 0' TERM INT

	mode="$(wait_for_state_value mode)"
	write_file watcher.pid "$$"

	if [ "$mode" = "tmux" ]; then
		pane="$(wait_for_state_value pane_id)"
		[ -n "$pane" ] || {
			cleanup "$watch_session_id"
			exit 0
		}
		save_ts="$(read_file save_ts)"
		anchor_rowid="$(read_file db_anchor_rowid)"
		anchor_updated_at="$(read_file db_anchor_updated_at)"
		[ -n "$anchor_rowid" ] || anchor_rowid=0
		log "watch mode=tmux pane=${pane} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at} polling"
		window_deadline="$(reuse_or_open_send_window "watch tmux" "$watch_session_id")"

		changed=0 i=0 done_status="" has_record=0
		while [ $i -lt "$WATCH_MAX_POLLS" ]; do
			session_is_current "$watch_session_id" || exit 0
			/bin/sleep "$WATCH_POLL_INTERVAL"
			i=$((i + 1))
			session_is_current "$watch_session_id" || exit 0
			done_status="$(typeless_check_done "$anchor_rowid" "$anchor_updated_at")"
			if [ -n "$done_status" ]; then
				changed=1 && break
			fi
			if [ $has_record -eq 0 ] && [ -n "$(typeless_has_record "$anchor_rowid" "$anchor_updated_at")" ]; then
				has_record=1
				log "watch tmux record_detected (${i} polls ~$((i / 10))s)"
			elif [ $has_record -eq 0 ] && [ $i -eq "$NO_RECORD_LOG_AFTER_POLLS" ]; then
				log "watch tmux still_no_record_after_${NO_RECORD_LOG_LABEL}"
			fi
			if [ $has_record -eq 1 ] && [ $((i % STALE_CHECK_EVERY_POLLS)) -eq 0 ]; then
				if [ -n "$(typeless_check_stale "$anchor_rowid" "$anchor_updated_at")" ]; then
					log "watch tmux stale_record (${i} polls ~$((i / 10))s), abort"
					clear_watch_state "$watch_session_id"
					/bin/rm -f "$STATE_DIR/watcher.pid"
					exit 0
				fi
			fi
			if ! deadline_has_remaining "$window_deadline"; then
				expire_send_window tmux 0 "$watch_session_id"
				exit 0
			fi
		done

		if [ $changed -eq 1 ] && [ "$done_status" = "transcript" ]; then
			session_is_current "$watch_session_id" || exit 0
			if ! deadline_has_remaining "$window_deadline"; then
				expire_send_window tmux 0 "$watch_session_id"
				exit 0
			fi
			log "watch tmux transcript_detected (${i} polls ~$((i / 10))s) grace_window=${PRECONFIRM_GRACE_POLLS}x${PRECONFIRM_GRACE_INTERVAL}s"
			if wait_for_pending_confirm; then
				session_is_current "$watch_session_id" || exit 0
				if ! deadline_has_remaining "$window_deadline"; then
					expire_send_window tmux 0 "$watch_session_id"
					exit 0
				fi
				/bin/sleep "$DELIVERY_DELAY"
				$TMUX_BIN send-keys -t "$pane" Enter 2>/dev/null
				clear_watch_state "$watch_session_id"
				log "watch tmux preconfirm_send (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s)"
				cleanup "$watch_session_id"
			else
				enter_ready_window tmux "$window_deadline" "$i" "$pending_confirm_polls" "$watch_session_id"
			fi
		elif [ $changed -eq 1 ] && [ "$done_status" = "dismissed" ]; then
			clear_watch_state "$watch_session_id"
			log "watch tmux dismissed (${i} polls ~$((i / 10))s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		else
			clear_watch_state "$watch_session_id"
			log "watch tmux no_change (timeout 30s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		fi

	elif [ "$mode" = "gui" ]; then
		save_ts="$(read_file save_ts)"
		anchor_rowid="$(read_file db_anchor_rowid)"
		anchor_updated_at="$(read_file db_anchor_updated_at)"
		[ -n "$anchor_rowid" ] || anchor_rowid=0
		log "watch mode=gui save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at} polling"
		window_deadline="$(reuse_or_open_send_window "watch gui" "$watch_session_id")"

		changed=0 i=0 has_record=0
		while [ $i -lt "$WATCH_MAX_POLLS" ]; do
			session_is_current "$watch_session_id" || exit 0
			/bin/sleep "$WATCH_POLL_INTERVAL"
			i=$((i + 1))
			session_is_current "$watch_session_id" || exit 0
			done_status="$(typeless_check_done "$anchor_rowid" "$anchor_updated_at")"
			if [ -n "$done_status" ]; then
				changed=1 && break
			fi
			if [ $has_record -eq 0 ] && [ -n "$(typeless_has_record "$anchor_rowid" "$anchor_updated_at")" ]; then
				has_record=1
				log "watch gui record_detected (${i} polls ~$((i / 10))s)"
			elif [ $has_record -eq 0 ] && [ $i -eq "$NO_RECORD_LOG_AFTER_POLLS" ]; then
				log "watch gui still_no_record_after_${NO_RECORD_LOG_LABEL}"
			fi
			if [ $has_record -eq 1 ] && [ $((i % STALE_CHECK_EVERY_POLLS)) -eq 0 ]; then
				if [ -n "$(typeless_check_stale "$anchor_rowid" "$anchor_updated_at")" ]; then
					log "watch gui stale_record (${i} polls ~$((i / 10))s), abort"
					clear_watch_state "$watch_session_id"
					/bin/rm -f "$STATE_DIR/watcher.pid"
					exit 0
				fi
			fi
			if ! deadline_has_remaining "$window_deadline"; then
				expire_send_window gui 0 "$watch_session_id"
				exit 0
			fi
		done

		if [ $changed -eq 1 ] && [ "$done_status" = "transcript" ]; then
			session_is_current "$watch_session_id" || exit 0
			if ! deadline_has_remaining "$window_deadline"; then
				expire_send_window gui 0 "$watch_session_id"
				exit 0
			fi
			log "watch gui transcript_detected (${i} polls ~$((i / 10))s) grace_window=${PRECONFIRM_GRACE_POLLS}x${PRECONFIRM_GRACE_INTERVAL}s"
			if wait_for_pending_confirm; then
				session_is_current "$watch_session_id" || exit 0
				if ! deadline_has_remaining "$window_deadline"; then
					expire_send_window gui 0 "$watch_session_id"
					exit 0
				fi
				/bin/sleep "$DELIVERY_DELAY"
				gui_send_enter
				clear_watch_state "$watch_session_id"
				log "watch gui preconfirm_send (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s)"
				cleanup "$watch_session_id"
			else
				enter_ready_window gui "$window_deadline" "$i" "$pending_confirm_polls" "$watch_session_id"
			fi
		elif [ $changed -eq 1 ] && [ "$done_status" = "dismissed" ]; then
			clear_watch_state "$watch_session_id"
			log "watch gui dismissed (${i} polls ~$((i / 10))s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		else
			clear_watch_state "$watch_session_id"
			log "watch gui no_change (timeout 30s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		fi
	else
		log "watch unknown mode, exit"
		/bin/rm -f "$STATE_DIR/watcher.pid"
	fi
	;;

open-window)
	open_window_session_id="$(current_session_id)"
	if [ -z "$open_window_session_id" ]; then
		open_window_session_id="$(wait_for_state_value session_id)"
	fi
	[ -n "$open_window_session_id" ] || exit 0
	reuse_or_open_send_window open_window "$open_window_session_id" >/dev/null
	;;

preconfirm)
	dismiss_ready_hud
	if transcript_ready_since_save; then
		kill_old_watcher
		set_vars '{"dji_ready_to_send":0,"dji_watching":0}'
		send_current_mode_enter preconfirm
		cleanup
	else
		write_file pending_confirm 1
		play_feedback_sound "$DJI_PRECONFIRM_SOUND_NAME"
		log "preconfirm queued"
	fi
	;;

confirm)
	kill_old_watcher
	dismiss_ready_hud
	set_vars '{"dji_ready_to_send":0,"dji_watching":0}'
	send_current_mode_enter confirm
	cleanup
	;;
esac
