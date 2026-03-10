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
CONFIRM_WINDOW="${CONFIRM_WINDOW:-3}"
WAIT_PHASE_DURATION="${WAIT_PHASE_DURATION:-2}"
PRECONFIRM_GRACE_INTERVAL="${PRECONFIRM_GRACE_INTERVAL:-0.02}"
PRECONFIRM_GRACE_POLLS="${PRECONFIRM_GRACE_POLLS:-4}"
DELIVERY_DELAY="${DELIVERY_DELAY:-0.05}"
WATCH_POLL_INTERVAL="${WATCH_POLL_INTERVAL:-0.1}"
WATCH_MAX_POLLS="${WATCH_MAX_POLLS:-300}"
WATCH_STATE_READY_INTERVAL="${WATCH_STATE_READY_INTERVAL:-0.01}"
WATCH_STATE_READY_POLLS="${WATCH_STATE_READY_POLLS:-20}"
SAVE_STATE_READY_POLLS="${SAVE_STATE_READY_POLLS:-300}"
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
DJI_PRECONFIRM_SOUND_NAME="${DJI_PRECONFIRM_SOUND_NAME:-ready}"
DJI_REVIEW_WINDOW_SECONDS="${DJI_REVIEW_WINDOW_SECONDS:-}"
SOUNDS_DIR="${SOUNDS_DIR:-}"
if [ -z "$SOUNDS_DIR" ]; then
	_sd="$(cd "$(dirname "$0")/../sounds" 2>/dev/null && pwd)"
	[ -d "$_sd" ] && SOUNDS_DIR="$_sd" || SOUNDS_DIR="$HOME/.config/dji-mic-dictation/sounds"
fi
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

normalize_duration_seconds() {
	local value="${1:-}"
	local fallback="$2"
	awk -v value="$value" -v fallback="$fallback" 'BEGIN {
		if (value ~ /^[0-9]*\.?[0-9]+$/ && value + 0 > 0) {
			print value
		} else {
			print fallback
		}
	}'
}

play_feedback_sound() {
	local sound_name="$1"
	[ "$DJI_ENABLE_AUDIO_FEEDBACK" = "1" ] || return 0
	[ -n "$sound_name" ] || return 0
	if [ -n "$SOUNDS_DIR" ] && [ -f "$SOUNDS_DIR/${sound_name}.wav" ]; then
		"$AFPLAY_BIN" -v 0.6 "$SOUNDS_DIR/${sound_name}.wav" &
	elif [ -f "/System/Library/Sounds/${sound_name}.aiff" ]; then
		"$AFPLAY_BIN" -v 0.3 "/System/Library/Sounds/${sound_name}.aiff" &
	fi
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
	let waitDuration: TimeInterval
	let confirmDuration: TimeInterval
	let warmup: Bool
	let daemon: Bool
	let controlPath: String?
	let readyPath: String?
	let width: CGFloat = 132
	let height: CGFloat = 34
	let cornerRadius: CGFloat = 17
	let fillBleed: CGFloat = 1.0
	let waitHoldFraction: CGFloat = 0.8
	var panel: NSPanel?
	var progressFillLayer: CALayer?
	var sweepLayer: CAGradientLayer?
	var hideWorkItem: DispatchWorkItem?
	var waitPhaseWorkItem: DispatchWorkItem?
	var signalSource: DispatchSourceSignal?

	init(waitDuration: TimeInterval, confirmDuration: TimeInterval, warmup: Bool, daemon: Bool, controlPath: String?, readyPath: String?) {
		self.waitDuration = max(0, waitDuration)
		self.confirmDuration = max(0.1, confirmDuration)
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

		let shouldAutoHide = waitDuration <= 0
		showPanel(waitDuration: waitDuration, confirmDuration: confirmDuration, terminateOnHide: shouldAutoHide)
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
			let requestedWaitDuration = TimeInterval(parts.count > 1 ? parts[1] : "") ?? waitDuration
			let requestedConfirmDuration = TimeInterval(parts.count > 2 ? parts[2] : "") ?? confirmDuration
			showPanel(waitDuration: requestedWaitDuration, confirmDuration: requestedConfirmDuration, terminateOnHide: false)
		case "confirm":
			let requestedDuration = TimeInterval(parts.count > 1 ? parts[1] : "") ?? confirmDuration
			startConfirmPhase(duration: requestedDuration, terminateOnHide: false)
		case "hide":
			hidePanel()
		case "stop":
			hidePanel()
			NSApp.terminate(nil)
		default:
			break
		}
	}

	func cancelScheduledWork() {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		waitPhaseWorkItem?.cancel()
		waitPhaseWorkItem = nil
	}

	func showPanel(waitDuration: TimeInterval, confirmDuration: TimeInterval, terminateOnHide: Bool) {
		cancelScheduledWork()
		hidePanel()
		preparePanel()

		let normalizedWaitDuration = max(0, waitDuration)
		let normalizedConfirmDuration = max(0.1, confirmDuration)
		if normalizedWaitDuration <= 0 {
			guard terminateOnHide else {
				return
			}
			startConfirmPhase(duration: normalizedConfirmDuration, terminateOnHide: true)
			return
		}

		startWaitPhase(duration: normalizedWaitDuration)
		let workItem = DispatchWorkItem { [weak self] in
			self?.startWaitHoldPhase()
		}
		waitPhaseWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + normalizedWaitDuration, execute: workItem)
	}

	func preparePanel() {
		guard panel == nil else {
			return
		}

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

		let shimmerHost = CALayer()
		shimmerHost.frame = label.frame
		shimmerHost.masksToBounds = true
		let gradientWidth = label.frame.width * 2
		let shimmerWidth = max(30, label.frame.width * 0.3)
		let coreWidth = max(10, shimmerWidth / 3)
		let shimmerHalf = shimmerWidth / gradientWidth / 2
		let coreHalf = coreWidth / gradientWidth / 2

		let shimmerMask = CATextLayer()
		shimmerMask.string = NSAttributedString(
			string: "Press to send",
			attributes: [
				.font: NSFont.systemFont(ofSize: 13, weight: .regular),
				.foregroundColor: NSColor.white,
			]
		)
		shimmerMask.alignmentMode = .center
		shimmerMask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
		shimmerMask.frame = shimmerHost.bounds
		shimmerHost.mask = shimmerMask

		let sweepLayer = CAGradientLayer()
		sweepLayer.colors = [
			NSColor(white: 1, alpha: 0).cgColor,
			NSColor(white: 1, alpha: 0.96).cgColor,
			NSColor(white: 1, alpha: 0.96).cgColor,
			NSColor(white: 1, alpha: 0).cgColor,
		]
		sweepLayer.locations = [
			NSNumber(value: Float(0.5 - shimmerHalf)),
			NSNumber(value: Float(0.5 - coreHalf)),
			NSNumber(value: Float(0.5 + coreHalf)),
			NSNumber(value: Float(0.5 + shimmerHalf)),
		]
		sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
		sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
		sweepLayer.frame = NSRect(x: -label.frame.width / 2, y: 0, width: gradientWidth, height: label.frame.height)
		sweepLayer.opacity = 0
		shimmerHost.addSublayer(sweepLayer)
		view.layer?.addSublayer(shimmerHost)
		self.sweepLayer = sweepLayer

		let visible = screen.visibleFrame
		panel.setFrameOrigin(NSPoint(
			x: visible.origin.x + round((visible.size.width - width) / 2),
			y: visible.origin.y + 50
		))
		panel.orderFrontRegardless()
		self.panel = panel
	}

	func hidePanel() {
		cancelScheduledWork()
		progressFillLayer?.removeAllAnimations()
		sweepLayer?.removeAllAnimations()
		sweepLayer = nil
		progressFillLayer = nil
		panel?.orderOut(nil)
		panel?.close()
		panel = nil
	}

	func progressLayerBounds(width: CGFloat) -> NSRect {
		NSRect(x: 0, y: 0, width: width, height: height + fillBleed * 2)
	}

	func currentFillWidth() -> CGFloat {
		guard let layer = progressFillLayer else {
			return 0
		}
		let sourceLayer = layer.presentation() ?? layer
		return max(0, min(width + fillBleed, sourceLayer.bounds.size.width))
	}

	func animateProgress(to fraction: CGFloat, duration: TimeInterval, timingFunctionName: CAMediaTimingFunctionName) {
		let maxFillWidth = width + fillBleed
		let fromWidth = currentFillWidth()
		let targetWidth = max(0, min(1, fraction)) * maxFillWidth

		progressFillLayer?.removeAnimation(forKey: "progress")
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		progressFillLayer?.bounds = progressLayerBounds(width: targetWidth)
		CATransaction.commit()
		guard duration > 0 else {
			return
		}

		let animation = CABasicAnimation(keyPath: "bounds.size.width")
		animation.fromValue = fromWidth
		animation.toValue = targetWidth
		animation.duration = duration
		animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		progressFillLayer?.add(animation, forKey: "progress")
	}

	func startWaitPhase(duration: TimeInterval) {
		stopSweepAnimation()
		animateProgress(to: waitHoldFraction, duration: duration, timingFunctionName: .easeIn)
	}

	func startWaitHoldPhase() {
		waitPhaseWorkItem?.cancel()
		waitPhaseWorkItem = nil
		startSweepAnimation()
	}

	func startSweepAnimation() {
		guard let sweepLayer else {
			return
		}
		sweepLayer.removeAllAnimations()
		sweepLayer.opacity = 1

		let bandWidth = sweepLayer.bounds.width
		let startX = -bandWidth / 2
		let endX = width + bandWidth / 2
		let move = CABasicAnimation(keyPath: "position.x")
		move.fromValue = startX
		move.toValue = endX
		move.duration = 2.1
		move.timingFunction = CAMediaTimingFunction(name: .easeOut)
		move.fillMode = .forwards
		move.isRemovedOnCompletion = false

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		sweepLayer.position = CGPoint(x: endX, y: sweepLayer.position.y)
		CATransaction.commit()

		sweepLayer.add(move, forKey: "sweep-position")
	}

	func stopSweepAnimation() {
		sweepLayer?.removeAllAnimations()
		sweepLayer?.opacity = 0
	}

	func startConfirmPhase(duration: TimeInterval, terminateOnHide: Bool) {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		preparePanel()

		let normalizedDuration = max(0.1, duration)
		animateProgress(to: 1, duration: normalizedDuration, timingFunctionName: .linear)

		let workItem = DispatchWorkItem { [weak self] in
			self?.hidePanel()
			if terminateOnHide {
				NSApp.terminate(nil)
			}
		}
		hideWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + normalizedDuration, execute: workItem)
	}
}

let arguments = Array(CommandLine.arguments.dropFirst())
var warmup = false
var daemon = false
var waitDuration: TimeInterval = 0
var confirmDuration: TimeInterval = 3
var controlPath: String?
var readyPath: String?
var positionalDurations: [TimeInterval] = []

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
			positionalDurations.append(parsedDuration)
		}
	}
	index += 1
}

if positionalDurations.count >= 2 {
	waitDuration = positionalDurations[0]
	confirmDuration = positionalDurations[1]
} else if let firstDuration = positionalDurations.first {
	confirmDuration = firstDuration
}

let app = NSApplication.shared
let delegate = AppDelegate(waitDuration: waitDuration, confirmDuration: confirmDuration, warmup: warmup, daemon: daemon, controlPath: controlPath, readyPath: readyPath)
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

hud_daemon_needs_restart() {
	hud_daemon_is_running || return 1
	[ -x "$HUD_BIN" ] && [ "$HUD_BIN" -nt "$HUD_DAEMON_PID_FILE" ] && return 0
	[ -f "$HUD_SWIFT_SOURCE" ] && [ "$HUD_SWIFT_SOURCE" -nt "$HUD_DAEMON_PID_FILE" ] && return 0
	return 1
}

ensure_send_window_hud_daemon() {
	hud_daemon_needs_restart && stop_send_window_hud_daemon
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
	local wait_duration="$1"
	local confirm_duration="$2"
	local expected_session_id="${3:-}"
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
	if send_hud_daemon_command "show|$wait_duration|$confirm_duration"; then
		write_file ready_hud.pid "$(hud_daemon_pid)"
		return 0
	fi
	stop_send_window_hud_daemon >/dev/null 2>&1 || true
	"$HUD_BIN" "$wait_duration" "$confirm_duration" >/dev/null 2>&1 &
	write_file ready_hud.pid "$!"
}

show_send_window_hud_if_enabled() {
	[ "$DJI_ENABLE_READY_HUD" = "1" ] || return 0
	show_send_window_hud "$1" "$2" "$3"
}

confirm_send_window_hud() {
	local confirm_duration="$1"
	local expected_session_id="${2:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	if [ ! -x "$HUD_BIN" ]; then
		ensure_send_window_hud_binary || {
			log "hud confirm skipped: binary_missing"
			return 0
		}
	fi
	if send_hud_daemon_command "confirm|$confirm_duration"; then
		write_file ready_hud.pid "$(hud_daemon_pid)"
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	stop_send_window_hud_daemon >/dev/null 2>&1 || true
	"$HUD_BIN" 0 "$confirm_duration" >/dev/null 2>&1 &
	write_file ready_hud.pid "$!"
}

confirm_send_window_hud_if_enabled() {
	[ "$DJI_ENABLE_READY_HUD" = "1" ] || return 0
	confirm_send_window_hud "$1" "$2"
}

load_optional_config
DJI_ENABLE_AUDIO_FEEDBACK="$(normalize_toggle "$DJI_ENABLE_AUDIO_FEEDBACK" 1)"
DJI_PRECONFIRM_SOUND_NAME="$(normalize_sound_name "$DJI_PRECONFIRM_SOUND_NAME")"
DJI_ENABLE_READY_HUD="$(normalize_toggle "$DJI_ENABLE_READY_HUD" 1)"
CONFIRM_WINDOW="$(normalize_duration_seconds "${DJI_REVIEW_WINDOW_SECONDS:-$CONFIRM_WINDOW}" 3)"

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

wait_for_save_state_value() {
	local name="$1"
	local polls="$WATCH_STATE_READY_POLLS"
	if [ -f "$STATE_DIR/save_in_progress" ]; then
		polls="$SAVE_STATE_READY_POLLS"
	fi
	wait_for_state_value "$name" "$polls" "$WATCH_STATE_READY_INTERVAL"
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
	/bin/rm -f "$STATE_DIR"/{mode,pane_id,watcher.pid,pending_confirm,save_ts,db_anchor_rowid,db_anchor_updated_at,ready_hud.pid,session_id,window_deadline,save_in_progress}
}

set_vars() { "$KCLI" --set-variables "$1" 2>/dev/null; }

reset_send_consumed() {
	/bin/rm -rf "$STATE_DIR/send_consumed.lock"
}

clear_watch_state() {
	local expected_session_id="${1:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	set_vars '{"dji_watching":0,"dji_ready_to_send":0}'
}

claim_send_state() {
	local source_label="$1"
	local expected_session_id="${2:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 1
	fi
	/bin/mkdir "$STATE_DIR/send_consumed.lock" 2>/dev/null || {
		log "$source_label ignored already_consumed"
		return 1
	}
}

release_send_state() {
	/bin/rm -rf "$STATE_DIR/send_consumed.lock"
}

finalize_send_state() {
	local expected_session_id="${1:-}"
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	dismiss_ready_hud "$expected_session_id"
	/bin/rm -f "$STATE_DIR/window_deadline" "$STATE_DIR/pending_confirm"
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
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	show_send_window_hud_if_enabled "$WAIT_PHASE_DURATION" "$CONFIRM_WINDOW" "$expected_session_id"
	log "${log_label} send_window_started wait=${WAIT_PHASE_DURATION}s confirm=${CONFIRM_WINDOW}s"
}

reuse_or_open_send_window() {
	local log_label="$1"
	local expected_session_id="${2:-}"
	local ready_pid
	ready_pid="$(read_file ready_hud.pid)"
	if [ -n "$ready_pid" ] && /bin/kill -0 "$ready_pid" 2>/dev/null; then
		log "${log_label} send_window_reused wait=${WAIT_PHASE_DURATION}s confirm=${CONFIRM_WINDOW}s"
		return 0
	fi
	open_send_window "$log_label" "$expected_session_id"
}

start_confirm_window() {
	local log_label="$1"
	local expected_session_id="${2:-}"
	local deadline
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	confirm_send_window_hud_if_enabled "$CONFIRM_WINDOW" "$expected_session_id"
	deadline="$(window_deadline_timestamp "$CONFIRM_WINDOW")"
	write_file window_deadline "$deadline"
	log "${log_label} confirm_window_started window=${CONFIRM_WINDOW}s deadline=${deadline}"
	printf '%s' "$deadline"
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
	local polls="$2"
	local grace_polls="${3:-0}"
	local expected_session_id="${4:-}"
	local deadline
	local remaining_window
	if [ -n "$expected_session_id" ] && ! session_is_current "$expected_session_id"; then
		return 0
	fi
	set_vars '{"dji_watching":0,"dji_ready_to_send":1}'
	deadline="$(start_confirm_window "watch ${mode}" "$expected_session_id")"
	remaining_window="$(remaining_deadline_seconds "$deadline")"
	if ! awk -v remaining="$remaining_window" 'BEGIN { exit !(remaining > 0) }'; then
		set_vars '{"dji_ready_to_send":0}'
		expire_send_window "$mode" 0 "$expected_session_id"
		return
	fi
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
		end tell' 2>/dev/null)" || {
		local status=$?
		log "gui_send_enter failed frontmost_lookup status=${status}"
		return "$status"
	}
	if [ "$bundle" = "com.googlecode.iterm2" ]; then
		"$OSASCRIPT_BIN" -e \
			'tell application "iTerm2" to tell current window to tell current session to write text ""' 2>/dev/null || {
			local status=$?
			log "gui_send_enter failed iterm_write status=${status}"
			return "$status"
		}
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
	local status
	mode="$(read_file mode)"
	if [ "$mode" = "tmux" ]; then
		pane="$(read_file pane_id)"
		if [ -n "$pane" ]; then
			$TMUX_BIN send-keys -t "$pane" Enter 2>/dev/null
			status=$?
			if [ "$status" -eq 0 ]; then
				log "$source tmux send_enter pane=${pane}"
				return 0
			fi
			log "$source tmux send_failed pane=${pane} status=${status}"
			return "$status"
		fi
		log "$source tmux no_pane"
		return 1
	elif [ "$mode" = "gui" ]; then
		gui_send_enter
		status=$?
		if [ "$status" -eq 0 ]; then
			log "$source gui send_enter"
			return 0
		fi
		log "$source gui send_failed status=${status}"
		return "$status"
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
	reset_send_consumed
	write_file save_in_progress 1
	save_ts="$(utc_timestamp_ms)"
	[ -n "$save_ts" ] || save_ts="$(/bin/date -u +%Y-%m-%dT%H:%M:%S.000Z)"
	anchor_rowid="$(typeless_last_rowid)"
	[ -n "$anchor_rowid" ] || anchor_rowid=0
	anchor_updated_at="$(typeless_row_updated_at "$anchor_rowid")"
	session_id="$(generate_session_id)"
	[ -n "$session_id" ] || session_id="$$-$(/bin/date +%s)"

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
		log "save mode=tmux pane=${pane} app=${front_bundle} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at}"
	else
		log "save mode=gui app=${front_bundle} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at}"
	fi
	prepare_send_window_hud_if_enabled
	write_file save_ts "$save_ts"
	write_file db_anchor_rowid "$anchor_rowid"
	write_file db_anchor_updated_at "$anchor_updated_at"
	if [ -n "$pane" ]; then
		write_file mode tmux
		write_file pane_id "$pane"
	else
		write_file mode gui
	fi
	write_file session_id "$session_id"
	/bin/rm -f "$STATE_DIR/save_in_progress"
	;;

watch)
	kill_old_watcher
	set_vars '{"dji_ready_to_send":0}'
	watch_session_id="$(wait_for_save_state_value session_id)"
	trap 'clear_watch_state "$watch_session_id"' EXIT
	trap 'clear_watch_state "$watch_session_id"; exit 0' TERM INT

	mode="$(wait_for_save_state_value mode)"
	write_file watcher.pid "$$"

	if [ "$mode" = "tmux" ]; then
		pane="$(wait_for_save_state_value pane_id)"
		[ -n "$pane" ] || {
			cleanup "$watch_session_id"
			exit 0
		}
		save_ts="$(read_file save_ts)"
		anchor_rowid="$(read_file db_anchor_rowid)"
		anchor_updated_at="$(read_file db_anchor_updated_at)"
		[ -n "$anchor_rowid" ] || anchor_rowid=0
		log "watch mode=tmux pane=${pane} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at} polling"
		reuse_or_open_send_window "watch tmux" "$watch_session_id"

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
		done

		if [ $changed -eq 1 ] && [ "$done_status" = "transcript" ]; then
			session_is_current "$watch_session_id" || exit 0
			log "watch tmux transcript_detected (${i} polls ~$((i / 10))s) grace_window=${PRECONFIRM_GRACE_POLLS}x${PRECONFIRM_GRACE_INTERVAL}s"
			if wait_for_pending_confirm; then
				session_is_current "$watch_session_id" || exit 0
				/bin/sleep "$DELIVERY_DELAY"
				if send_current_mode_enter "watch tmux preconfirm"; then
					finalize_send_state "$watch_session_id"
					log "watch tmux preconfirm_send (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s)"
					cleanup "$watch_session_id"
				else
					send_status=$?
					/bin/rm -f "$STATE_DIR/pending_confirm"
					log "watch tmux preconfirm_failed (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s status=${send_status})"
					enter_ready_window tmux "$i" "$pending_confirm_polls" "$watch_session_id"
				fi
			else
				enter_ready_window tmux "$i" "$pending_confirm_polls" "$watch_session_id"
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
		reuse_or_open_send_window "watch gui" "$watch_session_id"

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
		done

		if [ $changed -eq 1 ] && [ "$done_status" = "transcript" ]; then
			session_is_current "$watch_session_id" || exit 0
			log "watch gui transcript_detected (${i} polls ~$((i / 10))s) grace_window=${PRECONFIRM_GRACE_POLLS}x${PRECONFIRM_GRACE_INTERVAL}s"
			if wait_for_pending_confirm; then
				session_is_current "$watch_session_id" || exit 0
				/bin/sleep "$DELIVERY_DELAY"
				if send_current_mode_enter "watch gui preconfirm"; then
					finalize_send_state "$watch_session_id"
					log "watch gui preconfirm_send (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s)"
					cleanup "$watch_session_id"
				else
					send_status=$?
					/bin/rm -f "$STATE_DIR/pending_confirm"
					log "watch gui preconfirm_failed (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s status=${send_status})"
					enter_ready_window gui "$i" "$pending_confirm_polls" "$watch_session_id"
				fi
			else
				enter_ready_window gui "$i" "$pending_confirm_polls" "$watch_session_id"
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
		open_window_session_id="$(wait_for_save_state_value session_id)"
	fi
	[ -n "$open_window_session_id" ] || exit 0
	reuse_or_open_send_window open_window "$open_window_session_id" >/dev/null
	;;

preconfirm)
	dismiss_ready_hud
	if transcript_ready_since_save; then
		claim_send_state preconfirm || exit 0
		play_feedback_sound "$DJI_PRECONFIRM_SOUND_NAME"
		if send_current_mode_enter preconfirm; then
			finalize_send_state
			kill_old_watcher
			cleanup
		else
			send_status=$?
			release_send_state
			exit "$send_status"
		fi
	else
		write_file pending_confirm 1
		play_feedback_sound "$DJI_PRECONFIRM_SOUND_NAME"
		log "preconfirm queued"
	fi
	;;

confirm)
	claim_send_state confirm || exit 0
	play_feedback_sound "$DJI_PRECONFIRM_SOUND_NAME"
	if send_current_mode_enter confirm; then
		finalize_send_state
		kill_old_watcher
		cleanup
	else
		send_status=$?
		release_send_state
		exit "$send_status"
	fi
	;;
esac
