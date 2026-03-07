# DJI Mic Mini Dictation Setup

You are setting up a DJI Mic Mini wireless microphone as a hands-free dictation controller on macOS. Follow these steps exactly.

## What this does

Maps the DJI Mic Mini's volume+ button to macOS dictation (Fn key), with a time-window based auto-Enter feature:

1. **1st press**: Start dictation (Fn) + record frontmost app
2. **2nd press**: Stop dictation (Fn) + start 3-second timer
3. **3 seconds later**: Audio chime + window shake = send window is open
4. **3rd press (within 3-6s)**: Send Enter to the recorded app
5. **Timeout (>6s)**: Silent reset, no side effects

## Installation steps (execute in order)

### 1. Install Karabiner-Elements

```bash
brew install --cask karabiner-elements
```

If not installed, prompt the user to open Karabiner-Elements and grant **Input Monitoring** and **Accessibility** permissions in System Settings → Privacy & Security.

### 2. Copy the script

```bash
mkdir -p ~/.config/karabiner/scripts
cp scripts/dictation-enter.sh ~/.config/karabiner/scripts/
chmod +x ~/.config/karabiner/scripts/dictation-enter.sh
```

### 3. Merge Karabiner config

Read `karabiner/dji-mic-mini.json` from this repo. Merge its contents into the user's existing `~/.config/karabiner/karabiner.json`:

- Add the `complex_modifications.rules` array entries into the user's **active profile**'s `complex_modifications.rules` array
- Add the `devices` array entry into the user's **active profile**'s `devices` array
- **Do NOT overwrite** the user's existing rules or devices — append to them
- The active profile is the one with `"selected": true`, or the first profile if none is selected

### 4. Verify device connection

```bash
'/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli' --list-connected-devices
```

Look for a device with vendor_id 11427 and product_id 16401. If found, the DJI Mic Mini receiver is connected.

### 5. Remind user

Tell the user to:
- Enable macOS Dictation: System Settings → Keyboard → Dictation → On
- Connect DJI Mic Mini receiver via USB-C
- Optionally install [Typeless](https://www.typeless.com/?via=john-yin) for better recognition

## Key details

- DJI Mic Mini vendor_id: **11427**, product_id: **16401**
- The device is a **Consumer HID device** (not a keyboard), so `"is_consumer": true, "ignore": false` is required in Karabiner's device config — this is already in the template
- Script path in karabiner config uses `~/.config/karabiner/scripts/dictation-enter.sh`
- For other wireless mic models, ask the user for their vendor_id/product_id (use `karabiner_cli --list-connected-devices`) and update both the rules and devices config

## Configurable parameters (in dictation-enter.sh)

- `TAP_WINDOW_MIN=3` — seconds after 2nd press before send window opens
- `TAP_WINDOW_MAX=6` — seconds after 2nd press when window closes and resets

## Debugging

```bash
cat /tmp/dji-dictation/debug.log
```
