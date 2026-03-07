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

<!-- TODO: 替换为京东推广链接 -->
[京东购买](https://item.jd.com/TODO)

10g 重量，夹领口上无感，400 米传输距离，主动降噪，单发射器约 195 元。

### 第二步：装 Typeless（推荐）

[Typeless](https://www.typeless.com/?via=john-yin) 在 macOS 听写之上加了一层 LLM 智能编辑，自动去除口头禅、修正口误、整理格式，中英文混合也能搞定。

免费版每周 4000 字，Pro 版 $12/月。

### 第三步：把指令粘贴给你的 AI

复制上面的指令，粘贴到 Claude Code 或你常用的 AI 助手里，搞定。

## 工作原理

```
按 1 下 → Fn（开始听写）→ 随便说多久
按 2 下 → Fn（结束听写）→ 3 秒倒计时开始
         → "Tink" 提示音 + 窗口震动 = 发送窗口打开
按 3 下 → Enter（发送给 App）→ AI 开始干活

没按？ → 6 秒后自动重置，无副作用
```

一个物理按钮，三种虚拟动作，时间窗口状态机驱动。

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

## 调试

```bash
cat /tmp/dji-dictation/debug.log
```

## 许可

MIT

## 致谢

由 [Johnixr](https://github.com/Johnixr) 和 [notdp](https://github.com/notdp) 共同创建。

使用 [Claude Code](https://claude.ai/claude-code) 纯语音 Vibe Coding 构建。
