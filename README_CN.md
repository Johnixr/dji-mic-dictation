# DJI Mic Mini 语音听写

这是一个以键盘工作流为核心的 macOS 听写/发送方案。`Fn` 是一等触发器；如果你有 DJI Mic Mini，也可以把它的硬件按钮作为可选触发器，映射到同一套流程。

适用于任何接受文字输入的 App：Claude Code、微信、飞书、Telegram、Slack、VS Code、备忘录等。如果发现不兼容的软件，欢迎[提 Issue](https://github.com/Johnixr/dji-mic-dictation/issues) 或提交 PR！

[English](README.md)

## 用 CLI 安装

直接运行安装器：

```bash
npx github:Johnixr/dji-mic-dictation install
```

交互式 `install` 现在会在安装完成后直接进入提示音录制：默认同时要求主提示音和取消提示音，然后立刻弹出浮窗开始录样。如果你只想用单 cue，或者要走脚本化流程，独立的 `wakeword` 命令仍然支持不传 `--cancel-cue`。

安装器会自动检查是否接了 DJI Mic Mini：

- 如果检测到了，就会在 keyboard workflow 之上自动启用可选的硬件触发器
- 如果没检测到，就默认安装 keyboard workflow，并在交互式安装时询问你是否要顺手把可选 DJI 触发器也预配置好

常用后续命令：

```bash
npx github:Johnixr/dji-mic-dictation update
npx github:Johnixr/dji-mic-dictation doctor
npx github:Johnixr/dji-mic-dictation config
npx github:Johnixr/dji-mic-dictation uninstall
```

唤醒词录音与校准：

```bash
npx github:Johnixr/dji-mic-dictation wakeword --cue "轻嘶两下"
npx github:Johnixr/dji-mic-dictation wakeword --cue "轻嘶两下" --cancel-cue "轻噗一下"
npx github:Johnixr/dji-mic-dictation wakeword record --cue "轻嘶两下"
npx github:Johnixr/dji-mic-dictation wakeword train
npx github:Johnixr/dji-mic-dictation wakeword doctor
npx github:Johnixr/dji-mic-dictation wakeword start
npx github:Johnixr/dji-mic-dictation wakeword status
npx github:Johnixr/dji-mic-dictation wakeword stop
```

默认走 CLI。AI 助手如果要帮你配置，也应该调用这套 CLI，而不是自己重新拼安装步骤。

## 三步上手

### 第一步：装 Typeless（当前版本必需）

[Typeless](https://www.typeless.com/?via=john-yin) 在 macOS 听写之上加了一层 LLM 智能编辑，自动去除口头禅、修正口误、整理格式，中英文混合也能搞定。

免费版每周 4000 字，Pro 版 $12/月。

### 第二步：决定是否启用可选硬件触发器

你完全可以只用键盘工作流。如果你有 DJI Mic Mini，也可以把它启用成一个可选硬件触发器，映射到同一套 `Fn` 工作流。

[京东购买 DJI Mic Mini](https://u.jd.com/N61cCGv)

10g 重量，夹领口上无感，400 米传输距离，主动降噪，单发射器约 195 元。

### 第三步：运行安装器

```bash
npx github:Johnixr/dji-mic-dictation install
```

## 工作原理

```
Fn 第 1 下 → 开始听写 → 随便说多久
Fn 第 2 下 → 结束听写 → 发送窗口打开（就绪浮层 + 文字上屏后提示音）
Fn 第 3 下 → 发送 / Enter 到当前 App → AI 开始干活

没按？ → 4 秒后自动重置，无副作用
```

如果在安装时启用了 DJI 触发器，那么 Mic Mini 按钮会镜像这套同样的流程。

## 唤醒 cue 录样

唤醒词这条路径单独围绕“个人样本采集”设计，现在也适合非文字的 vocal cue。样本会写到 `~/.config/dji-mic-dictation/wakeword/`，录音时会弹出一个很小的浮窗，提供录音状态和时间进度；训练后会启动一个本地 log-mel 学习型 listener，直接驱动现有 `save/watch/preconfirm/confirm` 状态机。

交互式 `wakeword setup` 现在默认同时录主提示音和取消提示音。两套 cue 各录轻声 / 干净 / 带噪声正样本，但无关说话声、其他口腔声、环境静音这三类负样本只录一套，会被两套 cue 共用。训练阶段会自动做增益、轻微变速、时移、背景噪声混合和轻量 spec-mask 增广，提升少样本下的鲁棒性。浮窗会根据当前 macOS 语言切成中文或英文，并且支持英文长文案换行；整个录音交互保持 `Space 开始 / Space 结束`。换了房间、麦克风或者噪声条件后，用 `wakeword doctor` 看是否需要补录和重新校准；校准完成后用 `wakeword start` 启动后台监听。

## 前置条件

| 需求 | 说明 |
|------|------|
| macOS | 已在 macOS Sequoia 上验证 |
| [Karabiner-Elements](https://karabiner-elements.pqrs.org/) | `brew install --cask karabiner-elements` |
| DJI Mic Mini | 可选硬件触发器；vendor_id: 11427, product_id: 16401 |
| macOS 听写 | 系统设置 → 键盘 → 听写 → 开启 |
| [Typeless](https://www.typeless.com/?via=john-yin) | 当前版本必需，因为检测依赖 Typeless DB |

## 仓库里有什么

```
dji-mic-dictation/
├── cli/                           # CLI 安装 / update / doctor / config / uninstall
├── README.md                      # 英文文档
├── README_CN.md                   # 你正在看的中文文档
├── CLAUDE.md                      # 给 AI 助手看的说明
├── AGENTS.md                      # 给 Codex 的软链
├── package.json                   # npm bin 入口
├── scripts/
│   └── dictation-enter.sh         # 主脚本
└── karabiner/
    └── dji-mic-mini.json          # Karabiner 规则模板
```

## 用的是其他外部触发器？

查你设备的 vendor_id 和 product_id：

```bash
'/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli' --list-connected-devices
```

然后更新受管设备 ID，并用 `--trigger-mode keyboard+dji` 重新安装。

## 问题排查

先看调试日志：

```bash
cat /tmp/dji-dictation/debug.log
```

### 不工作时的排查清单

| 现象 | 可能原因 | 解决方法 |
|------|---------|---------|
| 可选硬件按钮没反应 | Karabiner 看不到设备 | 系统设置 → 隐私与安全 → 输入监控，给 Karabiner 授权 |
| 可选硬件按钮只调音量 | 安装时没有检测到设备，所以只配置了 keyboard workflow | 把 DJI 接收器插上后重新执行 `npx github:Johnixr/dji-mic-dictation install` |
| 听写正常但没有提示音/浮层不出现 | 缺少辅助功能权限 | 系统设置 → 隐私与安全 → 辅助功能，给 `/usr/bin/osascript` 或终端 App 授权 |
| 有提示音但浮层不出现 | 就绪浮层需要编译 Swift 二进制；执行 `npx github:Johnixr/dji-mic-dictation update` 刷新。部分 App 有非标准窗口（如 Electron 水印层），飞书已适配；其他 App 欢迎[提 Issue](https://github.com/Johnixr/dji-mic-dictation/issues) |
| CLI 提示找不到 Typeless DB | Typeless 没安装或还没打开过 | 安装 Typeless，至少打开一次，再重新执行 `npx github:Johnixr/dji-mic-dictation install` 或 `npx github:Johnixr/dji-mic-dictation doctor` |
| 浮层出现但 Enter 没发出去 | 终端 App 缺少辅助功能权限 | 系统设置 → 隐私与安全 → 辅助功能，给 iTerm2 / Terminal.app 授权 |
| 发送逻辑不对或者还是旧脚本 | 已安装版本太旧 | 拉最新仓库后执行 `npx github:Johnixr/dji-mic-dictation update` |

### 权限清单

以下权限都需要在**系统设置 → 隐私与安全**中授予：

1. **输入监控** → Karabiner-Elements、karabiner_grabber
2. **辅助功能** → Karabiner-Elements、你的终端 App（iTerm2 / Terminal.app）
3. **听写** → 系统设置 → 键盘 → 听写 → 开启

## 许可

MIT

## 致谢

由 [Johnixr](https://github.com/Johnixr) 和 [notdp](https://github.com/notdp) 共同创建。

使用 [Claude Code](https://claude.ai/claude-code) 纯语音 Vibe Coding 构建。
