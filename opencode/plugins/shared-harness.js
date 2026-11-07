// OpenCode V2 と共通ハーネス（Claude Code / Codex / Grok と同じ guard / pr-mode / verify-gate / completion-gate）の接続。
//
// このファイルは OpenCode の plugin として読み込まれ、判定は opencode/hooks/harness.sh に委譲する。
// Git の許可判定は /pr の起動状態に依存しない:
// - permission 評価では共通 guard と pr-mode の PreToolUse（pr-pre）を呼び、deny / ask をそのまま反映する。
//   guard も pr-pre も決定を返さず、フル入力の単一コマンド・メインセッション・設定が ask のときだけ
//   pr-mode の PermissionRequest（pr-request）を `PR_MODE_REQUEST_SCOPE=git` で呼び、
//   allow が返ればそれを反映する。allow されるのは main 時点と同じ git の自動承認対象だけで、
//   `home-manager switch`・`apt install`・`git reset --hard` 等の設定 ask は残る。
// - サブエージェントと delegated-worker は agent_id 付きで渡し、pr-pre に git 書き込みを拒否させる。
// - session ごとの「世代 (generation)」と「最新の実配送 user」は検証ゲートの再開制御だけに使う。
//   execution.started / failed / interrupted と実 user の変更は generation を進め、進行中の検証ジョブ
//   （synthetic 再開）を無効化する。終了判定は session ごとの job で行い、event stream を止めない。
// - synthetic / compact で元の実 user が見えなくなっただけでは新しい turn にしない。
// - 完了チェックゲート（completion-gate.sh）も同じ集約先・namespace で接続する。新しい実 user で
//   complete-prompt、編集・shell の後に complete-post、終了時は verify-stop が block も警告も返さないときだけ
//   complete-stop を呼ぶ。block の再開は verify と同じ（turn ごとに 1 回、state.nudged を共有）。
// 実装しないこと:
// - commit / push / PR の実行（許可判定だけを行う）
// - 独自の削除・Git 判定・検証分類（共通スクリプトの結果をそのまま使う）
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

const ADAPTER = fileURLToPath(new URL("../hooks/harness.sh", import.meta.url))
const OPENCODE_PREFIX = "opencode-"
const TIMEOUT_MS = 5000

function namespace(id) {
  return `${OPENCODE_PREFIX}${id}`
}

function isWorker(info) {
  return info?.agent === "delegated-worker"
}

function isChild(info) {
  return Boolean(info?.parentID)
}

function locationMatches(ctx, info) {
  const want = ctx?.location?.directory
  const got = info?.location?.directory
  if (!want || !got) return true
  const norm = (p) => {
    try {
      return new URL(`file://${p}`).pathname.replace(/\/+$/, "")
    } catch {
      return p.replace(/\/+$/, "")
    }
  }
  return norm(want) === norm(got)
}

// config に残した安全網の ask を、共通 guard が正常終了 no-decision を返したときだけ下げる family。
// 判定ルール・許可 roots は複写せず、「どのコマンド family を guard に任せているか」だけを明示する。
// unlink/find/pkill/killall は今回の昇格対象にしない（config の ask をそのまま残す）。
function guardFamily(command) {
  const match = /^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*(?:command\s+)?(rm|rmdir|mv)(?:\s|$)/.exec(command)
  return match ? match[1] : ""
}

function resourcesAreGuardFamily(resources) {
  if (!Array.isArray(resources) || resources.length === 0) return false
  return resources.every((resource) => {
    if (typeof resource !== "string" || !isSingleSimpleCommand(resource)) return false
    return guardFamily(resource) !== ""
  })
}

// 引用符の外にシェル演算子がない単純コマンドだけを対象にする（複合コマンドの一部だけを見て ask を消さない）
function isSingleSimpleCommand(command) {
  let quote = ""
  for (let i = 0; i < command.length; i++) {
    const ch = command[i]
    if (quote) {
      if (ch === "\\" && quote === '"') {
        i++
        continue
      }
      if (ch === quote) quote = ""
      continue
    }
    if (ch === "'" || ch === '"') {
      quote = ch
      continue
    }
    if (ch === "\\") {
      i++
      continue
    }
    if (";&|`<>()\n\r".includes(ch)) return false
    if (ch === "$" && command[i + 1] === "(") return false
  }
  return quote === ""
}

async function runAdapter(op, payload) {
  return await new Promise((resolve) => {
    let child
    try {
      child = spawn("bash", [ADAPTER, op], {
        stdio: ["pipe", "pipe", "pipe"],
        env: process.env,
      })
    } catch (error) {
      resolve({ ok: false, stdout: "", stderr: String(error), error: "spawn" })
      return
    }
    let stdout = ""
    let stderr = ""
    let settled = false
    const finish = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(result)
    }
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL")
      } catch {
        // 終了できなくても呼び出し側は拒否に倒す
      }
      finish({ ok: false, stdout, stderr, error: "timeout" })
    }, TIMEOUT_MS)
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString()
    })
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString()
    })
    child.on("error", (error) => {
      finish({ ok: false, stdout, stderr: stderr + String(error), error: "spawn" })
    })
    child.on("close", (code) => {
      finish({ ok: code === 0, code, stdout, stderr, error: code === 0 ? "" : "exit" })
    })
    try {
      child.stdin.end(JSON.stringify(payload))
    } catch (error) {
      finish({ ok: false, stdout, stderr: stderr + String(error), error: "stdin" })
    }
  })
}

function parsePermission(run) {
  if (!run.ok) return { kind: "error", message: run.stderr || run.error || "共通フックの実行に失敗しました" }
  const text = run.stdout.trim()
  if (!text) return { kind: "none" }
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    return { kind: "error", message: "共通フックの出力 JSON を解釈できませんでした" }
  }
  const out = parsed?.hookSpecificOutput
  if (!out) return { kind: "none" }
  switch (out.permissionDecision) {
    case "deny":
      return { kind: "deny", message: out.permissionDecisionReason || "" }
    case "ask":
      return { kind: "ask", message: out.permissionDecisionReason || "" }
    case "allow":
      return { kind: "allow", message: out.permissionDecisionReason || "" }
    default:
      return { kind: "none" }
  }
}

function parseRequestAllow(run) {
  if (!run.ok) return { kind: "error", message: run.stderr || run.error || "共通フックの実行に失敗しました" }
  const text = run.stdout.trim()
  if (!text) return { kind: "none" }
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    return { kind: "error", message: "共通フックの出力 JSON を解釈できませんでした" }
  }
  const out = parsed?.hookSpecificOutput
  return out?.decision?.behavior === "allow" ? { kind: "allow" } : { kind: "none" }
}

function worst(current, next) {
  const rank = { none: 0, allow: 1, ask: 2, deny: 3, error: 4 }
  return rank[next] > rank[current] ? next : current
}

export default {
  id: "dotfiles.shared-harness",
  async setup(ctx) {
    const calls = new Map()
    const sessions = new Map()
    const registrations = []
    const controller = new AbortController()
    let disposed = false

    const sessionState = (id) => {
      let state = sessions.get(id)
      if (!state) {
        state = {
          // 実行の開始・中断・失敗・実 user の変更で進む。古いジョブはこの値で無効になる
          generation: 0,
          // 同じ generation の succeeded を二重に処理しない
          stopGeneration: -1,
          // この session で実配送を確認した user.id（compact で順序が変わっても再開始しない）
          seenUsers: new Set(),
          userID: "",
          // 実配送 user の照合だけを session 内で直列化する
          turnQueue: Promise.resolve(),
          nudged: false,
          // 同一 turn で警告 synthetic を繰り返さない（delivery:steer が再開する環境でもループしない）
          warned: false,
          nudgeFailed: false,
          verifyBroken: false,
        }
        sessions.set(id, state)
      }
      return state
    }

    const turnQueue = (state, fn) => {
      const result = state.turnQueue.then(fn, fn)
      state.turnQueue = result.then(
        () => undefined,
        () => undefined,
      )
      return result
    }

    const getInfo = async (id) => {
      try {
        return await ctx.session.get({ sessionID: id })
      } catch {
        return undefined
      }
    }

    const alive = (sessionID, state, generation) =>
      !disposed && sessions.get(sessionID) === state && state.generation === generation

    const isHarnessMessage = (message) => message?.metadata?.source === "dotfiles.shared-harness"

    // 実配送された user だけを対象にする。plugin 自身が送った synthetic（検証の再開・警告）は除く。
    const realUsers = (messages) =>
      (Array.isArray(messages) ? messages : []).filter(
        (message) =>
          message?.type === "user" &&
          typeof message.id === "string" &&
          message.id &&
          !isHarnessMessage(message),
      )

    const latestRealUser = (messages) => realUsers(messages).at(-1)

    const rememberUser = (state, id) => {
      state.seenUsers.add(id)
      if (state.seenUsers.size > 200) state.seenUsers.delete(state.seenUsers.values().next().value)
    }

    // 検証ゲートの turn 管理。実配送された最新 user が変わったときだけ generation を進め、
    // 進行中の検証ジョブ（synthetic 再開）を無効化する。Git の許可判定には使わない。
    // session.get / session.context の失敗は ok:false（呼び出し側は再開しない）。
    const syncTurn = (sessionID, info) => {
      const state = sessionState(sessionID)
      return turnQueue(state, async () => {
        if (disposed) return { ok: false, message: "plugin の終了処理中です" }
        if (!info) {
          return { ok: false, message: "セッション情報を取得できないため、状態を確認できません" }
        }
        if (isChild(info) || isWorker(info) || !locationMatches(ctx, info)) {
          return { ok: true, managed: false }
        }
        let messages
        try {
          messages = await ctx.session.context({ sessionID })
        } catch {
          return { ok: false, message: "セッションの会話を取得できないため、状態を確認できません" }
        }
        if (disposed) return { ok: false, message: "plugin の終了処理中です" }
        const user = latestRealUser(messages)
        // synthetic だけ / compact で元の実 user が見えないだけなら、既知の turn を変えない
        if (!user) return { ok: true, managed: true }
        if (state.seenUsers.has(user.id)) return { ok: true, managed: true }
        const newTurn = state.userID !== ""
        rememberUser(state, user.id)
        state.userID = user.id
        state.nudged = false
        state.warned = false
        state.nudgeFailed = false
        // 実 user が変わったときだけ、前の turn の検証ジョブを無効化する。
        // 初回同期（この job が最初に user を知る場合）は同じ turn なので進めない。
        if (newTurn) state.generation++
        // 完了チェックゲートの「このターンの促し回数」を戻す（UserPromptSubmit 相当）。失敗は無視する
        try {
          await runAdapter("complete-prompt", {
            session_id: namespace(sessionID),
            cwd: info.location?.directory || "",
          })
        } catch {
          // 完了チェックの記録失敗は turn 管理に影響させない
        }
        return { ok: true, managed: true }
      })
    }

    const commandList = (event) => {
      const source = event?.source
      const call = source?.type === "tool" && source.id ? calls.get(source.id) : undefined
      if (call?.tool === "shell" && call.command) {
        return { full: true, commands: [{ command: call.command, cwd: call.cwd }] }
      }
      // resources はシェル分解後の断片。フル入力が分からないときは連結せず、
      // 制限（deny/ask）の判定にだけ使う（allow への昇格には使わない）。
      return {
        full: false,
        commands: (Array.isArray(event.resources) ? event.resources : [])
          .filter((r) => typeof r === "string" && r.length > 0)
          .map((command) => ({ command })),
      }
    }

    const evaluateShell = async (event) => {
      if (event.effect === "deny") return
      const info = await getInfo(event.sessionID)
      if (!info) {
        event.effect = "deny"
        event.message = "セッション情報を取得できないため、共通ハーネスで判定できません"
        return
      }
      if (!locationMatches(ctx, info)) return
      const child = isChild(info) || isWorker(info)
      const agentId = child ? "opencode-subagent" : ""
      const { full, commands } = commandList(event)
      if (commands.length === 0) return

      let decision = "none"
      let message = ""
      let anyAsk = false
      for (const item of commands) {
        const payload = {
          session_id: namespace(event.sessionID),
          command: item.command,
          cwd: item.cwd || info.location?.directory || "",
          agent_id: agentId,
        }
        const guard = parsePermission(await runAdapter("guard", payload))
        if (guard.kind === "error") {
          event.effect = "deny"
          event.message = guard.message
          return
        }
        const pre = parsePermission(await runAdapter("pr-pre", payload))
        if (pre.kind === "error") {
          event.effect = "deny"
          event.message = pre.message
          return
        }
        for (const result of [guard, pre]) {
          if (result.kind === "deny") {
            event.effect = "deny"
            event.message = result.message || "共通ハーネスが拒否しました"
            return
          }
          if (result.kind === "ask") {
            anyAsk = true
            decision = worst(decision, "ask")
            message = message || result.message
          }
        }
      }

      if (decision === "ask") {
        event.effect = "ask"
        if (message) event.message = message
        return
      }

      // 共通 guard が正常終了 no-decision を返し、同一 source のフル command/cwd と
      // engine resources の全てが guard 担当 family（rm/rmdir/mv）の単純コマンドであるときだけ、
      // config の安全網 ask を allow 候補へ下げる。npm install 等が混ざる複合は昇格しない。
      if (
        event.effect === "ask" &&
        full &&
        commands.length === 1 &&
        guardFamily(commands[0].command) &&
        isSingleSimpleCommand(commands[0].command) &&
        resourcesAreGuardFamily(event.resources)
      ) {
        event.effect = "allow"
        return
      }

      // 共通 pr-mode の PermissionRequest が返す allow を設定の ask に反映する。
      // /pr の起動状態は問わない。フル入力を特定できたメインセッションの単一コマンドだけを
      // 対象にする（resources の断片評価で、無関係な static ask まで allow に上げない）。
      // 設定の allow はそのまま、deny / ask はここへ来ない。
      if (
        full &&
        commands.length === 1 &&
        !child &&
        event.effect === "ask" &&
        !anyAsk &&
        isSingleSimpleCommand(commands[0].command)
      ) {
        const result = parseRequestAllow(
          await runAdapter("pr-request", {
            session_id: namespace(event.sessionID),
            command: commands[0].command,
            cwd: commands[0].cwd || info.location?.directory || "",
          }),
        )
        if (result.kind === "error") {
          event.effect = "deny"
          event.message = result.message
          return
        }
        if (result.kind === "allow") {
          event.effect = "allow"
        }
      }
    }

    const eventSessionID = (event) => {
      return (
        event?.data?.sessionID ||
        event?.sessionID ||
        event?.properties?.sessionID ||
        event?.data?.session?.id ||
        ""
      )
    }

    const resultText = (result) => {
      if (typeof result === "string") return result
      if (!result) return ""
      if (typeof result.stdout === "string") return result.stdout
      if (typeof result.output === "string") return result.output
      if (typeof result.text === "string") return result.text
      if (typeof result.metadata?.stdout === "string") return result.metadata.stdout
      if (Array.isArray(result.content)) {
        return result.content
          .map((part) => (typeof part === "string" ? part : typeof part?.text === "string" ? part.text : ""))
          .join("\n")
      }
      return ""
    }

    // Tool.Output / ToolExecuteCompleted の実 shape（content + metadata.status/exit）を見る。
    // stdout に成功マーカーがあっても、非 0 exit や error/interrupted は成功として扱わない。
    const toolCompleted = (event) => {
      if (event?.error) return false
      if (event?.status && event.status !== "completed") return false
      const result = event?.result
      if (!result || typeof result !== "object") return false
      const metadata = result.metadata
      if (metadata && typeof metadata === "object") {
        if (typeof metadata.exit === "number" && metadata.exit !== 0) return false
        if (typeof metadata.status === "string" && metadata.status !== "completed") return false
      }
      return true
    }

    const latestUserID = async (sessionID) => {
      try {
        const messages = await ctx.session.context({ sessionID })
        return { ok: true, id: latestRealUser(messages)?.id || "" }
      } catch {
        return { ok: false, id: "" }
      }
    }

    const resolveRoot = async (sessionID) => {
      let info = await getInfo(sessionID)
      if (!info) return undefined
      let rootID = sessionID
      for (let i = 0; i < 20; i++) {
        if (isWorker(info)) return undefined
        if (!info.parentID) return { rootID, info }
        rootID = info.parentID
        info = await getInfo(rootID)
        if (!info) return undefined
      }
      return undefined
    }

    const postVerify = async (sessionID, payload) => {
      if (disposed) return
      const root = await resolveRoot(sessionID)
      if (!root) return // delegated-worker とその子は終了ゲート対象外
      if (!locationMatches(ctx, root.info)) return
      const run = await runAdapter("verify-post", {
        session_id: namespace(root.rootID),
        ...payload,
      })
      // 記録に失敗した turn だけ警告する。成功した記録で回復させる（失敗を残し続けない）。
      const state = sessions.get(root.rootID)
      if (state) state.verifyBroken = !run.ok
      // 完了チェックゲートにも同じ集約先で記録する（失敗は他の判定に影響させない）
      await runAdapter("complete-post", { session_id: namespace(root.rootID), ...payload })
    }

    // どれか必須フックの登録に失敗したら plugin のセットアップを失敗させる。
    // 動的ガードが無い状態で「たまたま通る」ことを避ける（設定側の ask は残す）。
    const disposeRegistrations = async () => {
      for (const registration of registrations.splice(0)) {
        try {
          await registration.dispose()
        } catch {
          // cleanup の失敗は握りつぶす
        }
      }
    }
    const register = async (promise, name) => {
      let registration
      try {
        registration = await promise
      } catch (error) {
        await disposeRegistrations()
        throw new Error(`shared-harness: ${name} フックの登録に失敗しました: ${error?.message || error}`)
      }
      if (!registration?.dispose) {
        await disposeRegistrations()
        throw new Error(`shared-harness: ${name} フックの登録結果に dispose がありません`)
      }
      registrations.push(registration)
    }

    // 依存（jq / 共通スクリプト）の健全性を setup 時に確認する。異常なら plugin を読み込ませず、
    // config に残した static ask をそのまま安全網として使う（動的 guard が壊れたまま通さない）。
    const health = await runAdapter("guard", {
      session_id: `${OPENCODE_PREFIX}health-check`,
      command: "true",
      cwd: ctx?.location?.directory || "/",
    })
    if (!health.ok || health.stdout.trim()) {
      throw new Error(
        `shared-harness: 共通 guard の健全性確認に失敗しました: ${health.stderr || health.error || health.stdout}`,
      )
    }

    if (typeof ctx.permission?.hook !== "function") {
      throw new Error("shared-harness: permission.hook が利用できません")
    }
    await register(
      ctx.permission.hook("evaluate", async (event) => {
        if (event.action === "shell") await evaluateShell(event)
      }),
      "permission.evaluate",
    )

    if (typeof ctx.tool?.hook !== "function") {
      throw new Error("shared-harness: tool.hook が利用できません")
    }
    await register(
      ctx.tool.hook("execute.before", (event) => {
        if (!event?.id || !event.sessionID) return
        const tool = event.tool
        if (tool === "shell") {
          const command = event.input?.command
          if (typeof command !== "string" || !command) return
          const info = sessions.get(event.sessionID)
          calls.set(event.id, {
            tool,
            sessionID: event.sessionID,
            command,
            cwd: event.input?.workdir || event.input?.cwd || info?.cwd || "",
            agentId: "",
          })
          return
        }
        if (tool === "edit" || tool === "write" || tool === "patch") {
          calls.set(event.id, {
            tool,
            sessionID: event.sessionID,
            path: event.input?.path || event.input?.filePath || "",
            agentId: "",
          })
        }
      }),
      "tool.execute.before",
    )

    await register(
      ctx.tool.hook("execute.after", async (event) => {
        const call = event?.id ? calls.get(event.id) : undefined
        if (event?.id) calls.delete(event.id)
        if (!call || !toolCompleted(event)) return
        if (call.tool === "shell") {
          const info = await getInfo(call.sessionID)
          const cwd = call.cwd || info?.location?.directory || ""
          await postVerify(call.sessionID, {
            tool_name: "Bash",
            command: call.command,
            stdout: resultText(event.result),
            cwd,
          })
          return
        }
        if ((call.tool === "edit" || call.tool === "write" || call.tool === "patch") && call.path) {
          await postVerify(call.sessionID, {
            tool_name: call.tool === "write" ? "Write" : "Edit",
            file_path: call.path,
          })
        }
      }),
      "tool.execute.after",
    )

    if (typeof ctx.session?.hook !== "function") {
      throw new Error("shared-harness: session.hook が利用できません")
    }
    await register(
      ctx.session.hook("context", async (event) => {
        const sessionID = event?.sessionID
        if (!sessionID) return
        const info = await getInfo(sessionID)
        if (!info) return
        // turn の切り替え判断は syncTurn に一本化する。ここでの失敗は終了判定で再試行される。
        await syncTurn(sessionID, info)
      }),
      "session.context",
    )

    if (typeof ctx.event?.subscribe !== "function") {
      throw new Error("shared-harness: event.subscribe が利用できません")
    }
    let events
    try {
      events = ctx.event.subscribe({ signal: controller.signal })
    } catch (error) {
      controller.abort()
      await disposeRegistrations()
      throw new Error(`shared-harness: event.subscribe に失敗しました: ${error?.message || error}`)
    }
    // synthetic は必ず世代と disposed を直前に確認してから送る（unload・新 user・新実行で無効）。
    const sendSynthetic = async (sessionID, state, generation, payload) => {
      if (!alive(sessionID, state, generation)) return false
      try {
        await ctx.session.synthetic({ sessionID, ...payload })
        return true
      } catch {
        return false
      }
    }

    const notifyFailure = (sessionID, state, generation, text, kind) => {
      if (!alive(sessionID, state, generation) || state.nudgeFailed) return Promise.resolve(false)
      state.nudgeFailed = true
      return sendSynthetic(sessionID, state, generation, {
        text,
        delivery: "steer",
        // 実機では resume 省略でも steer が再開するため、再開しないことを明示する
        resume: false,
        metadata: { source: "dotfiles.shared-harness", kind },
      })
    }
    const notifyVerifyFailure = (sessionID, state, generation, text) =>
      notifyFailure(sessionID, state, generation, text, "verify-gate-error")

    const GATES = {
      verify: {
        name: "verify-gate",
        suffix: "検証を実行してから終了してください。",
        failure: "verify-gate: 検証の再開に失敗しました。変更は未検証です。検証コマンドを実行してから終了してください。",
      },
      completion: {
        name: "completion-gate",
        suffix: "確認結果を報告に書いてから終了してください。",
        failure:
          "completion-gate: 完了チェックの再開に失敗しました。要件ごとの確認結果を報告に書いてから終了してください。",
      },
    }

    // Stop 相当の判定結果（block / systemMessage）を synthetic に反映する。何もしなければ false。
    // 再開は turn ごとに 1 回（state.nudged を verify / completion で共有）、警告も 1 回だけ。
    const applyStopDecision = async (sessionID, state, generation, userID, parsed, gate) => {
      const current = () => alive(sessionID, state, generation)
      if (parsed.decision === "block" && parsed.reason) {
        if (state.nudged) {
          // この turn は 1 回再開済み。pending は消さず、警告を 1 回だけ残して終える
          // （delivery:steer 自体が再開する環境でも、警告の連鎖でループしない）。
          // 次の実 user は新しい turn として再び 1 回だけ促せる。
          if (state.warned || !current() || state.userID !== userID) return true
          state.warned = true
          await sendSynthetic(sessionID, state, generation, {
            text: parsed.reason,
            delivery: "steer",
            resume: false,
            metadata: { source: "dotfiles.shared-harness", kind: `${gate.name}-warning` },
          })
          return true
        }
        // synthetic の直前に generation・最新実 user・location・outcome を再確認する
        const latest = await latestUserID(sessionID)
        const now = await getInfo(sessionID)
        if (!current() || state.userID !== userID || state.nudged) return true
        if (!latest.ok || (latest.id && latest.id !== userID)) return true
        if (!now || !locationMatches(ctx, now) || now.outcome !== "succeeded") return true
        state.nudged = true
        const sent = await sendSynthetic(sessionID, state, generation, {
          text: `${parsed.reason}\n\n${gate.suffix}`,
          delivery: "steer",
          resume: true,
          metadata: { source: "dotfiles.shared-harness", kind: `${gate.name}-resume` },
        })
        if (!sent && alive(sessionID, state, generation)) {
          state.nudged = false
          await notifyFailure(sessionID, state, generation, gate.failure, `${gate.name}-error`)
        }
        return true
      }

      if (parsed.systemMessage) {
        // verify は active=false では通常返らないが、返っても pending は消さず警告だけにする。
        if (state.warned || !current() || state.userID !== userID) return true
        state.warned = true
        await sendSynthetic(sessionID, state, generation, {
          text: parsed.systemMessage,
          delivery: "steer",
          resume: false,
          metadata: { source: "dotfiles.shared-harness", kind: `${gate.name}-warning` },
        })
        return true
      }
      return false
    }

    const parseStop = (run) => {
      if (!run.stdout.trim()) return {}
      try {
        return JSON.parse(run.stdout)
      } catch {
        return undefined
      }
    }

    // 終了判定は session ごとの job。event stream は待たず、started / interrupted は
    // generation の更新だけで即時に旧 job を無効化する。
    const runSucceededJob = async (sessionID, generation) => {
      const state = sessions.get(sessionID)
      if (!state) return
      const current = () => alive(sessionID, state, generation)
      try {
        if (!current()) return
        const info = await getInfo(sessionID)
        if (!current()) return
        if (!info || isChild(info) || isWorker(info)) return
        if (!locationMatches(ctx, info)) return
        // 実 active の outcome は null。完了は succeeded のときだけ扱う（null は通さない）
        if (info.outcome !== "succeeded") return
        // 最新の実配送 user をこの job でも引き直す
        const sync = await syncTurn(sessionID, info)
        if (!current()) return
        if (!sync.ok) {
          await notifyVerifyFailure(
            sessionID,
            state,
            generation,
            "verify-gate: 変更の記録または検証判定に失敗しました。変更は未検証の可能性があります。検証コマンドを実行してから終了してください（自動再開はしません）。",
          )
          return
        }
        if (!sync.managed) return
        // job 開始時の turn を固定する。実 user が変わったら別 turn として扱い、再開しない
        const userID = state.userID
        if (!userID) return
        if (state.verifyBroken) {
          await notifyVerifyFailure(
            sessionID,
            state,
            generation,
            "verify-gate: 変更の記録または検証判定に失敗しました。変更は未検証の可能性があります。検証コマンドを実行してから終了してください（自動再開はしません）。",
          )
          return
        }
        // active=true（common gate の Stop 実装）は保留状態を消す副作用がある。
        // OpenCode 側は常に active=false で問い合わせ、pending は成功した検証だけで消す。
        const run = await runAdapter("verify-stop", {
          session_id: namespace(sessionID),
          stop_hook_active: false,
        })
        if (!current() || state.userID !== userID) return
        if (!run.ok) {
          await notifyVerifyFailure(
            sessionID,
            state,
            generation,
            "verify-gate: 終了時の検証判定に失敗しました。変更は未検証の可能性があります。検証コマンドを実行してから終了してください（自動再開はしません）。",
          )
          return
        }
        const parsed = parseStop(run)
        if (!parsed) {
          await notifyVerifyFailure(
            sessionID,
            state,
            generation,
            "verify-gate: 検証判定の JSON を解釈できませんでした。変更は未検証の可能性があります（自動再開はしません）。",
          )
          return
        }
        // verify が block / 警告の turn では completion を呼ばない（completion の状態を消費しない）
        if (await applyStopDecision(sessionID, state, generation, userID, parsed, GATES.verify)) return

        // 検証済み、または記録なし
        if (!current() || state.userID !== userID) return
        state.nudged = false
        state.warned = false

        // 続けて完了チェック（PDCA の Check）。失敗しても再開・警告はしない（verify の判定は済んでいる）
        const done = await runAdapter("complete-stop", {
          session_id: namespace(sessionID),
          cwd: info.location?.directory || "",
        })
        if (!current() || state.userID !== userID || !done.ok) return
        const completion = parseStop(done)
        if (!completion) return
        await applyStopDecision(sessionID, state, generation, userID, completion, GATES.completion)
      } catch {
        // 判定中の例外では再開しない
      }
    }

    void (async () => {
      try {
        for await (const event of events) {
          if (disposed) return
          if (event?.type === "session.execution.started") {
            // 進行中の検証ジョブを即座に無効化する（待機はしない）
            const sid = eventSessionID(event)
            if (sid) sessionState(sid).generation++
            continue
          }
          if (event?.type === "session.execution.failed" || event?.type === "session.execution.interrupted") {
            const sid = eventSessionID(event)
            if (sid) sessionState(sid).generation++
            continue
          }
          if (event?.type === "session.execution.succeeded") {
            const sid = eventSessionID(event)
            if (!sid) continue
            const state = sessionState(sid)
            const generation = state.generation
            // 同じ generation の succeeded を二重に処理しない
            if (state.stopGeneration === generation) continue
            state.stopGeneration = generation
            // 重い終了判定は job に任せ、別 session のイベント処理を止めない
            void runSucceededJob(sid, generation)
            continue
          }
          if (event?.type === "session.deleted") {
            const sid = eventSessionID(event)
            if (sid) {
              sessions.delete(sid)
              for (const [id, call] of calls) {
                if (call.sessionID === sid) calls.delete(id)
              }
            }
          }
        }
      } catch {
        // abort 時の例外は無視する
      }
    })()

    return async () => {
      disposed = true
      controller.abort()
      // 進行中の job / synthetic を全て無効化してから登録を外す。
      // 以後の job は alive() が false になり、古い state を書き戻さない。
      for (const state of sessions.values()) state.generation++
      await disposeRegistrations()
      calls.clear()
      sessions.clear()
    }
  },
}
