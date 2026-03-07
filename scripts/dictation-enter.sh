#!/bin/bash
# DJI MIC MINI dictation helper
#
# Usage (called by Karabiner):
#   dictation-enter.sh save   — 1st press: mark dictation started
#   dictation-enter.sh tap    — 2nd press: end dictation, wait for text, open send window
#   dictation-enter.sh enter  — in window: send Enter to current frontmost app
#
# Karabiner rules:
#   dji_active=0            + press → Fn + save + dji_active=1
#   dji_active=1, window=0  + press → Fn + tap  (ends dictation, polls for text)
#   dji_active=1, window=1  + press → enter + reset (no Fn!)

STATE_DIR="/tmp/dji-dictation"
LOG="$STATE_DIR/debug.log"
POLL_INTERVAL=0.2   # seconds between char count checks
SEND_WINDOW=6       # seconds the send window stays open
SAVE_WATCHDOG=180   # seconds before save auto-resets

KARABINER_CLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
PYTHON3="/opt/homebrew/Caskroom/miniforge/base/bin/python3"

/bin/mkdir -p "$STATE_DIR"

log() { /usr/bin/printf '%s %s\n' "$(/bin/date +%H:%M:%S)" "$*" >> "$LOG"; }

read_file()  { /bin/cat "$STATE_DIR/$1" 2>/dev/null; }
write_file() { /usr/bin/printf '%s' "$2" > "$STATE_DIR/$1"; }

kill_old_timer() {
  local pid; pid="$(read_file timer.pid)"
  if [ -n "$pid" ]; then
    # kill 整个进程组（包括 osascript 子进程）
    /bin/kill -- -"$pid" 2>/dev/null
    /bin/kill "$pid" 2>/dev/null
  fi
  /bin/rm -f "$STATE_DIR/timer.pid"
}

cleanup() { /bin/rm -f "$STATE_DIR"/{timer.pid,win_pos}; }

set_vars() {
  "$KARABINER_CLI" --set-variables "$1" 2>/dev/null
}

# 获取当前焦点输入框的字符数
get_char_count() {
  "$PYTHON3" -c "
import ApplicationServices as AX
from Cocoa import NSWorkspace
app = NSWorkspace.sharedWorkspace().frontmostApplication()
ref = AX.AXUIElementCreateApplication(app.processIdentifier())
_, el = AX.AXUIElementCopyAttributeValue(ref, 'AXFocusedUIElement', None)
if el:
    _, n = AX.AXUIElementCopyAttributeValue(el, 'AXNumberOfCharacters', None)
    print(n if n else -1)
else:
    print(-1)
" 2>/dev/null
}

# 保存当前窗口位置并震动（跳过非标准窗口如水印层）
shake_window() {
  /usr/bin/osascript -l JavaScript <<JS 2>/dev/null
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
  // 保存原始位置到文件，供 enter 快速归位
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

# 强制归位窗口（enter 时调用，防止抖动被中断后窗口偏移）
restore_window() {
  local saved; saved="$(read_file win_pos)"
  [ -z "$saved" ] && return
  local x y
  x="${saved% *}"
  y="${saved#* }"
  /usr/bin/osascript -l JavaScript - "$x" "$y" <<'JS' 2>/dev/null
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

# 向当前最前面的 App 发送 Enter（不切换 App）
send_enter() {
  local bundle
  bundle="$(/usr/bin/osascript -e \
    'tell application "System Events" to return bundle identifier of first application process whose frontmost is true' 2>/dev/null)"

  case "$bundle" in
    com.googlecode.iterm2)
      /usr/bin/osascript -e \
        'tell application "iTerm2" to tell current window to tell current session to write text ""' 2>/dev/null
      ;;
    *)
      /usr/bin/osascript -e \
        'tell application "System Events" to keystroke return' 2>/dev/null
      ;;
  esac
  log "enter: sent to $bundle"
}

case "$1" in
  save)
    kill_old_timer
    cleanup
    log "save: started"

    # 看门狗：长时间不 tap 就自动重置
    (
      /bin/sleep "$SAVE_WATCHDOG"
      log "save: watchdog timeout, resetting"
      set_vars '{"dji_in_window": 0, "dji_active": 0}'
      cleanup
    ) &
    write_file timer.pid "$!"
    ;;

  tap)
    kill_old_timer
    set_vars '{"dji_in_window": 0}'

    baseline="$(get_char_count)"
    log "tap: baseline=$baseline, polling"

    (
      while true; do
        /bin/sleep "$POLL_INTERVAL"
        current="$(get_char_count)"
        if [ "$current" != "$baseline" ] && [ "$current" != "-1" ]; then
          log "tap: text changed ($baseline → $current)"
          set_vars '{"dji_in_window": 1}'
          /usr/bin/afplay /System/Library/Sounds/Tink.aiff &
          shake_window
          log "tap: window OPEN"

          /bin/sleep "$SEND_WINDOW"
          log "tap: window CLOSED, resetting"
          set_vars '{"dji_in_window": 0, "dji_active": 0}'
          cleanup
          exit 0
        fi
      done
    ) &

    write_file timer.pid "$!"
    ;;

  enter)
    kill_old_timer
    restore_window
    send_enter
    cleanup
    ;;

  *)
    echo "Usage: $0 {save|tap|enter}" >&2
    exit 1
    ;;
esac
