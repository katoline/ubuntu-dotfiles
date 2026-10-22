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
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const webpushUrl = pathToFileURL(
  createRequire(import.meta.url).resolve("web-push")
).href;

/** 実設定やネットワークを使わず、別プロセスの診断ログを検証する。 */
function runWithDummyConfig(config, preload = "", scriptArgs = []) {
  const dir = mkdtempSync(path.join(os.tmpdir(), "notify-log-test-"));
  const configPath = path.join(dir, "config.json");
  const logPath = path.join(dir, "stderr.log");
  const log = openSync(logPath, "w", 0o600);
  try {
    writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
    const args = preload
      ? ["--import", `data:text/javascript,${encodeURIComponent(preload)}`]
      : [];
    args.push(
      fileURLToPath(new URL("./send-push.mjs", import.meta.url)),
      ...scriptArgs
    );
    const result = spawnSync(process.execPath, args, {
      env: { ...process.env, CLAUDE_NOTIFY_CONFIG: configPath },
      stdio: ["ignore", "ignore", log],
      timeout: 10_000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0);
    return readFileSync(logPath, "utf8");
  } finally {
    closeSync(log);
    rmSync(dir, { recursive: true, force: true });
  }
}

const dummyConfig = {
  vapid: {
    subject: "DUMMY_PRIVATE_KEY_IN_SUBJECT",
    publicKey: "DUMMY_PUBLIC_KEY",
    privateKey: "DUMMY_PRIVATE_KEY",
  },
  subscription: {
    endpoint: "https://example.invalid/DUMMY_SECRET_ENDPOINT",
    keys: { p256dh: "DUMMY_P256DH", auth: "DUMMY_AUTH" },
  },
};

test("正常なJSONでもVAPIDの検証例外へ設定値を含めない", () => {
  const stderr = runWithDummyConfig(dummyConfig);
  assert.match(stderr, /VAPID 情報の形式が不正です/);
  assert.doesNotMatch(stderr, /DUMMY|PRIVATE_KEY|https:\/\//);
});

for (const [name, errorFields, expected] of [
  ["通信エラー", { code: "ECONNRESET" }, /ECONNRESET/],
  ["HTTPエラー", { statusCode: 429 }, /HTTP 429/],
  ["購読なし", { statusCode: 404 }, /購読が失効しています/],
  ["購読失効", { statusCode: 410 }, /購読が失効しています/],
  ["不正なエラーコード", { code: "DUMMY_SECRET_CODE" }, /送信に失敗/],
  ["不正なHTTPステータス", { statusCode: "DUMMY_SECRET_STATUS" }, /送信に失敗/],
]) {
  test(`${name}の本文や送信先をログへ含めない`, () => {
    const preload = `
      import webpush from ${JSON.stringify(webpushUrl)};
      webpush.setVapidDetails = () => {};
      webpush.sendNotification = () => Promise.reject(Object.assign(
        new Error("DUMMY_SECRET_ERROR_MESSAGE"),
        ${JSON.stringify(errorFields)},
        {body: "DUMMY_SECRET_RESPONSE", endpoint: "https://example.invalid/DUMMY_SECRET_ENDPOINT"}
      ));
    `;
    const stderr = runWithDummyConfig(dummyConfig, preload);
    assert.match(stderr, expected);
    assert.doesNotMatch(stderr, /DUMMY|SECRET|https:\/\//);
  });
}

for (const [name, preload, scriptArgs, expected] of [
  [
    "設定ファイル読込",
    `
      import fs from "node:fs";
      const original = fs.readFileSync;
      fs.readFileSync = (filename, ...args) => {
        if (filename === process.env.CLAUDE_NOTIFY_CONFIG) {
          throw Object.assign(new Error("DUMMY_SECRET_READ_ERROR"), {code: "EACCES"});
        }
        return original(filename, ...args);
      };
    `,
    [],
    /設定ファイルを読み込めませんでした/,
  ],
  [
    "状態ファイル保存",
    `
      import fs from "node:fs";
      import webpush from ${JSON.stringify(webpushUrl)};
      webpush.setVapidDetails = () => {};
      webpush.sendNotification = () => Promise.resolve({statusCode: 201});
      const original = fs.writeFileSync;
      fs.writeFileSync = (filename, ...args) => {
        if (filename.endsWith(".claude-notify-state.json")) {
          throw Object.assign(new Error("DUMMY_SECRET_WRITE_ERROR"), {code: "EACCES"});
        }
        return original(filename, ...args);
      };
    `,
    ["--event", "Stop"],
    /状態ファイルの書き込みに失敗しました/,
  ],
  [
    "予期しない例外",
    `
      import fs from "node:fs";
      const original = fs.existsSync;
      fs.existsSync = (filename) => {
        if (filename === process.env.CLAUDE_NOTIFY_CONFIG) {
          throw Object.assign(new Error("DUMMY_SECRET_UNEXPECTED_ERROR"), {code: "EACCES"});
        }
        return original(filename);
      };
    `,
    [],
    /予期しないエラーが発生しました/,
  ],
]) {
  test(`${name}の診断に例外本文を含めない`, () => {
    const stderr = runWithDummyConfig(dummyConfig, preload, scriptArgs);
    assert.match(stderr, expected);
    assert.match(stderr, /EACCES/);
    assert.doesNotMatch(stderr, /DUMMY|SECRET|https:\/\//);
  });
}

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
