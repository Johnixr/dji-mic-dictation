#!/bin/bash
# DJI MIC MINI dictation helper — universal version
#
# Usage (called by Karabiner):
#   dictation-enter.sh save   — 1st press: just record frontmost app (no timer)
#   dictation-enter.sh tap    — 2nd press: end dictation, start time window
#   dictation-enter.sh enter  — in window: send Enter to saved app
#
# Time window logic (managed via Karabiner variable dji_in_window):
#   Timer starts on 2nd press (tap), not 1st press (save).
#   After tap, wait TAP_WINDOW_MIN seconds, then open window for
#   (TAP_WINDOW_MAX - TAP_WINDOW_MIN) seconds. During this window,
#   next press sends Enter instead of Fn.
#
# Karabiner rules:
#   dji_active=0            + press → Fn + save + dji_active=1
#   dji_active=1, window=0  + press → Fn + tap  (ends dictation, starts timer)
#   dji_active=1, window=1  + press → enter + reset (no Fn!)

STATE_DIR="/tmp/dji-dictation"
LOG="$STATE_DIR/debug.log"
TAP_WINDOW_MIN=3  # seconds before window opens
TAP_WINDOW_MAX=6  # seconds when window closes

KARABINER_CLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

/bin/mkdir -p "$STATE_DIR"

log() { /usr/bin/printf '%s %s\n' "$(/bin/date +%H:%M:%S)" "$*" >> "$LOG"; }

read_file()  { /bin/cat "$STATE_DIR/$1" 2>/dev/null; }
write_file() { /usr/bin/printf '%s' "$2" > "$STATE_DIR/$1"; }

kill_old_timer() {
  local pid; pid="$(read_file timer.pid)"
  [ -n "$pid" ] && /bin/kill "$pid" 2>/dev/null
  /bin/rm -f "$STATE_DIR/timer.pid"
}

cleanup() { /bin/rm -f "$STATE_DIR"/{app_bundle,timer.pid}; }

set_vars() {
  "$KARABINER_CLI" --set-variables "$1" 2>/dev/null
}

frontmost_bundle() {
  /usr/bin/osascript -e \
    'tell application "System Events" to return bundle identifier of first application process whose frontmost is true' 2>/dev/null
}

# Shake the frontmost window (visual feedback)
shake_window() {
  /usr/bin/osascript <<'AS' 2>/dev/null
tell application "System Events"
  set fp to first application process whose frontmost is true
  set fw to first window of fp
  set {x, y} to position of fw
  repeat 6 times
    set position of fw to {x + 4, y}
    delay 0.01
    set position of fw to {x - 4, y}
    delay 0.01
  end repeat
  delay 0.05
  set position of fw to {x, y}
  delay 0.05
  set position of fw to {x, y}
end tell
AS
}

# Send Return key to a specific app
send_enter_to_app() {
  local bundle="$1"
  case "$bundle" in
    com.googlecode.iterm2)
      /usr/bin/osascript -e \
        'tell application "iTerm2" to tell current window to tell current session to write text ""' 2>/dev/null
      ;;
    *)
      /usr/bin/osascript - "$bundle" <<'AS' 2>/dev/null
on run argv
  set targetBundle to item 1 of argv
  tell application id targetBundle
    activate
    delay 0.2
    tell application "System Events"
      keystroke return
    end tell
  end tell
  return "ok"
end run
AS
      ;;
  esac
}

case "$1" in
  save)
    # 1st press: just record the frontmost app, no timer
    kill_old_timer
    cleanup

    app="$(frontmost_bundle)"
    write_file app_bundle "$app"
    log "save: app=$app"

    # Watchdog: auto-reset if tap not called within 180s
    (
      /bin/sleep 180
      log "save: watchdog timeout, resetting"
      set_vars '{"dji_in_window": 0, "dji_active": 0}'
      cleanup
    ) &
    write_file timer.pid "$!"
    ;;

  tap)
    # 2nd press (end dictation): start time window
    kill_old_timer

    set_vars '{"dji_in_window": 0}'

    log "tap: window will open in ${TAP_WINDOW_MIN}s"

    (
      /bin/sleep "$TAP_WINDOW_MIN"
      set_vars '{"dji_in_window": 1}'
      /usr/bin/afplay /System/Library/Sounds/Tink.aiff &
      shake_window
      log "tap: window OPEN"

      window_duration=$(( TAP_WINDOW_MAX - TAP_WINDOW_MIN ))
      /bin/sleep "$window_duration"
      log "tap: window CLOSED, resetting"
      set_vars '{"dji_in_window": 0, "dji_active": 0}'
      cleanup
    ) &

    write_file timer.pid "$!"
    ;;

  enter)
    # In window: send Enter to saved app
    kill_old_timer

    app="$(read_file app_bundle)"
    if [ -z "$app" ]; then
      log "enter: no app_bundle, nothing to do"
      cleanup
      exit 0
    fi

    result="$(send_enter_to_app "$app")"
    log "enter: send_enter to $app, result=$result"
    cleanup
    ;;

  *)
    echo "Usage: $0 {save|tap|enter}" >&2
    exit 1
    ;;
esac
