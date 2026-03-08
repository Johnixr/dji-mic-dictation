import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
KARABINER_JSON = REPO_ROOT / "karabiner" / "dji-mic-mini.json"


def load_rule():
    data = json.loads(KARABINER_JSON.read_text(encoding="utf-8"))
    return next(
        rule
        for rule in data["rules"]
        if rule["description"] == "Fn dictation toggle + confirm/preconfirm to send Enter"
    )


def shell_commands(items):
    return [item["shell_command"] for item in items if "shell_command" in item]


def test_fn_save_rule_is_present_and_sets_dictation_active():
    rule = load_rule()
    save_manip = next(
        manip
        for manip in rule["manipulators"]
        if manip.get("from", {}).get("key_code") == "fn"
        and any(
            " route fn-save save " in cmd
            for cmd in shell_commands(manip.get("to", [])) + shell_commands(manip.get("to_if_alone", []))
        )
    )

    commands = shell_commands(save_manip.get("to", [])) + shell_commands(save_manip.get("to_if_alone", []))
    assert commands == [
        "~/.config/karabiner/scripts/dictation-enter.sh route fn-save save 2>/dev/null"
    ]

    set_variable_entries = [
        item["set_variable"]
        for item in save_manip.get("to", []) + save_manip.get("to_if_alone", [])
        if "set_variable" in item
    ]
    assert {
        "name": "dji_dictation_active",
        "value": 1,
    } in set_variable_entries

    key_entries = [item for item in save_manip.get("to", []) if item.get("key_code") == "fn"]
    assert key_entries == [{"key_code": "fn"}]


def test_dji_save_rule_sets_dictation_active_only_on_to_if_alone():
    rule = load_rule()
    save_manip = next(
        manip
        for manip in rule["manipulators"]
        if manip.get("from", {}).get("consumer_key_code") == "volume_increment"
        and any(
            " route dji-save save " in cmd
            for cmd in shell_commands(manip.get("to", [])) + shell_commands(manip.get("to_if_alone", []))
        )
    )

    assert shell_commands(save_manip.get("to", [])) == []
    assert shell_commands(save_manip.get("to_if_alone", [])) == [
        "~/.config/karabiner/scripts/dictation-enter.sh route dji-save save 2>/dev/null"
    ]

    key_entries = [item for item in save_manip.get("to", []) if item.get("key_code") == "fn"]
    assert key_entries == [{"key_code": "fn"}]

    set_variable_entries = [
        item["set_variable"]
        for item in save_manip.get("to_if_alone", [])
        if "set_variable" in item
    ]
    assert set_variable_entries == [
        {
            "name": "dji_dictation_active",
            "value": 1,
        }
    ]


def test_escape_clears_dictation_active_while_preserving_escape_key():
    rule = load_rule()
    escape_manip = next(
        manip
        for manip in rule["manipulators"]
        if manip.get("from", {}).get("key_code") == "escape"
    )

    conditions = escape_manip.get("conditions", [])
    assert {
        "name": "dji_dictation_active",
        "type": "variable_if",
        "value": 1,
    } in conditions
    assert {
        "name": "dji_watching",
        "type": "variable_unless",
        "value": 1,
    } in conditions
    assert {
        "name": "dji_ready_to_send",
        "type": "variable_unless",
        "value": 1,
    } in conditions

    assert escape_manip.get("to", []) == [
        {
            "set_variable": {
                "name": "dji_dictation_active",
                "value": 0,
            }
        },
        {"key_code": "escape"},
    ]


def test_second_press_routes_open_send_window_before_watcher_starts():
    rule = load_rule()

    fn_watch = next(
        manip
        for manip in rule["manipulators"]
        if manip.get("from", {}).get("key_code") == "fn"
        and any(
            " route fn-watch watch " in cmd
            for cmd in shell_commands(manip.get("to", []))
        )
    )
    dji_watch = next(
        manip
        for manip in rule["manipulators"]
        if manip.get("from", {}).get("consumer_key_code") == "volume_increment"
        and any(
            " route dji-watch watch " in cmd
            for cmd in shell_commands(manip.get("to", []))
        )
    )

    assert shell_commands(fn_watch.get("to", [])) == [
        "~/.config/karabiner/scripts/dictation-enter.sh route fn-open-window open-window 2>/dev/null; /usr/bin/nohup ~/.config/karabiner/scripts/dictation-enter.sh route fn-watch watch 2>/dev/null &",
    ]
    assert shell_commands(dji_watch.get("to", [])) == [
        "~/.config/karabiner/scripts/dictation-enter.sh route dji-open-window open-window 2>/dev/null; /usr/bin/nohup ~/.config/karabiner/scripts/dictation-enter.sh route dji-watch watch 2>/dev/null &",
    ]


def test_fn_and_dji_routes_are_present_in_expected_order():
    rule = load_rule()

    fn_routes = []
    dji_routes = []
    for manip in rule["manipulators"]:
        origin = manip.get("from", {})
        commands = shell_commands(manip.get("to", [])) + shell_commands(manip.get("to_if_alone", []))
        if origin.get("key_code") == "fn":
            fn_routes.extend(commands)
        if origin.get("consumer_key_code") == "volume_increment":
            dji_routes.extend(commands)

    assert fn_routes == [
        "~/.config/karabiner/scripts/dictation-enter.sh route fn-confirm confirm 2>/dev/null",
        "~/.config/karabiner/scripts/dictation-enter.sh route fn-preconfirm preconfirm 2>/dev/null",
        "~/.config/karabiner/scripts/dictation-enter.sh route fn-open-window open-window 2>/dev/null; /usr/bin/nohup ~/.config/karabiner/scripts/dictation-enter.sh route fn-watch watch 2>/dev/null &",
        "~/.config/karabiner/scripts/dictation-enter.sh route fn-save save 2>/dev/null",
    ]
    assert dji_routes == [
        "~/.config/karabiner/scripts/dictation-enter.sh route dji-confirm confirm 2>/dev/null",
        "~/.config/karabiner/scripts/dictation-enter.sh route dji-preconfirm preconfirm 2>/dev/null",
        "~/.config/karabiner/scripts/dictation-enter.sh route dji-open-window open-window 2>/dev/null; /usr/bin/nohup ~/.config/karabiner/scripts/dictation-enter.sh route dji-watch watch 2>/dev/null &",
        "~/.config/karabiner/scripts/dictation-enter.sh route dji-save save 2>/dev/null",
    ]
