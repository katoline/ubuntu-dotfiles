#!/usr/bin/env node
// Claude Code の hook（.claude/hooks/notify.sh）から呼ばれる Web Push 送信スクリプト。
// このファイルは dotfiles リポジトリ管理（dotfiles/claude-notify/）。
// 受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にある。
// どんな失敗があっても Claude Code の動作を妨げないよう、必ず exit code 0 で終了する。
// 失敗理由は stderr に日本語で出力する。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import webpush from "web-push";

const SETUP_HINT =
  "セットアップ手順は dotfiles の .claude/README.md、および claude-notify-mobile リポジトリの docs/SETUP.md を参照してください（VAPID 鍵の生成・購読情報の登録が必要です）。";

/** CLI 引数を --key value 形式でパースする */
function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      args[key] = true;
    } else {
      args[key] = next;
      i++;
    }
  }
  return args;
}

/** 設定ファイルの絶対パスを決定する（環境変数優先、なければ ~/.claude/claude-notify.json） */
function resolveConfigPath() {
  if (process.env.CLAUDE_NOTIFY_CONFIG) {
    return path.resolve(process.env.CLAUDE_NOTIFY_CONFIG);
  }
  return path.join(os.homedir(), ".claude", "claude-notify.json");
}

/** 設定ファイルを読み込む。存在しない/壊れている場合は null を返し、理由を stderr に出す */
function loadConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    process.stderr.write(
      `[claude-notify] 設定ファイルが見つかりません: ${configPath}\n${SETUP_HINT}\n`
    );
    return null;
  }

  let raw;
  try {
    raw = fs.readFileSync(configPath, "utf8");
  } catch (err) {
    process.stderr.write(
      `[claude-notify] 設定ファイルを読み込めませんでした: ${configPath} (${err.message})\n${SETUP_HINT}\n`
    );
    return null;
  }

  let config;
  try {
    config = JSON.parse(raw);
  } catch {
    process.stderr.write(
      // JSON.parse のエラーには入力の抜粋（VAPID秘密鍵を含みうる）が入る。
      `[claude-notify] 設定ファイルの JSON が不正です: ${configPath}\n${SETUP_HINT}\n`
    );
    return null;
  }

  const vapid = config.vapid ?? {};
  const subscription = config.subscription ?? {};
  const keys = subscription.keys ?? {};

  if (!vapid.subject || !vapid.publicKey || !vapid.privateKey) {
    process.stderr.write(
      `[claude-notify] 設定ファイルに VAPID 情報（subject / publicKey / privateKey）が不足しています: ${configPath}\n${SETUP_HINT}\n`
    );
    return null;
  }

  if (!subscription.endpoint || !keys.p256dh || !keys.auth) {
    process.stderr.write(
      `[claude-notify] 設定ファイルに購読情報（subscription.endpoint / keys.p256dh / keys.auth）が不足しています: ${configPath}\n${SETUP_HINT}\n`
    );
    return null;
  }

  return config;
}

/** "HH:MM" を当日の分単位（0-1439）に変換する */
function toMinutes(hhmm) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm);
  if (!m) return null;
  const hour = Number(m[1]);
  const minute = Number(m[2]);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

/** 現在時刻が quietHours の範囲内かどうか（日跨ぎ対応） */
function isWithinQuietHours(quietHours, now = new Date()) {
  if (!quietHours || !quietHours.start || !quietHours.end) return false;

  const start = toMinutes(quietHours.start);
  const end = toMinutes(quietHours.end);
  if (start === null || end === null) return false;

  const current = now.getHours() * 60 + now.getMinutes();

  if (start === end) {
    // 全時間帯が静音（例: start === end）とみなす
    return true;
  }

  if (start < end) {
    // 日を跨がない通常の範囲（例: 09:00 -> 18:00）
    return current >= start && current < end;
  }

  // 日を跨ぐ範囲（例: 23:00 -> 07:00）
  return current >= start || current < end;
}

/** 状態ファイル（デバウンス用の最終送信時刻）のパスを決定する */
function resolveStatePath(configPath) {
  return path.join(path.dirname(configPath), ".claude-notify-state.json");
}

/** 状態ファイルを読み込む。存在しない/壊れている場合は空オブジェクトを返す */
function loadState(statePath) {
  try {
    if (!fs.existsSync(statePath)) return {};
    const raw = fs.readFileSync(statePath, "utf8");
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/** 状態ファイルを書き込む。失敗しても致命的にしない */
function saveState(statePath, state) {
  try {
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2), "utf8");
  } catch (err) {
    process.stderr.write(
      `[claude-notify] 状態ファイルの書き込みに失敗しました（デバウンスが機能しない可能性があります）: ${err.message}\n`
    );
  }
}

/** デバウンス判定。送信すべきなら true を返す */
function shouldSendByDebounce(
  statePath,
  event,
  debounceSeconds,
  now = new Date()
) {
  if (!debounceSeconds || debounceSeconds <= 0) return true;
  if (!event) return true;

  const state = loadState(statePath);
  const lastSentAt = state[event];
  if (typeof lastSentAt === "number") {
    const elapsedSeconds = (now.getTime() - lastSentAt) / 1000;
    if (elapsedSeconds < debounceSeconds) {
      return false;
    }
  }
  return true;
}

/** デバウンス用に最終送信時刻を記録する */
function recordSendTime(statePath, event, now = new Date()) {
  if (!event) return;
  const state = loadState(statePath);
  state[event] = now.getTime();
  saveState(statePath, state);
}

/** Promise に指定ミリ秒のタイムアウトを付ける */
function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`送信がタイムアウトしました（${ms}ms）`)),
      ms
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  const title = typeof args.title === "string" ? args.title : "Claude Code";
  const body = typeof args.body === "string" ? args.body : "";
  const event = typeof args.event === "string" ? args.event : undefined;
  const project = typeof args.project === "string" ? args.project : undefined;
  const tag = typeof args.tag === "string" ? args.tag : event;

  const configPath = resolveConfigPath();
  const config = loadConfig(configPath);
  if (!config) {
    return; // loadConfig 内で理由を出力済み
  }

  const filters = config.filters ?? {};

  // events フィルタ
  if (Array.isArray(filters.events) && filters.events.length > 0) {
    if (!event || !filters.events.includes(event)) {
      process.stderr.write(
        `[claude-notify] イベント種別 "${event ?? "(未指定)"}" は通知対象外のため送信しません。\n`
      );
      return;
    }
  }

  // quietHours フィルタ
  if (isWithinQuietHours(filters.quietHours)) {
    process.stderr.write(
      `[claude-notify] 静音時間帯（${filters.quietHours.start} - ${filters.quietHours.end}）のため送信しません。\n`
    );
    return;
  }

  // debounce フィルタ
  const statePath = resolveStatePath(configPath);
  if (!shouldSendByDebounce(statePath, event, filters.debounceSeconds)) {
    process.stderr.write(
      `[claude-notify] デバウンス期間内（${filters.debounceSeconds}秒）のため送信しません（event=${event}）。\n`
    );
    return;
  }

  webpush.setVapidDetails(
    config.vapid.subject,
    config.vapid.publicKey,
    config.vapid.privateKey
  );

  const payload = JSON.stringify({
    title,
    body,
    tag,
    event,
    project,
    ts: Date.now(),
  });

  // デバウンスの記録は送信を試みた時点で行う（失敗時の連投も抑制するため）
  recordSendTime(statePath, event);

  try {
    await withTimeout(
      webpush.sendNotification(config.subscription, payload, { TTL: 3600 }),
      5000
    );
    process.stderr.write(`[claude-notify] 通知を送信しました: "${title}"\n`);
  } catch (err) {
    const statusCode = err && err.statusCode;
    if (statusCode === 404 || statusCode === 410) {
      process.stderr.write(
        "[claude-notify] 購読が失効しています。PWA を開いて再ペアリングしてください。\n"
      );
    } else if (statusCode) {
      process.stderr.write(
        `[claude-notify] 通知の送信に失敗しました（HTTP ${statusCode}）。\n`
      );
    } else {
      process.stderr.write(
        `[claude-notify] 通知の送信に失敗しました: ${err && err.message ? err.message : err}\n`
      );
    }
  }
}

main()
  .catch((err) => {
    process.stderr.write(
      `[claude-notify] 予期しないエラーが発生しました: ${err && err.message ? err.message : err}\n`
    );
  })
  .finally(() => {
    process.exit(0);
  });
