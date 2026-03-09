# DJI Mic Mini Dictation

A keyboard-first dictation/send workflow for macOS. `Fn` is the first-class trigger, and if you have a DJI Mic Mini you can optionally map its hardware button to the same workflow.

Works with any app that accepts text input: Claude Code, WeChat, Feishu/Lark, Telegram, Slack, VS Code, Notes, and more. If you find an app that doesn't work, [open an issue](https://github.com/Johnixr/dji-mic-dictation/issues) or submit a PR!

[中文文档](README_CN.md)

## Install with the CLI

Run the installer directly:

```bash
npx github:Johnixr/dji-mic-dictation install
```

Interactive install now drops straight into cue enrollment: it asks for both the main cue and the cancel cue, then opens the floating recorder panel. If you prefer a single cue or want to script setup, the standalone `wakeword` commands still support omitting `--cancel-cue`.

The installer checks for a connected DJI Mic Mini automatically:

- if detected, it enables the optional hardware trigger on top of the keyboard workflow
- if not detected, it installs the keyboard workflow by default and may ask if you want to preconfigure the optional DJI trigger anyway

Useful follow-up commands:

```bash
npx github:Johnixr/dji-mic-dictation update
npx github:Johnixr/dji-mic-dictation doctor
npx github:Johnixr/dji-mic-dictation config
npx github:Johnixr/dji-mic-dictation uninstall
```

Wake-word enrollment and calibration:

```bash
npx github:Johnixr/dji-mic-dictation wakeword --cue "double hiss"
npx github:Johnixr/dji-mic-dictation wakeword --cue "double hiss" --cancel-cue "double puff"
npx github:Johnixr/dji-mic-dictation wakeword record --cue "double hiss"
npx github:Johnixr/dji-mic-dictation wakeword train
npx github:Johnixr/dji-mic-dictation wakeword doctor
npx github:Johnixr/dji-mic-dictation wakeword start
npx github:Johnixr/dji-mic-dictation wakeword status
npx github:Johnixr/dji-mic-dictation wakeword stop
```

Use the CLI as the default path. If you want an AI assistant to help, have it call the same CLI instead of reimplementing the setup steps.

## Quick start

### Step 1: Install Typeless (required for the current workflow)

[Typeless](https://www.typeless.com/?via=john-yin) adds an LLM layer on top of macOS dictation — it cleans up your speech, removes filler words, fixes grammar, and handles mixed Chinese/English seamlessly.

Free tier: 4,000 characters/week. Pro: $12/month.

### Step 2: Decide if you want an optional hardware trigger

You can use the workflow with the keyboard alone. If you also have a DJI Mic Mini, you can enable it as an optional trigger that mirrors the same `Fn` workflow.

[Buy DJI Mic Mini on JD.com](https://u.jd.com/N61cCGv)

10g, clips to your collar, 400m range, active noise cancellation, ~$27 USD.

### Step 3: Run the installer

```bash
npx github:Johnixr/dji-mic-dictation install
```

## How it works

```
Fn press 1 → start dictation → speak freely, any duration
Fn press 2 → stop dictation → send window opens (ready overlay + sound once text lands)
Fn press 3 → send / Enter to current app → AI starts working

No press? → auto-reset after 4 seconds, no side effects
```

Optional: if you enable the DJI trigger during install, the Mic Mini button mirrors the same workflow.

## Wake-cue Enrollment

The wake-word path is designed around personal sample collection, and now works well for non-lexical vocal cues too. It writes data into `~/.config/dji-mic-dictation/wakeword/`, uses a small floating recorder panel for sample capture, then runs a local log-mel learning backend that drives the same `save/watch/preconfirm/confirm` flow as `Fn`.

Interactive `wakeword setup` now defaults to both a main cue and a cancel cue. It records quiet / clean / noisy positives for each cue, then one shared set of speech, mouth-sound, and ambient negatives that is reused for both classes. Training now applies built-in gain, light speed, time-shift, background-noise mixing, and light spec-mask augmentation to make small personal sample sets more robust. The floating panel follows the current macOS language (Chinese or English), wraps long copy, and keeps the recording loop on `Space to start` / `Space to stop`. `wakeword doctor` reports whether the current sample set is healthy enough, and `wakeword start` launches the background listener after calibration is ready.

## Prerequisites

| Requirement | Notes |
|------------|-------|
| macOS | Tested on macOS Sequoia |
| [Karabiner-Elements](https://karabiner-elements.pqrs.org/) | `brew install --cask karabiner-elements` |
| DJI Mic Mini | Optional hardware trigger; vendor_id: 11427, product_id: 16401 |
| macOS Dictation | System Settings → Keyboard → Dictation → On |
| [Typeless](https://www.typeless.com/?via=john-yin) | Required in the current version because detection relies on the Typeless DB |

## What's in this repo

```
dji-mic-dictation/
├── cli/                           # CLI installer / update / doctor / config / uninstall
├── README.md                      # You're reading this
├── README_CN.md                   # 中文文档
├── CLAUDE.md                      # Instructions for AI assistants
├── AGENTS.md                      # Symlink to CLAUDE.md (for Codex)
├── package.json                   # npm bin entry for the CLI
├── scripts/
│   └── dictation-enter.sh         # Main script (save/tap/enter)
└── karabiner/
    └── dji-mic-mini.json          # Karabiner config to merge
```

## Using a different external trigger?

Find your device's vendor_id and product_id:

```bash
# With Karabiner installed:
'/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli' --list-connected-devices
```

Then update the managed device identifiers and reinstall with `--trigger-mode keyboard+dji`.

## Troubleshooting

Check the debug log first:

```bash
cat /tmp/dji-dictation/debug.log
```

### Checklist if something doesn't work

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| The optional hardware button does nothing | Karabiner can't see the device | Grant **Input Monitoring** permission to Karabiner in System Settings → Privacy & Security |
| The optional hardware button changes volume instead of dictation | The installer did not detect the device when you installed, so only the keyboard workflow was configured | Re-run `npx github:Johnixr/dji-mic-dictation install` with the DJI receiver connected |
| Dictation works but no sound / no ready overlay | Accessibility permission missing | Grant **Accessibility** permission to `/usr/bin/osascript` (or the terminal app running the script) |
| Sound plays but overlay doesn't appear | The ready overlay requires a compiled Swift binary; run `npx github:Johnixr/dji-mic-dictation update` to refresh. Some apps have non-standard windows (e.g. Electron overlay); already handled for Feishu/Lark; [open an issue](https://github.com/Johnixr/dji-mic-dictation/issues) for other apps |
| CLI says Typeless DB is missing | Typeless is not installed or has never been opened | Install Typeless, launch it once, then run `npx github:Johnixr/dji-mic-dictation install` or `npx github:Johnixr/dji-mic-dictation doctor` again |
| Overlay shows but Enter doesn't send | Terminal app needs Accessibility permission | Grant **Accessibility** to your terminal (iTerm2 / Terminal.app) |
| Enter sends to wrong app | Old build or stale install | Run `npx github:Johnixr/dji-mic-dictation update` from the latest repo version |

### Permissions checklist

All of these must be granted in **System Settings → Privacy & Security**:

1. **Input Monitoring** → Karabiner-Elements, karabiner_grabber
2. **Accessibility** → Karabiner-Elements, your terminal app (iTerm2 / Terminal.app)
3. **Dictation** → System Settings → Keyboard → Dictation → On

## License

MIT

## Credits

Created by [Johnixr](https://github.com/Johnixr) and [notdp](https://github.com/notdp).

Built with [Claude Code](https://claude.ai/claude-code) via pure voice-driven Vibe Coding.
