import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  closeSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

test("不正な設定の診断に秘密鍵の抜粋を含めない", () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), "notify-log-test-"));
  const configPath = path.join(dir, "config.json");
  const logPath = path.join(dir, "stderr.log");
  const log = openSync(logPath, "w", 0o600);
  try {
    // JSON.parse は引用符のない値をエラーへ抜粋する。実際の設定・送信は使わない。
    writeFileSync(configPath, '{"privateKey": DUMMY_PRIVATE_KEY}', {
      mode: 0o600,
    });
    const result = spawnSync(
      process.execPath,
      [fileURLToPath(new URL("./send-push.mjs", import.meta.url))],
      {
        env: { ...process.env, CLAUDE_NOTIFY_CONFIG: configPath },
        stdio: ["ignore", "ignore", log],
        timeout: 10_000,
      }
    );
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0);
    const stderr = readFileSync(logPath, "utf8");
    assert.match(stderr, /設定ファイルの JSON が不正です/);
    assert.doesNotMatch(stderr, /DUMMY|PRIVATE_KEY|vateKey/);
  } finally {
    closeSync(log);
    rmSync(dir, { recursive: true, force: true });
  }
});
