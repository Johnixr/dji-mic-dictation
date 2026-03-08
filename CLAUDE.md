# DJI Mic Mini Dictation Setup

You are setting up a DJI Mic Mini wireless microphone as a hands-free dictation controller on macOS. Follow these steps exactly.

## What this does

Maps the DJI Mic Mini's volume+ button to macOS dictation (Fn key), with adaptive text-detection based auto-Enter:

1. **1st press**: Start dictation (Fn)
2. **2nd press**: Stop dictation (Fn) + poll for text input via Accessibility API
3. **Text detected**: Audio chime + window shake = send window is open
4. **3rd press (within 3s)**: Send Enter to current frontmost app
5. **No press within 3s**: Silent reset, no side effects

## Validation requirements

After **any** code change (feature work, refactor, bug fix, config update), you must proactively run the repository validation suite before handing control back to the user. Do not wait for the user to remind you.

This is a **local pre-handoff requirement**, not just a CI requirement. Run it yourself after every code change; CI is only the backstop.

Run:

```bash
scripts/validate.sh
```

If `pytest` is missing, install dev dependencies first:

```bash
python3 -m pip install -r requirements-dev.txt
```

The validation suite currently includes three layers:

1. **Lint**
   - `bash -n scripts/dictation-enter.sh`
   - `shfmt -d scripts/*.sh`
   - `shellcheck scripts/*.sh`
2. **Test**
   - `python3 -m pytest -q -m "not smoke"`
3. **Smoke Test**
   - `python3 -m pytest -q -m smoke`

The CI pipeline must also run these three stages separately: `lint`, `test`, and `smoke-test`.

## Installation steps (execute in order)

### 1. Install Karabiner-Elements

```bash
brew install --cask karabiner-elements
```

If not installed, prompt the user to open Karabiner-Elements and grant **Input Monitoring** and **Accessibility** permissions in System Settings → Privacy & Security.

### 2. Install pyobjc (required for text detection)

The script uses Python + pyobjc to detect text input via macOS Accessibility API. Install it with:

```bash
pip install pyobjc-core pyobjc-framework-Cocoa pyobjc-framework-ApplicationServices
```

Then find the full path of the python3 that has pyobjc:

```bash
python3 -c "import ApplicationServices; import sys; print(sys.executable)"
```

Update the `PYTHON3=` line in `dictation-enter.sh` with this path.

### 3. Copy the script

```bash
mkdir -p ~/.config/karabiner/scripts
cp scripts/dictation-enter.sh ~/.config/karabiner/scripts/
chmod +x ~/.config/karabiner/scripts/dictation-enter.sh
```

### 4. Merge Karabiner config

Read `karabiner/dji-mic-mini.json` from this repo. Merge its contents into the user's existing `~/.config/karabiner/karabiner.json`:

- Add the `complex_modifications.rules` array entries into the user's **active profile**'s `complex_modifications.rules` array
- Add the `devices` array entry into the user's **active profile**'s `devices` array
- **Do NOT overwrite** the user's existing rules or devices — append to them
- The active profile is the one with `"selected": true`, or the first profile if none is selected

### 5. Verify device connection

```bash
'/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli' --list-connected-devices
```

Look for a device with vendor_id 11427 and product_id 16401. If found, the DJI Mic Mini receiver is connected.

### 6. Remind user

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

- `PYTHON3=...` — full path to python3 with pyobjc installed
- `POLL_INTERVAL=0.2` — seconds between text input checks
- `SEND_WINDOW=3` — seconds the send window stays open after text is detected
- `SAVE_WATCHDOG=180` — seconds before auto-reset if 2nd press never happens

## Troubleshooting

Debug log: `cat /tmp/dji-dictation/debug.log`

If the user reports issues, check these in order:

1. **Button does nothing** → Karabiner needs **Input Monitoring** permission. Check System Settings → Privacy & Security → Input Monitoring.
2. **Button changes volume instead of triggering dictation** → Device not grabbed. Verify `"is_consumer": true, "ignore": false` in karabiner.json devices. Check Karabiner log for `grabbed` status.
3. **No sound / no window shake after dictation** → `/usr/bin/osascript` or the terminal app needs **Accessibility** permission. Check System Settings → Privacy & Security → Accessibility.
4. **Sound plays but window doesn't shake** → Some Electron apps (like Feishu/Lark) have invisible overlay windows. The script already filters for `AXStandardWindow`. If another app has this issue, inspect its windows and add handling.
5. **Log shows `baseline=-1` repeatedly** → pyobjc not installed or `PYTHON3` path is wrong. Verify: `$PYTHON3 -c "import ApplicationServices; print('ok')"`.
6. **Enter doesn't send** → Terminal app (iTerm2 / Terminal.app) needs **Accessibility** permission.

### Required permissions checklist

All in **System Settings → Privacy & Security**:

- **Input Monitoring**: Karabiner-Elements, karabiner_grabber
- **Accessibility**: Karabiner-Elements, terminal app (iTerm2 / Terminal.app)
- **Dictation**: System Settings → Keyboard → Dictation → On
