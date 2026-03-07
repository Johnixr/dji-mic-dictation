# DJI Mic Mini Dictation

Turn your DJI Mic Mini into a wireless dictation remote for macOS. Press the button on your chest to start dictation, press again to stop, and one more press to send — all without touching your keyboard.

Works with any app that accepts text input: Claude Code, WeChat, Feishu/Lark, Telegram, Slack, VS Code, Notes, and more. If you find an app that doesn't work, [open an issue](https://github.com/Johnixr/dji-mic-dictation/issues) or submit a PR!

[中文文档](README_CN.md)

## Don't install this manually

Seriously, don't read through all these config files and try to set them up by hand.

**Copy this command and paste it to your AI coding assistant:**

```
Set up DJI Mic Mini dictation for me, project at https://github.com/Johnixr/dji-mic-dictation
```

It will handle everything: install Karabiner, copy scripts, merge configs, grant permissions. That's the whole point.

> Works with Claude Code, Codex, Cursor, Windsurf, or any AI coding assistant that can read URLs.

## 3 Steps to Vibe Coding

### Step 1: Get a DJI Mic Mini

Buy a DJI Mic Mini wireless microphone. You only need one transmitter + receiver.

<!-- TODO: Add JD.com affiliate link -->
[Buy on JD.com](https://item.jd.com/TODO)

10g, clips to your collar, 400m range, active noise cancellation, ~$27 USD.

### Step 2: Get Typeless (optional but recommended)

[Typeless](https://www.typeless.com/?via=john-yin) adds an LLM layer on top of macOS dictation — it cleans up your speech, removes filler words, fixes grammar, and handles mixed Chinese/English seamlessly.

Free tier: 4,000 characters/week. Pro: $12/month.

### Step 3: Send this repo to your AI

Copy and paste the command above into your AI assistant. Done.

## How it works

```
Press 1 → Fn (start dictation) → speak freely, any duration
Press 2 → Fn (stop dictation) → 3 second countdown starts
         → "Tink" sound + window shake = send window is open
Press 3 → Enter (send to app) → AI starts working

No press? → auto-reset after 6 seconds, no side effects
```

One physical button, three virtual actions, powered by a time-window state machine.

## Prerequisites

| Requirement | Notes |
|------------|-------|
| macOS | Tested on macOS Sequoia |
| [Karabiner-Elements](https://karabiner-elements.pqrs.org/) | `brew install --cask karabiner-elements` |
| DJI Mic Mini | vendor_id: 11427, product_id: 16401 |
| macOS Dictation | System Settings → Keyboard → Dictation → On |
| [Typeless](https://www.typeless.com/?via=john-yin) | Optional, but highly recommended for accuracy |

## What's in this repo

```
dji-mic-dictation/
├── README.md                      # You're reading this
├── README_CN.md                   # 中文文档
├── CLAUDE.md                      # Instructions for AI assistants
├── scripts/
│   └── dictation-enter.sh         # Main script (save/tap/enter)
└── karabiner/
    └── dji-mic-mini.json          # Karabiner config to merge
```

## Using a different wireless mic?

Find your device's vendor_id and product_id:

```bash
# With Karabiner installed:
'/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli' --list-connected-devices
```

Then tell your AI assistant to update the config with your device's IDs.

## Debugging

```bash
cat /tmp/dji-dictation/debug.log
```

## License

MIT

## Credits

Created by [Johnixr](https://github.com/Johnixr) and [notdp](https://github.com/notdp).

Built with [Claude Code](https://claude.ai/claude-code) via pure voice-driven Vibe Coding.
