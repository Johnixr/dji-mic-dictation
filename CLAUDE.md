# DJI Mic Mini Dictation Setup

You are setting up a keyboard-first dictation/send workflow on macOS. `Fn` is the primary trigger. A DJI Mic Mini can be enabled as an optional hardware trigger that mirrors the same workflow.

## What this does

Builds an adaptive dictation/send workflow around the macOS `Fn` dictation trigger:

1. **1st `Fn` press**: Start dictation
2. **2nd `Fn` press**: Stop dictation + open send window (ready overlay + audio chime once text lands)
3. **3rd `Fn` press (within 4s)**: Send Enter to current frontmost app
4. **No press within 4s**: Silent reset, no side effects

If the optional DJI trigger is enabled, its button mirrors the same save / preconfirm / confirm flow.

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
   - `npm run lint --silent`
2. **Test**
   - `npm run test:node --silent`
   - `python3 -m pytest -q -m "not smoke"`
3. **Smoke Test**
   - `python3 -m pytest -q -m smoke`

The CI pipeline must also run these three stages separately: `lint`, `test`, and `smoke-test`.

## Installation and lifecycle commands

Default to the CLI instead of manually editing files.

### Install

```bash
npx github:Johnixr/dji-mic-dictation install
```

The installer should check for a connected DJI Mic Mini automatically:

- if detected, enable the optional DJI trigger on top of the keyboard workflow
- if not detected, default to keyboard-only and ask the user whether to preconfigure the optional DJI trigger when interactive
- if the user explicitly wants to force a mode, `--trigger-mode keyboard` and `--trigger-mode keyboard+dji` remain valid overrides

The CLI is responsible for:

- checking that Karabiner and Typeless are present
- copying `scripts/dictation-enter.sh` into `~/.config/karabiner/scripts/`
- writing `~/.config/dji-mic-dictation/config.env`
- merging the managed keyboard workflow rule into the target profile
- adding the managed DJI device entry only when the optional trigger mode is enabled
- reminding the user about required permissions

### Update

```bash
npx github:Johnixr/dji-mic-dictation update
```

Use this when the repo script or Karabiner rule changes. It should refresh the installed script/rules while preserving the user's config.

Unless explicitly overridden, `update` should preserve both the existing trigger mode and the existing target profile.

### Doctor

```bash
npx github:Johnixr/dji-mic-dictation doctor
```

Use this to inspect Typeless DB presence, Karabiner config state, installed script/config files, connected device status, and whether an update is needed.

Only treat device connection as relevant when the optional DJI trigger mode is enabled.

### Config

```bash
npx github:Johnixr/dji-mic-dictation config
```

Use this to change audio feedback and ready overlay settings.

### Uninstall

```bash
npx github:Johnixr/dji-mic-dictation uninstall
```

This should remove only the managed script/config/Karabiner entries, without clobbering unrelated user settings.

## Key details

- Keyboard workflow is first-class; the optional DJI trigger mode adds device-specific Karabiner mappings on top
- DJI Mic Mini vendor_id: **11427**, product_id: **16401**
- The optional DJI trigger device is a **Consumer HID device** (not a keyboard), so `"is_consumer": true, "ignore": false` is required in Karabiner's device config
- Script path in karabiner config uses `~/.config/karabiner/scripts/dictation-enter.sh`
- Runtime text detection depends on the Typeless DB at `~/Library/Application Support/Typeless/typeless.db`
- For other external trigger devices, ask the user for their vendor_id/product_id (use `karabiner_cli --list-connected-devices`) and update both the rules and device config

## Configurable parameters

Persist user-facing settings in `~/.config/dji-mic-dictation/config.env`:

- `DJI_ENABLE_AUDIO_FEEDBACK=1|0`
- `DJI_PRECONFIRM_SOUND_NAME=<sound name from /System/Library/Sounds>`
- `DJI_ENABLE_READY_HUD=1|0`

## Troubleshooting

Debug log: `cat /tmp/dji-dictation/debug.log`

If the user reports issues, check these in order:

1. **Button does nothing** → Karabiner needs **Input Monitoring** permission. Check System Settings → Privacy & Security → Input Monitoring.
2. **Optional hardware button changes volume instead of triggering dictation** → The optional DJI trigger mode was not enabled, or the device is not grabbed. Verify `"is_consumer": true, "ignore": false` in karabiner.json devices when the optional trigger is enabled.
3. **No sound / no ready overlay after dictation** → `/usr/bin/osascript` or the terminal app needs **Accessibility** permission. Check System Settings → Privacy & Security → Accessibility.
4. **Sound plays but overlay doesn't appear** → The ready overlay requires a compiled Swift binary. Run `npx github:Johnixr/dji-mic-dictation update` to refresh. Some Electron apps (like Feishu/Lark) have invisible overlay windows; the script already filters for `AXStandardWindow`.
5. **CLI reports missing Typeless DB** → Typeless is not installed or has never been opened. Install/open Typeless once, then rerun `npx github:Johnixr/dji-mic-dictation install` or `npx github:Johnixr/dji-mic-dictation doctor`.
6. **Enter doesn't send** → Terminal app (iTerm2 / Terminal.app) needs **Accessibility** permission.

### Required permissions checklist

All in **System Settings → Privacy & Security**:

- **Input Monitoring**: Karabiner-Elements, karabiner_grabber
- **Accessibility**: Karabiner-Elements, terminal app (iTerm2 / Terminal.app)
- **Dictation**: System Settings → Keyboard → Dictation → On
