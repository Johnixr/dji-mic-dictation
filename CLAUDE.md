# DJI Mic Mini Dictation Setup

This project configures a DJI Mic Mini wireless microphone as a hands-free dictation controller on macOS.

## What this does

Maps the DJI Mic Mini's volume+ button to macOS dictation (Fn key), with a time-window based auto-Enter feature:

1. **1st press**: Start dictation (Fn) + record frontmost app
2. **2nd press**: Stop dictation (Fn) + start 3-second timer
3. **3 seconds later**: Audio chime + window shake = send window is open
4. **3rd press (within 3-6s)**: Send Enter to the recorded app
5. **Timeout (>6s)**: Silent reset, no side effects

## Installation steps

1. Install Karabiner-Elements: `brew install --cask karabiner-elements`
2. Grant **Input Monitoring** and **Accessibility** permissions to Karabiner
3. Copy the script: `cp scripts/dictation-enter.sh ~/.config/karabiner/scripts/ && chmod +x ~/.config/karabiner/scripts/dictation-enter.sh`
4. Merge `karabiner/dji-mic-mini.json` into `~/.config/karabiner/karabiner.json`:
   - Add the `complex_modifications.rules` array entries to your profile's rules
   - Add the `devices` array entry to your profile's devices
5. Connect DJI Mic Mini receiver via USB-C
6. Enable macOS Dictation: System Settings → Keyboard → Dictation → On

## Key details

- DJI Mic Mini vendor_id: **11427**, product_id: **16401**
- The device is a **Consumer HID device** (not a keyboard), so `"is_consumer": true, "ignore": false` is required in Karabiner's device config
- Script path in karabiner config uses `~/.config/karabiner/scripts/dictation-enter.sh` — adjust if you place it elsewhere
- For other wireless mic models, change vendor_id/product_id (use `karabiner_cli --list-connected-devices` to find yours)

## Configurable parameters (in dictation-enter.sh)

- `TAP_WINDOW_MIN=3` — seconds after 2nd press before send window opens
- `TAP_WINDOW_MAX=6` — seconds after 2nd press when window closes and resets

## Debugging

```bash
cat /tmp/dji-dictation/debug.log
```
