# Spokenly 集成设计

**日期:** 2026-03-30
**状态:** 草稿
**作者:** Claude + User

## 背景

DJI Mic Mini 听写目前使用 **Typeless** 作为唯一的转录引擎。Typeless 在 macOS 听写功能之上添加了一个 LLM 层,用于清理语音、去除填充词、修复语法并无缝处理中英文混合。

**Spokenly** 是另一个提供类似 AI 语音清理功能的转录应用。与 Typeless 类似,Spokenly:
- **支持 Fn 键直接触发**(在 Spokenly 应用设置中配置)
- 采用相同的三按键工作流:Fn → 开始,Fn → 结束,Fn → 发送
- 将转录内容以 JSON 文件形式存储在 `~/Library/Application Support/Spokenly/History/YYYY-MM-DD/`
- 每个转录文件包含处理后的文本、AI 提示和音频元数据
- 同时运行本地 MCP API 服务器于 `localhost:51089`(用于 AI 代理集成,用户工作流无需此功能)

**目标:** 支持 Typeless 和 Spokenly 作为同等选项,允许用户在安装时选择。

## 设计目标

1. **双引擎支持:** Typeless 和 Spokenly 作为同等选项
2. **零外部依赖:** 不需要 fswatch 或其他工具
3. **实时检测:** 保持约 100ms 轮询间隔(与当前 Typeless 实现相同)
4. **向后兼容:** 现有 Typeless 用户不受影响
5. **优雅降级:** 转录引擎故障时具备健壮的错误处理

## 架构概览

### 当前系统(仅 Typeless)

```
Fn 按键第 1 下 → 开始听写
  → Karabiner 触发 dictation-enter.sh (save 命令)
  → macOS 听写启动 → Typeless 自动介入
  → 用户说话...
Fn 按键第 2 下 → 结束听写
  → Karabiner 触发 dictation-enter.sh (watch 命令)
  → macOS 听写结束 → Typeless 写入 SQLite 数据库
  → 脚本轮询 Typeless 数据库(每 100ms)
  → 检测到新记录 → 提取文本 → 显示覆盖层
Fn 按键第 3 下 → 发送 Enter
  → Karabiner 触发 dictation-enter.sh (confirm 命令)
  → 发送 Enter 到当前最前台应用
```

### 新系统(双引擎)

```
Fn 按键第 1 下 → 开始听写
  → Karabiner 触发 dictation-enter.sh (save 命令)
  → Typeless: macOS 听写启动 → Typeless 介入
  → Spokenly: Spokenly 直接开始录音
  → 用户说话...
Fn 按键第 2 下 → 结束听写
  → Karabiner 触发 dictation-enter.sh (watch 命令)
  → Typeless: macOS 听写结束 → Typeless 写入 SQLite 数据库
  → Spokenly: Spokenly 停止录音 → 写入 JSON 文件
  → 脚本轮询引擎(Typeless 用数据库,Spokenly 用文件)
  → 检测到新转录 → 提取文本 → 显示覆盖层
Fn 按键第 3 下 → 发送 Enter
  → Karabiner 触发 dictation-enter.sh (confirm 命令)
  → 发送 Enter 到当前最前台应用
```

### 引擎选择流程

```
安装 CLI
  → 询问用户:"选择转录引擎"
  → 选项:[Typeless, Spokenly](同等,无默认值)
  → 检查引擎可用性
  → 将选择写入 ~/.config/dji-mic-dictation/config.env
  → 配置脚本使用选定的引擎
```

## 实现细节

### 1. 配置管理

**文件:** `~/.config/dji-mic-dictation/config.env`

添加新参数:
```bash
TRANSCRIPTION_ENGINE=spokenly  # 或 'typeless'
```

**CLI 变更 (cli/lib/config.mjs):**
- 将 `transcriptionEngine` 添加到配置模式
- 默认值:无默认值(用户必须选择)
- 验证:必须是 'typeless' 或 'spokenly'

### 2. Spokenly 检测方法

#### 重要发现: Spokenly 的两种转录模式

通过实际验证发现,Spokenly 的 JSON 文件有两种结构:

| 模式 | JSON 结构 | 文本提取路径 | 适用场景 |
|-----|----------|------------|---------|
| **AI 增强模式** | 有 `conversation` 字段 | `conversation.messages[2].content.value` | 用户配置了 AI prompt |
| **快速转录模式** | 只有 `transcriptionData` 字段 | `result.transcriptionData.segments[0].text` | 未配置 AI prompt |

**示例对比:**

AI 增强模式:
```json
{
  "content": {
    "dictation": {
      "_0": {
        "success": {
          "_0": {
            "conversation": {
              "messages": [
                {"role": "system", ...},
                {"role": "user", ...},
                {"role": "assistant", "content": {"value": "AI 处理后的文本"}}
              ]
            },
            "result": {...}
          }
        }
      }
    }
  }
}
```

快速转录模式:
```json
{
  "content": {
    "dictation": {
      "_0": {
        "success": {
          "_0": {
            "result": {
              "transcriptionData": {
                "segments": [{"text": "原始转录文本"}]
              }
            }
          }
        }
      }
    }
  }
}
```

脚本需要兼容两种模式,优先提取 AI 处理后的文本(更智能),降级到原始转录文本。

#### 策略:文件时间戳轮询 + Python JSON 解析

**选择此方法的原因:**
- 无需 fswatch 依赖(使用纯 Bash + macOS 兼容命令)
- 快速轮询(仅通过 `stat` 检查文件时间戳,非完整解析)
- 与 Typeless 相同的 100ms 间隔(保持实时感)
- 文件系统问题时具备健壮降级
- macOS 兼容性:使用 `stat -f "%m"` 替代 Linux 特有的 `find -printf`

#### 实现函数

**函数: `spokenly_get_today_dir()`**
```bash
spokenly_get_today_dir() {
    echo "$HOME/Library/Application Support/Spokenly/History/$(date +%Y-%m-%d)"
}
```

**函数: `spokenly_latest_json_mtime()`**
```bash
spokenly_latest_json_mtime() {
    local date_dir
    date_dir="$(spokenly_get_today_dir)"
    # 使用 macOS 兼容的 stat 命令获取最新文件的修改时间戳
    # stat -f "%m" 返回 Unix 纪元秒数
    stat -f "%m" "$date_dir"/*.json 2>/dev/null | sort -rn | head -1
}
```

**函数: `spokenly_check_new_file()`**
```bash
spokenly_check_new_file() {
    local anchor_mtime="$1"
    [ -z "$anchor_mtime" ] && return 1

    local current_mtime
    current_mtime="$(spokenly_latest_json_mtime)"

    # 如果 current_mtime > anchor_mtime 则返回 true
    [ -n "$current_mtime" ] && awk -v cur="$current_mtime" -v anc="$anchor_mtime" 'BEGIN { exit !(cur > anc) }'
}
```

**函数: `spokenly_find_latest_json()`**
```bash
spokenly_find_latest_json() {
    local date_dir
    date_dir="$(spokenly_get_today_dir)"
    # 按修改时间查找最新的 JSON 文件
    # 使用 ls -t 按时间排序,取第一个
    ls -t "$date_dir"/*.json 2>/dev/null | head -1
}
```

**函数: `spokenly_extract_text()`**
```bash
spokenly_extract_text() {
    local json_file="$1"
    [ -z "$json_file" ] && return 1

    "$PYTHON3_BIN" - <<'PY' "$json_file"
import json, sys

try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)

    dictation = data.get('content', {}).get('dictation', {})
    if not dictation:
        sys.exit(1)

    first_key = next(iter(dictation), None)
    if not first_key:
        sys.exit(1)

    success = dictation[first_key].get('success', {})
    if not success:
        sys.exit(1)

    first_success_key = next(iter(success), None)
    if not first_success_key:
        sys.exit(1)

    # 优先尝试 AI 增强模式(conversation)
    # Spokenly 有两种转录模式:
    # 1. AI 增强模式: 有 conversation 字段,包含 AI 处理后的最终文本
    # 2. 快速转录模式: 只有 transcriptionData,包含原始转录文本
    if 'conversation' in success[first_success_key]:
        conversation = success[first_success_key].get('conversation', {})
        messages = conversation.get('messages', [])
        # 查找助手消息(role='assistant')
        # 通常 messages[2] 是包含最终文本的助手响应
        for msg in messages:
            if msg.get('role') == 'assistant':
                content = msg.get('content', {})
                text = content.get('value', '')
                if text:
                    print(text)
                    sys.exit(0)

    # 降级到快速转录模式(transcriptionData)
    if 'result' in success[first_success_key]:
        result = success[first_success_key].get('result', {})
        transcription_data = result.get('transcriptionData', {})
        segments = transcription_data.get('segments', [])
        if segments:
            text = segments[0].get('text', '')
            if text:
                print(text)
                sys.exit(0)

    sys.exit(1)
except Exception:
    sys.exit(1)
PY
}
```

#### 轮询循环(Spokenly 模式)

```bash
# 在 watch 命令中,gui 模式且 TRANSCRIPTION_ENGINE=spokenly
if [ "$TRANSCRIPTION_ENGINE" = "spokenly" ]; then
    anchor_mtime="$(spokenly_latest_json_mtime)"
    [ -z "$anchor_mtime" ] && anchor_mtime=0

    log "watch mode=gui engine=spokenly anchor_mtime=${anchor_mtime} polling"

    changed=0 i=0
    while [ $i -lt "$WATCH_MAX_POLLS" ]; do
        session_is_current "$watch_session_id" || exit 0
        /bin/sleep "$WATCH_POLL_INTERVAL"  # 100ms
        i=$((i + 1))
        session_is_current "$watch_session_id" || exit 0

        # 快速检查:是否有新 JSON 文件?
        if spokenly_check_new_file "$anchor_mtime"; then
            # 慢速步骤:解析 JSON(仅一次)
            latest_json="$(spokenly_find_latest_json)"
            if [ -n "$latest_json" ]; then
                final_text="$(spokenly_extract_text "$latest_json")"
                if [ -n "$final_text" ]; then
                    changed=1 && break
                fi
            fi
        fi
    done

    if [ $changed -eq 1 ]; then
        # 与 Typeless 相同的流程:显示覆盖层,等待确认
        log "watch spokenly transcript_detected (${i} polls ~$((i / 10))s)"
        if wait_for_pending_confirm; then
            # 立即发送 Enter
            send_current_mode_enter "watch spokenly preconfirm"
        else
            # 进入准备窗口(显示倒计时覆盖层)
            enter_ready_window spokenly "$i" 0 "$watch_session_id"
        fi
    fi
fi
```

### 3. CLI 安装流程

**文件:** `cli/lib/actions.mjs`

**函数: `collectTranscriptionEngine()`**
```javascript
async function collectTranscriptionEngine(runtime, interactive) {
    // 首先检查现有配置
    const manifest = await readManifest(runtime);
    if (manifest?.transcriptionEngine) {
        return { engine: manifest.transcriptionEngine, reused: true };
    }

    // 询问用户(无默认值,平等选择)
    const engine = await select({
        message: '选择转录引擎',
        initialValue: null,  // 强制用户选择
        options: [
            {
                value: 'typeless',
                label: 'Typeless',
                hint: 'LLM 驱动清理,SQLite 数据库'
            },
            {
                value: 'spokenly',
                label: 'Spokenly',
                hint: 'AI 转录,JSON 文件历史'
            }
        ]
    });

    if (isCancel(engine)) {
        cancel('已取消');
        process.exit(1);
    }

    return { engine, reused: false };
}
```

**函数: `checkEngineAvailability()`**
```javascript
async function checkEngineAvailability(runtime, engine) {
    if (engine === 'typeless') {
        const typelessDb = runtime.typelessDbPath;
        const exists = await pathExists(typelessDb);
        if (!exists) {
            throw createCliError(
                '未找到 Typeless 数据库。请安装 Typeless 并打开一次。',
                'TYPELESS_DB_MISSING'
            );
        }
    } else if (engine === 'spokenly') {
        const spokenlyDir = path.join(
            runtime.homeDir,
            'Library/Application Support/Spokenly'
        );
        const exists = await pathExists(spokenlyDir);
        if (!exists) {
            throw createCliError(
                '未找到 Spokenly。请安装 Spokenly 并打开一次。',
                'SPOKENLY_DIR_MISSING'
            );
        }

        // 检查 Spokenly MCP 服务器是否运行
        try {
            await execFile('curl', ['-s', '--max-time', '1', 'http://localhost:51089']);
        } catch {
            // 非关键,但警告用户
            note(
                '未检测到 Spokenly MCP 服务器。基于文件的检测仍将工作。',
                'Spokenly 状态'
            );
        }
    }
}
```

**安装流程集成:**
```javascript
async function install(runtime, options) {
    const engine = options.transcriptionEngine || await collectTranscriptionEngine(runtime);

    await checkEngineAvailability(runtime, engine);

    // 写入配置
    const config = {
        transcriptionEngine: engine,
        ...options.configOverrides
    };
    await writeConfig(runtime, config);

    // 写入清单
    await writeManifest(runtime, {
        transcriptionEngine: engine,
        triggerMode: options.triggerMode,
        profileName: result.profileName,
        installedVersion: runtime.packageVersion
    });

    // ... 其余安装逻辑
}
```

### 4. Doctor 命令增强

**文件:** `cli/lib/actions.mjs`

将引擎状态添加到 doctor 报告:
```javascript
async function doctor(runtime) {
    const config = await loadConfig(runtime);
    const engine = config.transcriptionEngine || 'typeless';

    let engineStatus;
    if (engine === 'typeless') {
        engineStatus = {
            name: 'Typeless',
            dbExists: await pathExists(runtime.typelessDbPath)
        };
    } else {
        const spokenlyDir = path.join(
            runtime.homeDir,
            'Library/Application Support/Spokenly'
        );
        const historyDir = path.join(spokenlyDir, 'History');
        const todayDir = path.join(historyDir, new Date().toISOString().split('T')[0]);

        engineStatus = {
            name: 'Spokenly',
            dirExists: await pathExists(spokenlyDir),
            historyExists: await pathExists(historyDir),
            todayHasFiles: await hasJsonFiles(todayDir),
            mcpRunning: await checkMcpServer()
        };
    }

    return {
        ...existingReport,
        engine: engineStatus
    };
}
```

### 5. 脚本初始化

**文件:** `scripts/dictation-enter.sh`

在脚本开始处添加引擎检测:
```bash
# 加载配置
load_optional_config

# 检测转录引擎
TRANSCRIPTION_ENGINE="${TRANSCRIPTION_ENGINE:-typeless}"  # 默认为 typeless 以向后兼容

# 设置引擎特定路径
if [ "$TRANSCRIPTION_ENGINE" = "spokenly" ]; then
    SPOKENLY_HISTORY_DIR="${SPOKENLY_HISTORY_DIR:-$HOME/Library/Application Support/Spokenly/History}"
    # 日期将在函数中动态计算
fi
```

### 6. Save 命令增强

**文件:** `scripts/dictation-enter.sh`

在 `save` 命令中,记录引擎特定的锚点:
```bash
save)
    # ... 现有模式检测逻辑

    if [ "$TRANSCRIPTION_ENGINE" = "spokenly" ]; then
        # 将当前时间戳保存为锚点
        current_mtime="$(spokenly_latest_json_mtime)"
        write_file spokenly_anchor_mtime "$current_mtime"
        log "save spokenly anchor_mtime=${current_mtime}"
    else
        # 现有 Typeless 逻辑
        anchor_rowid="$(typeless_last_rowid)"
        anchor_updated_at="$(typeless_row_updated_at "$anchor_rowid")"
        write_file db_anchor_rowid "$anchor_rowid"
        write_file db_anchor_updated_at "$anchor_updated_at"
        log "save typeless anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at}"
    fi

    # ... 其余保存逻辑
```

## 错误处理

### Spokenly 特定错误

1. **无 History 目录:**
   ```bash
   if [ ! -d "$SPOKENLY_HISTORY_DIR" ]; then
       log "error spokenly_history_dir_missing"
       exit 1
   fi
   ```

2. **JSON 解析失败:**
   ```bash
   if [ -z "$final_text" ]; then
       log "error spokenly_json_parse_failed file=${latest_json}"
       # 不要退出,继续轮询下一个文件
       anchor_mtime="$current_mtime"  # 更新锚点以避免重复检查
   fi
   ```

3. **日期目录变化(午夜跨天):**
   - 函数每次调用时动态计算 `date +%Y-%m-%d`
   - 无目录路径状态缓存
   - 自动处理午夜转换

### 降级行为

如果 Spokenly 检测超时:
```bash
if [ $i -ge "$WATCH_MAX_POLLS" ]; then
    log "watch spokenly timeout (30s)"
    # 清除状态,优雅退出
    clear_watch_state "$watch_session_id"
    exit 0
fi
```

## 测试策略

### 手动测试

1. **安装流程:**
   ```bash
   npx github:Johnixr/dji-mic-dictation install --transcription-engine spokenly
   ```
   - 验证配置正确写入
   - 验证 Spokenly 可用性检查

2. **听写流程:**
   - 按 Fn,说话,再按 Fn
   - 验证 JSON 文件出现在 History/YYYY-MM-DD/
   - 验证覆盖层在 1-2 秒内出现
   - 按 Fn 发送 Enter

3. **Doctor 检查:**
   ```bash
   npx github:Johnixr/dji-mic-dictation doctor
   ```
   - 验证 Spokenly 状态部分

### 边缘情况

1. **午夜跨天:**
   - 在 23:59:50 开始听写
   - 在 00:00:10 完成
   - 验证脚本在新日期目录中找到 JSON

2. **多个 JSON 文件:**
   - 创建 3 个测试 JSON 文件
   - 验证脚本总是选择最新的(按 mtime)

3. **部分 JSON:**
   - 测试不完整/格式错误的 JSON
   - 验证错误处理,无崩溃

4. **Spokenly 未运行:**
   - 终止 Spokenly 应用
   - 验证脚本在 30s 后超时,无僵尸进程

## 性能考虑

### 轮询开销

**Typeless:**
- 查询: `sqlite3 "$TYPELESS_DB" "SELECT ..."`
- 时间: 每次查询约 5-10ms
- 负载: 最小(SQLite 针对频繁查询优化)

**Spokenly:**
- 查询: `stat -f "%m" "$dir"/*.json | sort -rn | head -1`
- 时间: 约 10-20ms(取决于文件数量)
- 负载: 最小(stat 高效,仅检查元数据)

**对比:**
- 两者均 <20ms 每次轮询
- 100ms 间隔 → 每次轮询约 20% CPU 时间
- 可接受的开销

### JSON 解析

- 仅在检测到新文件时触发(每次听写 1-2 次)
- Python 解析: 约 50-100ms
- 总延迟: 检测(100ms) + 解析(100ms) = 约 200ms
- 在用户容忍范围内(覆盖层在 <1s 内出现)

## 迁移路径

### 现有用户

- **默认行为:** 继续使用 Typeless(向后兼容)
- **迁移:** 运行 `npx github:Johnixr/dji-mic-dictation config` → 选择 Spokenly
- **回滚:** 再次运行 `config` → 选择 Typeless

### 新用户

- **安装:** 必须选择引擎(无默认值)
- **切换:** 随时使用 `config` 命令

## 文档更新

### README.md

添加章节:
```markdown
## 转录引擎选择

此工作流支持两种转录引擎:

| 引擎 | 检测方法 | 数据源 |
|------|---------|--------|
| Typeless | SQLite 数据库轮询 | `~/Library/Application Support/Typeless/typeless.db` |
| Spokenly | JSON 文件轮询 | `~/Library/Application Support/Spokenly/History/YYYY-MM-DD/*.json` |

安装时选择:
```bash
npx github:Johnixr/dji-mic-dictation install
# CLI 将询问:"选择转录引擎"
```

随时切换:
```bash
npx github:Johnixr/dji-mic-dictation config
```
```

### CLAUDE.md

更新验证要求、先决条件、故障排除章节。

## 开放问题

1. **是否应支持"双引擎同时使用"?**
   - 当前设计:一次一个引擎
   - 替代方案:从两者检测,合并结果
   - 决策:保持简单,仅使用一个引擎

2. **是否应向用户暴露 Spokenly MCP?**
   - MCP 用于 AI 代理,非用户工作流
   - 用户工作流:Fn → 听写 → 文件 → 发送
   - 决策:不暴露 MCP,仅使用文件检测

3. **性能优化:缓存日期目录?**
   - 当前:每次轮询重新计算 `date +%Y-%m-%d`
   - 优化:每次脚本调用缓存一次
   - 权衡:处理午夜跨天 vs 速度
   - 决策:不缓存,正确处理午夜

## 实现检查清单

- [ ] 将 `TRANSCRIPTION_ENGINE` 添加到配置模式
- [ ] 在 dictation-enter.sh 中实现 `spokenly_*` 函数
- [ ] 更新 CLI 安装流程(引擎选择)
- [ ] 更新 CLI doctor 命令(引擎状态)
- [ ] 更新 save/watch 命令(引擎分支)
- [ ] 为 Spokenly 检测添加测试
- [ ] 更新 README.md 和 CLAUDE.md
- [ ] 手动测试:端到端流程
- [ ] 边缘情况测试:午夜、错误、超时

## 成功标准

1. **安装:** 用户可在安装时选择 Spokenly
2. **检测:** Spokenly 转录在 1-2 秒内被检测到
3. **可靠性:** 对格式错误的 JSON、缺失文件不崩溃
4. **切换:** 用户可使用 `config` 命令切换引擎
5. **向后兼容:** 现有 Typeless 用户不受影响
6. **性能:** 轮询期间 CPU 开销 <5%