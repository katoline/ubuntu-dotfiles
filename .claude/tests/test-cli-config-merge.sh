#!/bin/bash
# Codex の宣言設定マージを一時 HOME で検証する（実際のホームは触らない）。
# python3 に tomlkit が無ければ flake の共通 Python を取得する。CLI_CONFIG_PYTHON で指定もできる。
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

fail_python_setup() {
  report cli-config-python 0 1 "$1"
  # run.sh が表示する NG 行に取得失敗の詳細も残す。
  if [ -n "${2-}" ]; then printf '%s\n' "$2" | sed 's/^/  NG [cli-config-python] /'; fi
  summary cli-config-merge
  exit 1
}

python="${CLI_CONFIG_PYTHON-python3}"
if [ "${CLI_CONFIG_PYTHON+x}" != x ] && ! PYTHONDONTWRITEBYTECODE=1 python3 -c 'import tomlkit' >/dev/null 2>&1; then
  if ! command -v nix >/dev/null 2>&1; then
    fail_python_setup 'python3 に tomlkit が無く、共通 Python の取得に必要な nix が見つかりません'
  fi
  if python_store=$(nix build --no-link --print-out-paths --no-write-lock-file "$ROOT#cli-config-python" 2>"$T/cli-config-python.err"); then
    python="$python_store/bin/python3"
  else
    fail_python_setup 'flake の cli-config-python を取得できませんでした' "$(cat "$T/cli-config-python.err")"
  fi
fi

output=$(PYTHONDONTWRITEBYTECODE=1 CLI_CONFIG_REPO="$ROOT" "$python" - <<'PY' 2>&1
from collections import Counter
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import tomlkit

root = Path(os.environ["CLI_CONFIG_REPO"])
spec = importlib.util.spec_from_file_location("merge_cli_config", root / "nix/merge-cli-config.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cli-config-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        self.home = Path(self.temporary.name) / "home"
        for directory in [self.repo / "codex", self.home / ".codex"]:
            directory.mkdir(parents=True)
        (self.repo / "codex/config.toml").write_text('model = "declared"\n[mcp_servers.node_repl]\nenabled = true\n')
        (self.repo / "codex/hooks.json").write_text((root / "codex/hooks.json").read_text())
        self.config = self.home / ".codex/config.toml"
        self.hooks = self.home / ".codex/hooks.json"

    def generate(self, detach_only=False):
        module.generate(self.repo, self.home, detach_only)

    def test_fresh_home_and_idempotence(self):
        self.generate()
        config = tomlkit.parse(self.config.read_text())
        self.assertEqual(config["model"], "declared")
        self.assertNotIn("node_repl", config.get("mcp_servers", {}))
        self.assertFalse(self.config.is_symlink())
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        times = [path.stat().st_mtime_ns for path in (self.config, self.hooks)]
        self.generate()
        self.assertEqual(times, [path.stat().st_mtime_ns for path in (self.config, self.hooks)])

    def test_local_state_and_runtime_survive(self):
        self.config.write_text('''# ユーザーのコメント
model = "local"
unknown_setting = "keep"
[projects."/fixture/work"]
trust_level = "trusted"
[hooks.state."fixture"]
trusted_hash = "do-not-change"
[marketplaces.fixture]
source = "/fixture/cache/version"
[mcp_servers.node_repl]
command = "/fixture/bin/node_repl"
enabled = false
[mcp_servers.node_repl.env]
CODEX_HOME = "/fixture/home/.codex"
''')
        self.hooks.write_text('{"local_state":{"setup_complete":true},"hooks":{}}')
        self.generate()
        config = tomlkit.parse(self.config.read_text())
        self.assertEqual(config["model"], "declared")
        self.assertEqual(config["unknown_setting"], "keep")
        self.assertEqual(config["projects"]["/fixture/work"]["trust_level"], "trusted")
        self.assertEqual(config["hooks"]["state"]["fixture"]["trusted_hash"], "do-not-change")
        self.assertEqual(config["marketplaces"]["fixture"]["source"], "/fixture/cache/version")
        self.assertEqual(config["mcp_servers"]["node_repl"]["env"]["CODEX_HOME"], "/fixture/home/.codex")
        self.assertTrue(config["mcp_servers"]["node_repl"]["enabled"])
        self.assertIn("ユーザーのコメント", self.config.read_text())
        # hooks.json もフック以外のローカル状態を残し、宣言したフックは反映する。
        hooks = json.loads(self.hooks.read_text())
        self.assertTrue(hooks["local_state"]["setup_complete"])
        self.assertTrue(hooks["hooks"])
        # 外部ツールが switch 間に追加した値も次回そのまま引き継ぐ。
        config["hooks"]["state"]["second"] = {"trusted_hash": "new-local-hash"}
        self.config.write_text(tomlkit.dumps(config))
        self.generate()
        self.assertEqual(tomlkit.parse(self.config.read_text())["hooks"]["state"]["second"]["trusted_hash"], "new-local-hash")

    def test_legacy_symlink_migration_never_writes_repo(self):
        old = Path(self.temporary.name) / "old"
        old.mkdir()
        originals = ["model = 'old'\n[projects.fixture]\ntrust_level = 'trusted'\n", '{"local_state":"old","hooks":{}}']
        for destination, text in zip((self.config, self.hooks), originals):
            source = old / destination.name
            source.write_text(text)
            destination.symlink_to(source)
        self.generate(detach_only=True)
        for destination, text in zip((self.config, self.hooks), originals):
            self.assertFalse(destination.is_symlink())
            self.assertEqual(destination.read_text(), text)
        # home-manager の旧リンク削除は実ファイルになった対象を削除しない。
        self.generate()
        self.assertEqual(tomlkit.parse(self.config.read_text())["projects"]["fixture"]["trust_level"], "trusted")
        self.assertEqual(json.loads(self.hooks.read_text())["local_state"], "old")
        for source, text in zip((old / "config.toml", old / "hooks.json"), originals):
            self.assertEqual(source.read_text(), text)

    def test_direct_merge_detaches_symlink(self):
        original = Path(self.temporary.name) / "linked.toml"
        original.write_text("model = 'old'\n")
        self.config.symlink_to(original)
        self.generate()
        self.assertEqual(original.read_text(), "model = 'old'\n")
        self.assertFalse(self.config.is_symlink())

    def test_external_hooks_and_metadata_preserved_managed_hooks_updated(self):
        external = {"type": "command", "command": "/fixture/.orca/agent-hooks/codex-hook", "timeout": 77}
        old_owned = {"type": "command", "command": 'bash "/fixture/.codex/hooks/guard.sh"', "timeout": 1}
        self.hooks.write_text(json.dumps({"local_metadata": True, "hooks": {
            "PreToolUse": [{"matcher": "old", "custom": "keep", "hooks": [old_owned, external]}],
            "UnknownEvent": [{"hooks": [external]}]}}))
        self.generate()
        hooks = json.loads(self.hooks.read_text())
        self.assertTrue(hooks["local_metadata"])
        self.assertEqual(hooks["hooks"]["PreToolUse"][-1], {"matcher": "old", "custom": "keep", "hooks": [external]})
        self.assertEqual(hooks["hooks"]["UnknownEvent"][0]["hooks"], [external])
        self.assertEqual(hooks["hooks"]["PreToolUse"][0]["matcher"], "Bash")
        # 宣言から登録を消すと管理フックだけ消える。外部登録は残る。
        (self.repo / "codex/hooks.json").write_text('{"hooks":{}}')
        self.generate()
        remaining = json.loads(self.hooks.read_text())["hooks"]
        self.assertEqual(remaining["PreToolUse"], [{"matcher": "old", "custom": "keep", "hooks": [external]}])

    def test_invalid_local_toml_fails_before_any_write(self):
        self.config.write_text("invalid = [\n")
        with self.assertRaises(tomlkit.exceptions.TOMLKitError):
            self.generate()
        self.assertEqual(self.config.read_text(), "invalid = [\n")
        self.assertFalse(self.hooks.exists())

    def test_invalid_last_config_fails_before_any_write(self):
        self.hooks.write_text("{")
        with self.assertRaises(ValueError):
            self.generate()
        self.assertFalse(self.config.exists())
        self.assertEqual(self.hooks.read_text(), "{")

    def test_paused_devin_config_untouched(self):
        # Devin は休止中で反映対象外。既存のホーム側設定は書き換えず、無ければ作らない。
        devin = self.home / ".config/devin/config.json"
        self.generate()
        self.assertFalse(devin.exists())
        devin.parent.mkdir(parents=True)
        devin.write_text("{")
        before = devin.stat().st_mtime_ns
        self.generate()
        self.assertEqual(devin.read_text(), "{")
        self.assertEqual(devin.stat().st_mtime_ns, before)

    def test_invalid_hooks_structure_fails_before_any_write(self):
        self.hooks.write_text('{"hooks":{"PreToolUse":false}}')
        with self.assertRaises(ValueError):
            self.generate()
        self.assertFalse(self.config.exists())

    def test_removed_declaration_preserves_unknown_local_value(self):
        self.config.write_text("model = 'local'\nunknown = 'keep'\n")
        self.generate()
        (self.repo / "codex/config.toml").write_text("model = 'updated'\n")
        self.generate()
        self.assertEqual(tomlkit.parse(self.config.read_text())["unknown"], "keep")

    def test_every_declared_hook_is_owned(self):
        declared = json.loads((root / "codex/hooks.json").read_text())
        hooks = [hook for groups in declared["hooks"].values() for group in groups for hook in group["hooks"]]
        self.assertTrue(hooks)
        for hook in hooks:
            self.assertTrue(module.owned_hook(hook), hook["command"])

    def test_declared_hook_forms_do_not_accumulate(self):
        self.hooks.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": "/usr/bin/orca-hook", "timeout": 5}]}]}}))
        declared = json.loads((self.repo / "codex/hooks.json").read_text())
        declared["hooks"]["Stop"][0]["hooks"].append(
            {"type": "command", "command": 'bash "$HOME/.codex/hooks/notify.sh"', "timeout": 10})
        declared["hooks"]["PreToolUse"][0]["hooks"].append(
            {"type": "command", "command": '"$HOME/.codex/hooks/guard.sh"', "timeout": 30})
        (self.repo / "codex/hooks.json").write_text(json.dumps(declared))
        for _ in range(3):
            self.generate()
        def commands_of(hooks_json):
            return Counter(hook["command"] for groups in hooks_json["hooks"].values()
                           for group in groups for hook in group["hooks"])

        expected = commands_of(declared)
        expected["/usr/bin/orca-hook"] = 1
        self.assertEqual(commands_of(json.loads(self.hooks.read_text())), expected)

    def test_owned_hook_forms_replaced_then_removed(self):
        old = {"type": "command", "command": 'bash "$HOME/.codex/hooks/notify.sh"', "timeout": 10}
        external = {"type": "command", "command": "/usr/bin/orca-hook", "timeout": 5}
        self.hooks.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [old, external]}]}}))
        declared = json.loads((self.repo / "codex/hooks.json").read_text())
        declared["hooks"]["Stop"] = [{"hooks": [
            {"type": "command", "command": '"$HOME/.codex/hooks/notify.sh" --quiet', "timeout": 10}]}]
        (self.repo / "codex/hooks.json").write_text(json.dumps(declared))
        def stop_commands():
            return [hook["command"] for group in json.loads(self.hooks.read_text())["hooks"]["Stop"]
                    for hook in group["hooks"]]
        self.generate()
        commands = stop_commands()
        self.assertNotIn('bash "$HOME/.codex/hooks/notify.sh"', commands)
        self.assertEqual(commands.count('"$HOME/.codex/hooks/notify.sh" --quiet'), 1)
        self.assertEqual(commands.count("/usr/bin/orca-hook"), 1)
        del declared["hooks"]["Stop"]
        (self.repo / "codex/hooks.json").write_text(json.dumps(declared))
        self.generate()
        commands = stop_commands()
        self.assertFalse(any("notify.sh" in command for command in commands), commands)
        self.assertEqual(commands.count("/usr/bin/orca-hook"), 1)

    def test_declared_exact_command_does_not_accumulate_when_not_owned(self):
        hook = {"type": "command", "command": "/usr/local/bin/declared-hook", "timeout": 5}
        self.hooks.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [hook]}]}}))
        declared = json.loads((self.repo / "codex/hooks.json").read_text())
        declared["hooks"].setdefault("Stop", []).append({"hooks": [hook]})
        (self.repo / "codex/hooks.json").write_text(json.dumps(declared))
        for _ in range(3):
            self.generate()
        stop = json.loads(self.hooks.read_text())["hooks"]["Stop"]
        self.assertEqual(sum(h["command"] == "/usr/local/bin/declared-hook" for g in stop for h in g["hooks"]), 1)

    def test_declared_config_without_runtime_mcp_is_idempotent(self):
        (self.repo / "codex/config.toml").write_text((root / "codex/config.toml").read_text())
        self.generate()
        first = self.config.read_text()
        self.assertNotIn("mcp_servers", first)
        for _ in range(2):
            self.generate()
        self.assertEqual(self.config.read_text(), first)

    def test_main_reports_target_path_without_content_on_invalid_json(self):
        self.hooks.write_text('{"local_secret": ')
        result = subprocess.run(
            [sys.executable, str(root / "nix/merge-cli-config.py"), "--repo", str(self.repo), "--home", str(self.home)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ホーム側の " + str(self.hooks), result.stderr)
        self.assertNotIn("local_secret", result.stdout + result.stderr)
        self.assertEqual(self.hooks.read_text(), '{"local_secret": ')
        self.assertFalse(self.config.exists())

    def test_main_names_declared_side_when_declaration_is_invalid(self):
        (self.repo / "codex/hooks.json").write_text('{"hooks": ')
        result = subprocess.run(
            [sys.executable, str(root / "nix/merge-cli-config.py"), "--repo", str(self.repo), "--home", str(self.home)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("宣言側の " + str(self.repo / "codex/hooks.json"), result.stderr)
        self.assertNotIn(str(self.hooks), result.stderr)


unittest.main()
PY
)
rc=$?
report cli-config-merge-python 0 "$rc" "$output"
if [ "$rc" -ne 0 ]; then printf '%s\n' "$output"; fi
summary cli-config-merge
