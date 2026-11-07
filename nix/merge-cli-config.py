#!/usr/bin/env python3
"""宣言設定をホーム側へ反映し、CLI が保存したローカル状態を保持する。"""

import argparse
from collections.abc import MutableMapping
import copy
import json
import os
from pathlib import Path
import re
import shlex
import stat
import tempfile

import tomlkit


def merge(local, declared):
    for key, value in declared.items():
        if isinstance(value, MutableMapping) and isinstance(local.get(key), MutableMapping):
            merge(local[key], value)
        else:
            local[key] = copy.deepcopy(value)
    return local


def owned_hook(hook):
    if hook.get("type") != "command":
        return False
    try:
        words = shlex.split(hook.get("command", ""))
    except ValueError:
        return False
    return any(re.search(r"(?:^|/)\.codex/hooks/[^/]+\Z", word) for word in words)


def command_text(hook):
    if hook.get("type") == "command" and isinstance(hook.get("command"), str):
        return hook["command"]
    return None


def validate_hooks(config):
    if not isinstance(config.get("hooks", {}), dict):
        raise ValueError("hooks はオブジェクトである必要があります")
    for groups in config.get("hooks", {}).values():
        if not isinstance(groups, list):
            raise ValueError("イベントの hooks は配列である必要があります")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("フックグループには hooks 配列が必要です")
            if any(not isinstance(hook, dict) for hook in group["hooks"]):
                raise ValueError("フックはオブジェクトである必要があります")


def merge_hooks(local, declared):
    validate_hooks(local)
    validate_hooks(declared)
    events = local.setdefault("hooks", {})
    declared_commands = {
        command_text(hook) for groups in declared.get("hooks", {}).values()
        for group in groups for hook in group["hooks"]
    } - {None}
    # コマンドの所属で区別し、削除・matcher変更も反映する。外部ツールの登録は残す。
    # 宣言と同じコマンドの既存登録は宣言分へ置き換えるため取り除く（重複させない）。
    for event, groups in list(events.items()):
        retained = []
        for group in groups:
            group = copy.deepcopy(group)
            group["hooks"] = [hook for hook in group["hooks"]
                              if not owned_hook(hook) and command_text(hook) not in declared_commands]
            if group["hooks"]:
                retained.append(group)
        events[event] = retained
    for event, groups in declared.get("hooks", {}).items():
        events[event] = copy.deepcopy(groups) + events.get(event, [])
    for key, value in declared.items():
        if key != "hooks":
            local[key] = copy.deepcopy(value)
    return local


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode | stat.S_IWUSR)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def generate(repo, home, detach_only=False):
    files = [
        (repo / "codex/config.toml", home / ".codex/config.toml", "toml"),
        (repo / "codex/hooks.json", home / ".codex/hooks.json", "hooks"),
    ]
    pending = []
    current = side = None
    try:
        # 全ファイルを構文検査してから書く。不正な既存設定を空の設定に置き換えない。
        for source, destination, kind in files:
            parse = tomlkit.parse if kind == "toml" else json.loads
            current, side = destination, "ホーム"
            original = destination.read_text() if destination.exists() else None
            if destination.is_symlink() and original is None:
                raise ValueError(f"設定のリンク先がありません: {destination}")
            local = parse(original) if original is not None else parse("" if kind == "toml" else "{}")
            if not isinstance(local, dict):
                raise ValueError("設定はオブジェクトである必要があります")
            current, side = source, "宣言"
            declared = parse(source.read_text())
            if not isinstance(declared, dict):
                raise ValueError("設定はオブジェクトである必要があります")
            if kind == "hooks":
                validate_hooks(declared)
            current, side = destination, "ホーム"
            if kind == "hooks":
                validate_hooks(local)
            if detach_only:
                if destination.is_symlink():
                    pending.append((destination, original, original))
                continue
            if kind == "toml":
                # desktop のランタイムが未生成なら enabled だけの不完全な MCP を作らない。
                for name, server in list(declared.get("mcp_servers", {}).items()):
                    if set(server) <= {"enabled"} and not any(
                        local.get("mcp_servers", {}).get(name, {}).get(key) for key in ("command", "url")
                    ):
                        del declared["mcp_servers"][name]
                if "mcp_servers" in declared and not declared["mcp_servers"]:
                    del declared["mcp_servers"]
                result = tomlkit.dumps(merge(local, declared))
            else:
                result = json.dumps(merge_hooks(local, declared) if kind == "hooks"
                                    else merge(local, declared), ensure_ascii=False, indent=2) + "\n"
            if result != original or destination.is_symlink():
                pending.append((destination, original, result))
        for destination, original, result in pending:
            # 読み取り後に外部ツールが書き込んだ場合は、次の switch で再試行する。
            current, side = destination, "ホーム"
            text = destination.read_text() if destination.exists() else None
            if text != original:
                raise ValueError(f"反映中に設定が変更されました: {destination}")
            atomic_write(destination, result)
    except (ValueError, OSError, tomlkit.exceptions.TOMLKitError) as error:
        # main が失敗メッセージに対象ファイルと宣言側・ホーム側の別を出せるよう、例外に処理中のパスを付ける。
        error.config_path = current
        error.config_side = side
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--detach-only", action="store_true")
    args = parser.parse_args()
    try:
        generate(args.repo, args.home, args.detach_only)
    except (ValueError, OSError, tomlkit.exceptions.TOMLKitError) as error:
        # パース例外には設定内容が含まれることがあるため出力しない。
        parser.exit(1, f"CLI 設定の反映に失敗しました（{type(error).__name__}）: {error.config_side}側の {error.config_path} を確認してください。\n")


if __name__ == "__main__":
    main()
