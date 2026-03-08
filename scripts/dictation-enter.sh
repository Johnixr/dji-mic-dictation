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
CONFIRM_WINDOW="${CONFIRM_WINDOW:-2}"
PRECONFIRM_GRACE_INTERVAL="${PRECONFIRM_GRACE_INTERVAL:-0.02}"
PRECONFIRM_GRACE_POLLS="${PRECONFIRM_GRACE_POLLS:-50}"
DELIVERY_DELAY="${DELIVERY_DELAY:-0.25}"
WATCH_POLL_INTERVAL="${WATCH_POLL_INTERVAL:-0.1}"
WATCH_MAX_POLLS="${WATCH_MAX_POLLS:-300}"
NO_RECORD_LOG_AFTER_POLLS="${NO_RECORD_LOG_AFTER_POLLS:-100}"
NO_RECORD_LOG_LABEL="${NO_RECORD_LOG_LABEL:-10s}"
STALE_CHECK_EVERY_POLLS="${STALE_CHECK_EVERY_POLLS:-50}"
STALE_SECONDS="${STALE_SECONDS:-5}"
PYTHON3_BIN="${PYTHON3_BIN:-$(command -v python3 2>/dev/null)}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-/usr/bin/osascript}"
AFPLAY_BIN="${AFPLAY_BIN:-/usr/bin/afplay}"
DJI_CONFIG_DIR="${DJI_CONFIG_DIR:-$HOME/.config/dji-mic-dictation}"
DJI_CONFIG_FILE="${DJI_CONFIG_FILE:-$DJI_CONFIG_DIR/config.env}"
DJI_ENABLE_AUDIO_FEEDBACK="${DJI_ENABLE_AUDIO_FEEDBACK:-1}"
DJI_READY_SOUND_NAME="${DJI_READY_SOUND_NAME:-Tink}"
DJI_PRECONFIRM_SOUND_NAME="${DJI_PRECONFIRM_SOUND_NAME:-Sosumi}"
DJI_ENABLE_WINDOW_SHAKE="${DJI_ENABLE_WINDOW_SHAKE:-1}"

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
	"$AFPLAY_BIN" "/System/Library/Sounds/${sound_name}.aiff" &
}

shake_window_if_enabled() {
	[ "$DJI_ENABLE_WINDOW_SHAKE" = "1" ] || return 0
	shake_window
}

load_optional_config
DJI_ENABLE_AUDIO_FEEDBACK="$(normalize_toggle "$DJI_ENABLE_AUDIO_FEEDBACK" 1)"
DJI_READY_SOUND_NAME="$(normalize_sound_name "$DJI_READY_SOUND_NAME")"
DJI_PRECONFIRM_SOUND_NAME="$(normalize_sound_name "$DJI_PRECONFIRM_SOUND_NAME")"
DJI_ENABLE_WINDOW_SHAKE="$(normalize_toggle "$DJI_ENABLE_WINDOW_SHAKE" 1)"

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

kill_old_watcher() {
	local pid
	pid="$(read_file watcher.pid)"
	[ -n "$pid" ] && /bin/kill "$pid" 2>/dev/null
	/bin/rm -f "$STATE_DIR/watcher.pid"
}

cleanup() { /bin/rm -f "$STATE_DIR"/{mode,pane_id,watcher.pid,pending_confirm,save_ts,db_anchor_rowid,db_anchor_updated_at,win_pos}; }

set_vars() { "$KCLI" --set-variables "$1" 2>/dev/null; }

clear_watch_state() { set_vars '{"dji_watching":0,"dji_ready_to_send":0}'; }

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

# 保存当前窗口位置并震动（跳过非标准窗口如水印层）
shake_window() {
	"$OSASCRIPT_BIN" -l JavaScript <<JS 2>/dev/null
var se = Application("System Events");
var fp = se.processes.whose({frontmost: true})[0];
var wins = fp.windows();
var fw = null;
for (var i = 0; i < wins.length; i++) {
  if (wins[i].subrole() === "AXStandardWindow") { fw = wins[i]; break; }
}
if (!fw && wins.length > 0) fw = wins[0];
if (!fw) { "no window"; } else {
  var pos = fw.position();
  var x = pos[0], y = pos[1];
  var app = Application.currentApplication();
  app.includeStandardAdditions = true;
  app.doShellScript("printf '%s %s' " + x + " " + y + " > ${STATE_DIR}/win_pos");
  for (var r = 0; r < 6; r++) {
    fw.position = [x + 4, y]; delay(0.01);
    fw.position = [x - 4, y]; delay(0.01);
  }
  delay(0.05); fw.position = [x, y];
  delay(0.05); fw.position = [x, y];
  "ok";
}
JS
}

# 强制归位窗口（confirm 时调用，防止抖动被中断后窗口偏移）
restore_window() {
	local saved
	saved="$(read_file win_pos)"
	[ -z "$saved" ] && return
	local x y
	x="${saved% *}"
	y="${saved#* }"
	"$OSASCRIPT_BIN" -l JavaScript - "$x" "$y" <<'JS' 2>/dev/null
function run(argv) {
  var x = parseInt(argv[0]), y = parseInt(argv[1]);
  var se = Application("System Events");
  var fp = se.processes.whose({frontmost: true})[0];
  var wins = fp.windows();
  var fw = null;
  for (var i = 0; i < wins.length; i++) {
    if (wins[i].subrole() === "AXStandardWindow") { fw = wins[i]; break; }
  }
  if (!fw && wins.length > 0) fw = wins[0];
  if (fw) { fw.position = [x, y]; }
}
JS
}

gui_send_enter() {
	local bundle
	bundle="$("$OSASCRIPT_BIN" -e \
		'tell application "System Events" to return bundle identifier of first application process whose frontmost is true' 2>/dev/null)"
	case "$bundle" in
	com.googlecode.iterm2)
		"$OSASCRIPT_BIN" -e \
			'tell application "iTerm2" to tell current window to tell current session to write text ""' 2>/dev/null
		;;
	*)
		"$OSASCRIPT_BIN" -e \
			'tell application "System Events" to keystroke return' 2>/dev/null
		;;
	esac
	log "gui_send_enter: $bundle"
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
	write_file save_ts "$save_ts"
	write_file db_anchor_rowid "$anchor_rowid"
	write_file db_anchor_updated_at "$anchor_updated_at"

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
	;;

watch)
	kill_old_watcher
	set_vars '{"dji_ready_to_send":0}'
	trap 'clear_watch_state' EXIT TERM INT

	mode="$(read_file mode)"
	write_file watcher.pid "$$"

	if [ "$mode" = "tmux" ]; then
		pane="$(read_file pane_id)"
		[ -n "$pane" ] || {
			cleanup
			exit 0
		}
		save_ts="$(read_file save_ts)"
		anchor_rowid="$(read_file db_anchor_rowid)"
		anchor_updated_at="$(read_file db_anchor_updated_at)"
		[ -n "$anchor_rowid" ] || anchor_rowid=0
		log "watch mode=tmux pane=${pane} save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at} polling"

		changed=0 i=0 done_status="" has_record=0
		while [ $i -lt "$WATCH_MAX_POLLS" ]; do
			/bin/sleep "$WATCH_POLL_INTERVAL"
			i=$((i + 1))
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
					clear_watch_state
					/bin/rm -f "$STATE_DIR/watcher.pid"
					exit 0
				fi
			fi
		done

		if [ $changed -eq 1 ] && [ "$done_status" = "transcript" ]; then
			log "watch tmux transcript_detected (${i} polls ~$((i / 10))s) grace_window=${PRECONFIRM_GRACE_POLLS}x${PRECONFIRM_GRACE_INTERVAL}s"
			if wait_for_pending_confirm; then
				/bin/sleep "$DELIVERY_DELAY"
				clear_watch_state
				$TMUX_BIN send-keys -t "$pane" Enter 2>/dev/null
				log "watch tmux preconfirm_send (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s)"
				cleanup
			else
				set_vars '{"dji_watching":0,"dji_ready_to_send":1}'
				play_feedback_sound "$DJI_READY_SOUND_NAME"
				shake_window_if_enabled
				log "watch tmux content_settled (${i} polls ~$((i / 10))s) window=${CONFIRM_WINDOW}s"
				/bin/sleep "$CONFIRM_WINDOW"
				set_vars '{"dji_ready_to_send":0}'
				log "watch tmux window_expired"
				/bin/rm -f "$STATE_DIR/watcher.pid"
			fi
		elif [ $changed -eq 1 ] && [ "$done_status" = "dismissed" ]; then
			clear_watch_state
			log "watch tmux dismissed (${i} polls ~$((i / 10))s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		else
			clear_watch_state
			log "watch tmux no_change (timeout 30s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		fi

	elif [ "$mode" = "gui" ]; then
		save_ts="$(read_file save_ts)"
		anchor_rowid="$(read_file db_anchor_rowid)"
		anchor_updated_at="$(read_file db_anchor_updated_at)"
		[ -n "$anchor_rowid" ] || anchor_rowid=0
		log "watch mode=gui save_ts=${save_ts} anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at} polling"

		changed=0 i=0 has_record=0
		while [ $i -lt "$WATCH_MAX_POLLS" ]; do
			/bin/sleep "$WATCH_POLL_INTERVAL"
			i=$((i + 1))
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
					clear_watch_state
					/bin/rm -f "$STATE_DIR/watcher.pid"
					exit 0
				fi
			fi
		done

		if [ $changed -eq 1 ] && [ "$done_status" = "transcript" ]; then
			log "watch gui transcript_detected (${i} polls ~$((i / 10))s) grace_window=${PRECONFIRM_GRACE_POLLS}x${PRECONFIRM_GRACE_INTERVAL}s"
			if wait_for_pending_confirm; then
				/bin/sleep "$DELIVERY_DELAY"
				clear_watch_state
				gui_send_enter
				log "watch gui preconfirm_send (${i} polls ~$((i / 10))s wait_polls=${pending_confirm_polls} delay=${DELIVERY_DELAY}s)"
				cleanup
			else
				set_vars '{"dji_watching":0,"dji_ready_to_send":1}'
				play_feedback_sound "$DJI_READY_SOUND_NAME"
				shake_window_if_enabled
				log "watch gui content_settled (${i} polls ~$((i / 10))s) window=${CONFIRM_WINDOW}s"
				/bin/sleep "$CONFIRM_WINDOW"
				set_vars '{"dji_ready_to_send":0}'
				log "watch gui window_expired"
				/bin/rm -f "$STATE_DIR/watcher.pid"
			fi
		elif [ $changed -eq 1 ] && [ "$done_status" = "dismissed" ]; then
			clear_watch_state
			log "watch gui dismissed (${i} polls ~$((i / 10))s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		else
			clear_watch_state
			log "watch gui no_change (timeout 30s)"
			/bin/rm -f "$STATE_DIR/watcher.pid"
		fi
	else
		log "watch unknown mode, exit"
		/bin/rm -f "$STATE_DIR/watcher.pid"
	fi
	;;

preconfirm)
	write_file pending_confirm 1
	play_feedback_sound "$DJI_PRECONFIRM_SOUND_NAME"
	log "preconfirm queued"
	;;

confirm)
	kill_old_watcher
	restore_window
	set_vars '{"dji_ready_to_send":0,"dji_watching":0}'

	mode="$(read_file mode)"
	if [ "$mode" = "tmux" ]; then
		pane="$(read_file pane_id)"
		if [ -n "$pane" ]; then
			$TMUX_BIN send-keys -t "$pane" Enter 2>/dev/null
			log "confirm tmux send_enter pane=${pane}"
		else
			log "confirm tmux no_pane"
		fi
	elif [ "$mode" = "gui" ]; then
		gui_send_enter
		log "confirm gui send_enter"
	else
		log "confirm unknown mode"
	fi
	cleanup
	;;
esac
