#!/bin/bash
# opencode/plugins/shared-harness.js の state テスト（Node の test スクリプトを呼ぶ）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
out=$(node "$TESTS_DIR/opencode-plugin.test.mjs" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || printf '%s\n' "$out"
report A01-node-test 0 "$rc" "$out"
summary "opencode-plugin.js"
