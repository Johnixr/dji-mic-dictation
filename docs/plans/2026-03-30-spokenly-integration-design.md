# Spokenly Integration Design

**Date:** 2026-03-30
**Status:** Draft
**Authors:** Claude + User

## Background

DJI Mic Mini Dictation currently uses **Typeless** as the sole transcription engine. Typeless adds an LLM layer on top of macOS dictation to clean up speech, remove filler words, fix grammar, and handle mixed Chinese/English seamlessly.

**Spokenly** is another transcription app that offers similar AI-powered speech cleanup features. Unlike Typeless, Spokenly:
- Runs a local HTTP API server (MCP - Model Context Protocol) on `localhost:51089`
- Stores transcripts as JSON files in `~/Library/Application Support/Spokenly/History/YYYY-MM-DD/`
- Each transcript contains processed text, AI prompts, and audio metadata
- MCP API is designed for AI agents to **trigger** dictation (not for passive detection)

**Goal:** Support both Typeless and Spokenly as equal alternatives, allowing users to choose during installation.

## Design Goals

1. **Dual-engine support:** Typeless and Spokenly as equal options
2. **Zero external dependencies:** No need for fswatch or additional tools
3. **Real-time detection:** Maintain ~100ms polling interval (same as current Typeless implementation)
4. **Backward compatibility:** Existing Typeless users unaffected
5. **Graceful degradation:** Robust error handling if transcription engine fails

## Architecture Overview

### Current System (Typeless-only)

```
User presses Fn/DJI button
  → Karabiner triggers dictation-enter.sh
  → macOS dictation starts
  → Typeless processes speech
  → Script polls Typeless SQLite DB (every 100ms)
  → New record detected → Extract text → Show overlay → Send Enter
```

### New System (Dual-engine)

```
User presses Fn/DJI button
  → Karabiner triggers dictation-enter.sh
  → macOS dictation starts
  → Selected engine processes speech (Typeless OR Spokenly)
  → Script polls engine (DB for Typeless, files for Spokenly)
  → New transcript detected → Extract text → Show overlay → Send Enter
```

### Engine Selection Flow

```
Install CLI
  → Ask user: "Choose transcription engine"
  → Options: [Typeless, Spokenly] (equal, no default)
  → Check engine availability
  → Write choice to ~/.config/dji-mic-dictation/config.env
  → Configure script to use selected engine
```

## Implementation Details

### 1. Configuration Management

**File:** `~/.config/dji-mic-dictation/config.env`

Add new parameter:
```bash
TRANSCRIPTION_ENGINE=spokenly  # or 'typeless'
```

**CLI Changes (cli/lib/config.mjs):**
- Add `transcriptionEngine` to config schema
- Default: no default (user must choose)
- Validation: must be 'typeless' or 'spokenly'

### 2. Spokenly Detection Method

#### Strategy: File Timestamp Polling + Python JSON Parsing

**Why this approach:**
- No fswatch dependency (uses pure Bash + find)
- Fast polling (only checks file timestamps, not full parsing)
- Same 100ms interval as Typeless (maintains real-time feel)
- Robust fallback if file system issues

#### Implementation Functions

**Function: `spokenly_get_today_dir()`**
```bash
spokenly_get_today_dir() {
    echo "$HOME/Library/Application Support/Spokenly/History/$(date +%Y-%m-%d)"
}
```

**Function: `spokenly_latest_json_mtime()`**
```bash
spokenly_latest_json_mtime() {
    local date_dir
    date_dir="$(spokenly_get_today_dir)"
    # Find all JSON files, print modification time (seconds since epoch)
    # Sort descending, take the newest
    find "$date_dir" -name "*.json" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1
}
```

**Function: `spokenly_check_new_file()`**
```bash
spokenly_check_new_file() {
    local anchor_mtime="$1"
    [ -z "$anchor_mtime" ] && return 1

    local current_mtime
    current_mtime="$(spokenly_latest_json_mtime)"

    # Return true if current_mtime > anchor_mtime
    [ -n "$current_mtime" ] && awk -v cur="$current_mtime" -v anc="$anchor_mtime" 'BEGIN { exit !(cur > anc) }'
}
```

**Function: `spokenly_find_latest_json()`**
```bash
spokenly_find_latest_json() {
    local date_dir
    date_dir="$(spokenly_get_today_dir)"
    # Find newest JSON file by modification time
    find "$date_dir" -name "*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}'
}
```

**Function: `spokenly_extract_text()`**
```bash
spokenly_extract_text() {
    local json_file="$1"
    [ -z "$json_file" ] && return 1

    "$PYTHON3_BIN" - <<'PY' "$json_file"
import json, sys

try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)

    # Navigate JSON structure:
    # content.dictation._0.success._0.conversation.messages[2].content.value
    dictation = data.get('content', {}).get('dictation', {})
    if not dictation:
        sys.exit(1)

    # Handle both possible structures
    first_key = next(iter(dictation), None)
    if not first_key:
        sys.exit(1)

    success = dictation[first_key].get('success', {})
    if not success:
        sys.exit(1)

    first_success_key = next(iter(success), None)
    if not first_success_key:
        sys.exit(1)

    conversation = success[first_success_key].get('conversation', {})
    messages = conversation.get('messages', [])

    # Find assistant message (role='assistant')
    # Usually messages[2] is the assistant's response with final text
    for msg in messages:
        if msg.get('role') == 'assistant':
            content = msg.get('content', {})
            text = content.get('value', '')
            if text:
                print(text)
                sys.exit(0)

    sys.exit(1)
except Exception:
    sys.exit(1)
PY
}
```

#### Polling Loop (Spokenly Mode)

```bash
# In watch command, gui mode with TRANSCRIPTION_ENGINE=spokenly
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

        # Fast check: any new JSON file?
        if spokenly_check_new_file "$anchor_mtime"; then
            # Slow step: parse JSON (only once)
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
        # Same flow as Typeless: show overlay, wait for confirm
        log "watch spokenly transcript_detected (${i} polls ~$((i / 10))s)"
        if wait_for_pending_confirm; then
            # Send Enter immediately
            send_current_mode_enter "watch spokenly preconfirm"
        else
            # Enter ready window (show countdown overlay)
            enter_ready_window spokenly "$i" 0 "$watch_session_id"
        fi
    fi
fi
```

### 3. CLI Installation Flow

**File:** `cli/lib/actions.mjs`

**Function: `collectTranscriptionEngine()`**
```javascript
async function collectTranscriptionEngine(runtime, interactive) {
    // Check existing config first
    const manifest = await readManifest(runtime);
    if (manifest?.transcriptionEngine) {
        return { engine: manifest.transcriptionEngine, reused: true };
    }

    // Ask user (no default, equal choice)
    const engine = await select({
        message: 'Choose transcription engine',
        initialValue: null,  // Force user to choose
        options: [
            {
                value: 'typeless',
                label: 'Typeless',
                hint: 'LLM-powered cleanup, SQLite database'
            },
            {
                value: 'spokenly',
                label: 'Spokenly',
                hint: 'AI transcription, JSON file history'
            }
        ]
    });

    if (isCancel(engine)) {
        cancel('Cancelled');
        process.exit(1);
    }

    return { engine, reused: false };
}
```

**Function: `checkEngineAvailability()`**
```javascript
async function checkEngineAvailability(runtime, engine) {
    if (engine === 'typeless') {
        const typelessDb = runtime.typelessDbPath;
        const exists = await pathExists(typelessDb);
        if (!exists) {
            throw createCliError(
                'Typeless database not found. Install Typeless and open it once.',
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
                'Spokenly not found. Install Spokenly and open it once.',
                'SPOKENLY_DIR_MISSING'
            );
        }

        // Check if Spokenly MCP server is running
        try {
            await execFile('curl', ['-s', '--max-time', '1', 'http://localhost:51089']);
        } catch {
            // Not critical, but warn user
            note(
                'Spokenly MCP server not detected. File-based detection will still work.',
                'Spokenly status'
            );
        }
    }
}
```

**Install flow integration:**
```javascript
async function install(runtime, options) {
    const engine = options.transcriptionEngine || await collectTranscriptionEngine(runtime);

    await checkEngineAvailability(runtime, engine);

    // Write config
    const config = {
        transcriptionEngine: engine,
        ...options.configOverrides
    };
    await writeConfig(runtime, config);

    // Write manifest
    await writeManifest(runtime, {
        transcriptionEngine: engine,
        triggerMode: options.triggerMode,
        profileName: result.profileName,
        installedVersion: runtime.packageVersion
    });

    // ... rest of install logic
}
```

### 4. Doctor Command Enhancement

**File:** `cli/lib/actions.mjs`

Add engine status to doctor report:
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

### 5. Script Initialization

**File:** `scripts/dictation-enter.sh`

Add engine detection at script start:
```bash
# Load config
load_optional_config

# Detect transcription engine
TRANSCRIPTION_ENGINE="${TRANSCRIPTION_ENGINE:-typeless}"  # Default to typeless for backward compat

# Set engine-specific paths
if [ "$TRANSCRIPTION_ENGINE" = "spokenly" ]; then
    SPOKENLY_HISTORY_DIR="${SPOKENLY_HISTORY_DIR:-$HOME/Library/Application Support/Spokenly/History}"
    # Date will be calculated dynamically in functions
fi
```

### 6. Save Command Enhancement

**File:** `scripts/dictation-enter.sh`

In `save` command, record engine-specific anchor:
```bash
save)
    # ... existing mode detection logic

    if [ "$TRANSCRIPTION_ENGINE" = "spokenly" ]; then
        # Save current timestamp as anchor
        current_mtime="$(spokenly_latest_json_mtime)"
        write_file spokenly_anchor_mtime "$current_mtime"
        log "save spokenly anchor_mtime=${current_mtime}"
    else
        # Existing Typeless logic
        anchor_rowid="$(typeless_last_rowid)"
        anchor_updated_at="$(typeless_row_updated_at "$anchor_rowid")"
        write_file db_anchor_rowid "$anchor_rowid"
        write_file db_anchor_updated_at "$anchor_updated_at"
        log "save typeless anchor_rowid=${anchor_rowid} anchor_updated_at=${anchor_updated_at}"
    fi

    # ... rest of save logic
```

## Error Handling

### Spokenly-specific Errors

1. **No History directory:**
   ```bash
   if [ ! -d "$SPOKENLY_HISTORY_DIR" ]; then
       log "error spokenly_history_dir_missing"
       exit 1
   fi
   ```

2. **JSON parsing failure:**
   ```bash
   if [ -z "$final_text" ]; then
       log "error spokenly_json_parse_failed file=${latest_json}"
       # Don't exit, continue polling for next file
       anchor_mtime="$current_mtime"  # Update anchor to avoid re-checking
   fi
   ```

3. **Date directory changes (midnight crossover):**
   - Functions dynamically calculate `date +%Y-%m-%d` each call
   - No state caching of directory path
   - Handles midnight transition automatically

### Fallback Behavior

If Spokenly detection fails after timeout:
```bash
if [ $i -ge "$WATCH_MAX_POLLS" ]; then
    log "watch spokenly timeout (30s)"
    # Clear state, exit gracefully
    clear_watch_state "$watch_session_id"
    exit 0
fi
```

## Testing Strategy

### Manual Testing

1. **Install flow:**
   ```bash
   npx github:Johnixr/dji-mic-dictation install --transcription-engine spokenly
   ```
   - Verify config written correctly
   - Verify Spokenly availability check

2. **Dictation flow:**
   - Press Fn, speak, press Fn again
   - Verify JSON file appears in History/YYYY-MM-DD/
   - Verify overlay appears within 1-2 seconds
   - Press Fn to send Enter

3. **Doctor check:**
   ```bash
   npx github:Johnixr/dji-mic-dictation doctor
   ```
   - Verify Spokenly status section

### Edge Cases

1. **Midnight crossover:**
   - Start dictation at 23:59:50
   - Finish at 00:00:10
   - Verify script finds JSON in new date directory

2. **Multiple JSON files:**
   - Create 3 test JSON files
   - Verify script always picks newest (by mtime)

3. **Partial JSON:**
   - Test with incomplete/malformed JSON
   - Verify error handling, no crash

4. **Spokenly not running:**
   - Kill Spokenly app
   - Verify script timeout after 30s, no zombie processes

## Performance Considerations

### Polling Overhead

**Typeless:**
- Query: `sqlite3 "$TYPELESS_DB" "SELECT ..."`
- Time: ~5-10ms per query
- Load: Minimal (SQLite optimized for frequent queries)

**Spokenly:**
- Query: `find "$dir" -name "*.json" -printf '%T@\n' | sort -rn | head -1`
- Time: ~10-20ms (depends on file count)
- Load: Minimal (find is efficient, only checks metadata)

**Comparison:**
- Both <20ms per poll
- 100ms interval → ~20% CPU time per poll
- Acceptable overhead

### JSON Parsing

- Only triggered when new file detected (1-2 times per dictation)
- Python parsing: ~50-100ms
- Total latency: detection (100ms) + parsing (100ms) = ~200ms
- Within user tolerance (overlay appears in <1s)

## Migration Path

### Existing Users

- **Default behavior:** Keep using Typeless (backward compat)
- **Migration:** Run `npx github:Johnixr/dji-mic-dictation config` → select Spokenly
- **Rollback:** Run `config` again → select Typeless

### New Users

- **Install:** Must choose engine (no default)
- **Switch:** Use `config` command anytime

## Documentation Updates

### README.md

Add section:
```markdown
## Transcription Engine Selection

This workflow supports two transcription engines:

| Engine | Detection Method | Data Source |
|--------|-----------------|-------------|
| Typeless | SQLite DB polling | `~/Library/Application Support/Typeless/typeless.db` |
| Spokenly | JSON file polling | `~/Library/Application Support/Spokenly/History/YYYY-MM-DD/*.json` |

Choose during install:
```bash
npx github:Johnixr/dji-mic-dictation install
# CLI will ask: "Choose transcription engine"
```

Switch anytime:
```bash
npx github:Johnixr/dji-mic-dictation config
```
```

### CLAUDE.md

Update validation requirements, prerequisites, troubleshooting sections.

## Open Questions

1. **Should we support "both engines simultaneously"?**
   - Current design: one engine at a time
   - Alternative: detect from both, merge results
   - Decision: Keep simple, one engine only

2. **Should we expose Spokenly MCP to users?**
   - MCP is for AI agents, not user workflow
   - User workflow: Fn → dictation → file → send
   - Decision: Don't expose MCP, use file detection only

3. **Performance optimization: cache date directory?**
   - Current: recalculate `date +%Y-%m-%d` every poll
   - Optimization: cache once per script invocation
   - Trade-off: Handles midnight crossover vs speed
   - Decision: No cache, handle midnight properly

## Implementation Checklist

- [ ] Add `TRANSCRIPTION_ENGINE` to config schema
- [ ] Implement `spokenly_*` functions in dictation-enter.sh
- [ ] Update CLI install flow (engine selection)
- [ ] Update CLI doctor command (engine status)
- [ ] Update save/watch commands (engine branching)
- [ ] Add tests for Spokenly detection
- [ ] Update README.md and CLAUDE.md
- [ ] Manual testing: end-to-end flow
- [ ] Edge case testing: midnight, errors, timeouts

## Success Criteria

1. **Installation:** Users can choose Spokenly during install
2. **Detection:** Spokenly transcripts detected within 1-2 seconds
3. **Reliability:** No crashes on malformed JSON, missing files
4. **Switching:** Users can switch engines with `config` command
5. **Backward compat:** Existing Typeless users unaffected
6. **Performance:** CPU overhead <5% during polling