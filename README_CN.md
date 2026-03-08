# DJI Mic Mini 语音听写

把 DJI Mic Mini 变成 macOS 无线听写遥控器。按一下胸口的按钮开始听写，再按一下停止，第三下发送——全程不碰键盘。

适用于任何接受文字输入的 App：Claude Code、微信、飞书、Telegram、Slack、VS Code、备忘录等。如果发现不兼容的软件，欢迎[提 Issue](https://github.com/Johnixr/dji-mic-dictation/issues) 或提交 PR！

[English](README.md)

## 不要手动安装

别去翻配置文件，别去一步步手动设置。

**复制下面这段指令，粘贴给你的 AI 编程助手：**

```
帮我配置 DJI Mic Mini 语音听写，项目在 https://github.com/Johnixr/dji-mic-dictation
```

它会自动完成所有事：安装 Karabiner、复制脚本、合并配置、授权权限。

> 适用于 Claude Code、Codex、Cursor、Windsurf，或任何能读取 URL 的 AI 编程助手。

## 三步上手

### 第一步：买个 DJI Mic Mini

[京东购买](https://u.jd.com/N61cCGv)

10g 重量，夹领口上无感，400 米传输距离，主动降噪，单发射器约 195 元。

### 第二步：装 Typeless（推荐）

[Typeless](https://www.typeless.com/?via=john-yin) 在 macOS 听写之上加了一层 LLM 智能编辑，自动去除口头禅、修正口误、整理格式，中英文混合也能搞定。

免费版每周 4000 字，Pro 版 $12/月。

### 第三步：把指令粘贴给你的 AI

复制上面的指令，粘贴到 Claude Code 或你常用的 AI 助手里，搞定。

## 工作原理

```
按 1 下 → Fn（开始听写）→ 随便说多久
按 2 下 → Fn（结束听写）→ 轮询检测文字输入
         → 文字上屏 → "Tink" 提示音 + 窗口震动 = 发送窗口打开
按 3 下 → Enter（发送到当前 App）→ AI 开始干活

没按？ → 3 秒后自动重置，无副作用
```

一个物理按钮，三种虚拟动作，自适应文字检测驱动。

## 前置条件

| 需求 | 说明 |
|------|------|
| macOS | 已在 macOS Sequoia 上验证 |
| [Karabiner-Elements](https://karabiner-elements.pqrs.org/) | `brew install --cask karabiner-elements` |
| DJI Mic Mini | vendor_id: 11427, product_id: 16401 |
| macOS 听写 | 系统设置 → 键盘 → 听写 → 开启 |
| [Typeless](https://www.typeless.com/?via=john-yin) | 可选，但强烈推荐 |

## 用的是其他麦克风？

查你设备的 vendor_id 和 product_id：

```bash
'/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli' --list-connected-devices
```

然后告诉你的 AI 助手用你的设备 ID 更新配置。

## 问题排查

先看调试日志：

```bash
cat /tmp/dji-dictation/debug.log
```

### 不工作时的排查清单

| 现象 | 可能原因 | 解决方法 |
|------|---------|---------|
| 按按钮没反应 | Karabiner 看不到设备 | 系统设置 → 隐私与安全 → 输入监控，给 Karabiner 授权 |
| 按按钮只调音量 | 设备未在 Karabiner 中配置 | 确认 karabiner.json 的 devices 里有 `"is_consumer": true, "ignore": false` |
| 听写正常但没有提示音/窗口不抖 | 缺少辅助功能权限 | 系统设置 → 隐私与安全 → 辅助功能，给 `/usr/bin/osascript` 或终端 App 授权 |
| 有提示音但窗口不抖 | App 有非标准窗口（如 Electron 水印层） | 飞书已适配；其他 App 欢迎[提 Issue](https://github.com/Johnixr/dji-mic-dictation/issues) |
| 日志一直显示 `baseline=-1` | pyobjc 未安装或 python 路径错误 | 执行 `pip install pyobjc-core pyobjc-framework-Cocoa pyobjc-framework-ApplicationServices`，更新脚本中的 `PYTHON3=` 路径 |
| 窗口抖了但 Enter 没发出去 | 终端 App 缺少辅助功能权限 | 系统设置 → 隐私与安全 → 辅助功能，给 iTerm2 / Terminal.app 授权 |

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
