// shared-harness.js の state テスト。実際の adapter → 共通 guard / pr-mode / verify-gate を使う。
// OpenCode 本体は起動せず、plugin が受け取る公開 hook の event shape を再現する。
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import plugin from "../../opencode/plugins/shared-harness.js"

const WORK = path.resolve(import.meta.dirname, "../..")
const BASE = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), "claude-oc-plugin-"))
process.env.TMPDIR = path.join(BASE, "tmp")
process.env.HOME = path.join(BASE, "home")
fs.mkdirSync(path.join(process.env.HOME, ".claude"), { recursive: true })
fs.mkdirSync(process.env.TMPDIR, { recursive: true })
fs.mkdirSync(path.join(process.env.HOME, "orca/workspaces/repo/tmp"), { recursive: true })
const SAFE = path.join(process.env.HOME, "orca/workspaces/repo/tmp/safe")
const REPOS = path.join(BASE, "repos")
const REPO_MAIN = path.join(REPOS, "main")
const REPO_FEAT = path.join(REPOS, "feat")
for (const [dir, branch] of [
  [REPO_MAIN, "main"],
  [REPO_FEAT, "feat/x"],
]) {
  fs.mkdirSync(dir, { recursive: true })
  execFileSync("git", ["init", "-q", "-b", branch, dir])
}

let pass = 0
const check = (name, fn) => {
  try {
    fn()
    pass++
  } catch (error) {
    console.error(`  NG ${name}: ${error.message}`)
    throw error
  }
}

const makeCtx = (sessions, messages) => {
  const handlers = { permission: [], before: [], after: [], context: [] }
  const synthetics = []
  let disposed = 0
  let aborted = false
  let waiter = null
  const queue = []
  const stream = {
    [Symbol.asyncIterator]() {
      return this
    },
    next() {
      if (queue.length) return Promise.resolve({ value: queue.shift(), done: false })
      if (aborted) return Promise.resolve({ done: true })
      return new Promise((resolve) => {
        waiter = resolve
      })
    },
    return() {
      aborted = true
      if (waiter) waiter({ done: true })
      return Promise.resolve({ done: true })
    },
  }
  const registration = () => ({
    dispose: async () => {
      disposed++
    },
  })
  const ctx = {
    location: { directory: WORK },
    permission: {
      hook: async (_name, cb) => {
        handlers.permission.push(cb)
        return registration()
      },
    },
    tool: {
      hook: async (name, cb) => {
        handlers[name === "execute.before" ? "before" : "after"].push(cb)
        return registration()
      },
    },
    session: {
      hook: async (_name, cb) => {
        handlers.context.push(cb)
        return registration()
      },
      get: async ({ sessionID }) => sessions[sessionID],
      context: async ({ sessionID }) => messages[sessionID] || [],
      synthetic: async (input) => {
        synthetics.push(input)
      },
    },
    event: {
      subscribe: ({ signal }) => {
        signal.addEventListener("abort", () => {
          aborted = true
          if (waiter) waiter({ done: true })
        })
        return stream
      },
    },
  }
  const push = (event) => {
    if (waiter) {
      const resolve = waiter
      waiter = null
      resolve({ value: event, done: false })
    } else {
      queue.push(event)
    }
  }
  return { ctx, handlers, synthetics, push, disposed: () => disposed }
}

const callPermission = async (h, event) => {
  for (const cb of h.handlers.permission) await cb(event)
}
const callBefore = async (h, event) => {
  for (const cb of h.handlers.before) await cb(event)
}
const callAfter = async (h, event) => {
  for (const cb of h.handlers.after) await cb(event)
}
const callContext = async (h, sessionID) => {
  for (const cb of h.handlers.context) await cb({ sessionID })
}
const waitFor = async (fn, ms = 5000) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (fn()) return
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error("timeout")
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const rootInfo = (id, extra = {}) => ({
  id,
  agent: "build",
  location: { directory: WORK },
  outcome: "succeeded",
  ...extra,
})
const user = (id, text, extra = {}) => ({ type: "user", id, text, ...extra })

const sessions = {}
const messages = {}
const h = makeCtx(sessions, messages)
let cleanup
try {
  cleanup = await plugin.setup(h.ctx)
  check("setup-registers-hooks", () => {
    assert.equal(h.handlers.permission.length, 1)
    assert.equal(h.handlers.before.length, 1)
    assert.equal(h.handlers.after.length, 1)
    assert.equal(h.handlers.context.length, 1)
  })

  // ヘルパー: worktree のフル入力を記録して permission を評価する
  const shell = async (sessionID, command, workdir, id, agent = "build") => {
    await callBefore(h, {
      tool: "shell",
      sessionID,
      agent,
      messageID: `m-${id}`,
      id,
      input: { command, workdir },
    })
    const event = {
      sessionID,
      agent,
      action: "shell",
      resources: [command],
      source: { type: "tool", messageID: `m-${id}`, id },
      effect: "ask",
    }
    await callPermission(h, event)
    return event
  }

  // 既定ブランチ以外は /pr を起動していなくても commit を自動許可する
  sessions.feat = rootInfo("feat")
  messages.feat = [user("f1", "hello")]
  await callContext(h, "feat")
  const featCommit = await shell("feat", "git commit -m x", REPO_FEAT, "f1c")
  check("feature-commit-allow-without-pr", () => assert.equal(featCommit.effect, "allow"))

  // 通常プロンプトと /pr プロンプトで挙動が変わらない
  messages.feat.push(user("f2", "/pr"))
  await callContext(h, "feat")
  const featCommitPr = await shell("feat", "git commit -m x", REPO_FEAT, "f2c")
  check("prompt-independent-allow", () => assert.equal(featCommitPr.effect, "allow"))

  // 既定ブランチへの commit / push は /pr 中でも deny
  sessions.main = rootInfo("main")
  messages.main = [user("m1", "/pr")]
  await callContext(h, "main")
  const mainCommit = await shell("main", "git commit -m x", REPO_MAIN, "m1c")
  check("protected-commit-deny", () => assert.equal(mainCommit.effect, "deny"))
  const mainPush = await shell("main", "git push", REPO_MAIN, "m1p")
  check("protected-push-deny", () => assert.equal(mainPush.effect, "deny"))
  const pushMain = await shell("feat", "git push origin main", REPO_FEAT, "f1p")
  check("push-to-protected-deny", () => assert.equal(pushMain.effect, "deny"))

  // マージは常に ask、force push は deny、宛先不明の push は ask
  const merge = await shell("feat", "gh pr merge 1", REPO_FEAT, "f1g")
  check("merge-keeps-ask", () => assert.equal(merge.effect, "ask"))
  const force = await shell("feat", "git push --force origin x", REPO_FEAT, "f1f")
  check("force-push-deny", () => assert.equal(force.effect, "deny"))
  const vars = await shell("feat", 'git push origin "$BRANCH"', REPO_FEAT, "f1v")
  check("vars-push-ask", () => assert.equal(vars.effect, "ask"))

  // 通常子・worker の Git 書き込みは agent_id 付きで拒否する
  sessions.child = rootInfo("child", { parentID: "feat" })
  const child = await shell("child", "git commit -m x", REPO_FEAT, "c1")
  check("child-git-deny", () => assert.equal(child.effect, "deny"))
  sessions.worker = rootInfo("worker", { agent: "delegated-worker" })
  const worker = await shell("worker", "git push origin x", REPO_FEAT, "w1", "delegated-worker")
  check("worker-git-deny", () => assert.equal(worker.effect, "deny"))

  // session.get に失敗したら拒否する（判定に必要な情報が無い）
  sessions.getfail = rootInfo("getfail")
  const realGet = h.ctx.session.get
  h.ctx.session.get = async ({ sessionID }) => {
    if (sessionID === "getfail") throw new Error("get failed")
    return realGet({ sessionID })
  }
  const getFail = {
    sessionID: "getfail",
    action: "shell",
    resources: ["git commit -m x"],
    effect: "ask",
  }
  await callPermission(h, getFail)
  h.ctx.session.get = realGet
  check("get-failure-denies", () => {
    assert.equal(getFail.effect, "deny")
    assert.match(getFail.message, /セッション情報/)
  })

  // context の取得に失敗しても、Git の許可判定は会話に依存しないので allow のまま
  sessions.nocontext = rootInfo("nocontext")
  const realContextForPerm = h.ctx.session.context
  h.ctx.session.context = async ({ sessionID }) => {
    if (sessionID === "nocontext") throw new Error("context failed")
    return realContextForPerm({ sessionID })
  }
  const noContext = await shell("nocontext", "git commit -m x", REPO_FEAT, "n1")
  h.ctx.session.context = realContextForPerm
  check("context-failure-does-not-deny", () => assert.equal(noContext.effect, "allow"))

  // resources しか無い fallback は制限の追加だけ。pr-request の allow に昇格しない。
  const fallbackInstall = {
    sessionID: "feat",
    agent: "build",
    action: "shell",
    resources: ["npm install -g pkg"],
    effect: "ask",
  }
  await callPermission(h, fallbackInstall)
  check("fallback-install-stays-ask", () => assert.equal(fallbackInstall.effect, "ask"))
  const fallbackGit = {
    sessionID: "feat",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    effect: "ask",
  }
  await callPermission(h, fallbackGit)
  check("fallback-git-stays-ask", () => assert.equal(fallbackGit.effect, "ask"))

  // guard 担当 family の安全な削除は従来どおり allow へ下げる
  fs.mkdirSync(SAFE, { recursive: true })
  const safeRm = `rm -rf ${SAFE}`
  const safe = await shell("feat", safeRm, WORK, "s1")
  check("safe-guard-family-downgraded", () => assert.equal(safe.effect, "allow"))

  const compositeCmd = `rm -rf ${SAFE} && npm install -g pkg`
  const composite = await shell("feat", compositeCmd, WORK, "s2")
  check("composite-not-downgraded", () => assert.equal(composite.effect, "ask"))

  const findCmd = "find . -delete"
  const findDelete = await shell("feat", findCmd, WORK, "s3")
  check("find-not-downgraded", () => assert.notEqual(findDelete.effect, "allow"))

  const explicitDeny = {
    sessionID: "feat",
    action: "shell",
    resources: ["rm -rf /"],
    effect: "deny",
  }
  await callPermission(h, explicitDeny)
  check("explicit-deny-kept", () => assert.equal(explicitDeny.effect, "deny"))

  // 会話の context が取れない session でも、既定ブランチ以外の commit は許可する
  sessions.broken = rootInfo("broken")
  const brokenGit = await shell("broken", "git commit -m x", REPO_FEAT, "b1")
  check("no-user-context-still-allows", () => assert.equal(brokenGit.effect, "allow"))

  // 中断しても PR 状態を持たない（次の commit 判定はブランチだけで決まる）
  h.push({ type: "session.execution.interrupted", data: { sessionID: "feat" } })
  await sleep(80)
  const afterInterrupt = await shell("feat", "git commit -m x", REPO_FEAT, "f3c")
  check("interrupt-does-not-deny", () => assert.equal(afterInterrupt.effect, "allow"))

  // verify-gate: 編集 → 成功終了で 1 回だけ再開。2 回目は pending を消さず警告だけ。
  const pendingFile = path.join(process.env.TMPDIR, "claude-verify-gate-opencode-verify")
  sessions.verify = rootInfo("verify")
  messages.verify = [user("vu1", "change")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "verify",
    agent: "build",
    messageID: "vm1",
    id: "ve1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "ve1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  h.push({ type: "session.execution.started", data: { sessionID: "verify" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "verify" } })
  await waitFor(() => h.synthetics.some((s) => s.sessionID === "verify"))
  const firstNudge = h.synthetics.find((s) => s.sessionID === "verify")
  check("verify-first-nudge-resumes", () => {
    assert.equal(firstNudge.resume, true)
    assert.equal(firstNudge.delivery, "steer")
  })
  h.push({ type: "session.execution.started", data: { sessionID: "verify" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "verify" } })
  await waitFor(() => h.synthetics.filter((s) => s.sessionID === "verify").length >= 2)
  const warning = h.synthetics.filter((s) => s.sessionID === "verify")[1]
  check("verify-warning-without-resume", () => {
    // 実機では resume 省略でも steer が再開するため、明示的な false を要求する
    assert.equal(warning.resume, false)
    assert.match(warning.text, /まだ成功していません/)
    assert.equal(fs.existsSync(pendingFile), true)
  })

  // 同じ turn でさらに終了イベントが来ても警告を繰り返さない
  const warnCount = h.synthetics.filter((s) => s.sessionID === "verify").length
  h.push({ type: "session.execution.started", data: { sessionID: "verify" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "verify" } })
  await sleep(250)
  check("warning-once-per-turn", () =>
    assert.equal(h.synthetics.filter((s) => s.sessionID === "verify").length, warnCount),
  )

  // 次の実 user は新しい turn として、未検証 pending に対して再び 1 回だけ促せる
  messages.verify.push(user("vu2", "next turn"))
  await callContext(h, "verify")
  h.push({ type: "session.execution.started", data: { sessionID: "verify" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "verify" } })
  await waitFor(() => h.synthetics.filter((s) => s.sessionID === "verify").length >= 3)
  const nextTurnNudge = h.synthetics.filter((s) => s.sessionID === "verify")[2]
  check("next-user-resumes-again", () => {
    assert.equal(nextTurnNudge.resume, true)
    assert.equal(fs.existsSync(pendingFile), true)
  })

  // 実際の Tool.Output shape: status completed + metadata.exit 0 の成功でだけ解除する
  sessions.verified = rootInfo("verified")
  messages.verified = [user("vv1", "change")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "verified",
    agent: "build",
    messageID: "vvm1",
    id: "vve1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "vve1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  await callBefore(h, {
    tool: "shell",
    sessionID: "verified",
    agent: "build",
    messageID: "vvm2",
    id: "vvs1",
    input: { command: `bash ${WORK}/.claude/tests/run.sh`, workdir: WORK },
  })
  await callAfter(h, {
    id: "vvs1",
    status: "completed",
    result: {
      content: [{ type: "text", text: "すべて通過" }],
      metadata: { status: "completed", truncated: false, exit: 0 },
    },
  })
  const beforeVerified = h.synthetics.length
  h.push({ type: "session.execution.started", data: { sessionID: "verified" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "verified" } })
  await sleep(250)
  check("verified-run-does-not-nudge", () => assert.equal(h.synthetics.length, beforeVerified))

  // 非 0 exit の stdout に成功文字があっても pending を消さない
  sessions.exitfail = rootInfo("exitfail")
  messages.exitfail = [user("ef1", "change")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "exitfail",
    agent: "build",
    messageID: "efm1",
    id: "efe1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "efe1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  await callBefore(h, {
    tool: "shell",
    sessionID: "exitfail",
    agent: "build",
    messageID: "efm2",
    id: "efs1",
    input: { command: `bash ${WORK}/.claude/tests/run.sh`, workdir: WORK },
  })
  await callAfter(h, {
    id: "efs1",
    status: "completed",
    result: {
      content: [{ type: "text", text: "すべて通過" }],
      metadata: { status: "completed", truncated: false, exit: 1 },
    },
  })
  const beforeExitFail = h.synthetics.length
  h.push({ type: "session.execution.started", data: { sessionID: "exitfail" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "exitfail" } })
  await waitFor(() => h.synthetics.length > beforeExitFail)
  check("nonzero-exit-does-not-clear", () => assert.equal(h.synthetics.at(-1).sessionID, "exitfail"))

  // 通常子の編集は親 main に集約する
  sessions.root2 = rootInfo("root2")
  messages.root2 = [user("r2u1", "parent")]
  sessions.child2 = rootInfo("child2", { parentID: "root2" })
  messages.child2 = [user("c2u1", "child")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "child2",
    agent: "build",
    messageID: "cm2",
    id: "ce2",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "ce2", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  const beforeChild = h.synthetics.length
  h.push({ type: "session.execution.started", data: { sessionID: "root2" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "root2" } })
  await waitFor(() => h.synthetics.length > beforeChild)
  check("child-edit-attributed-to-root", () =>
    assert.equal(h.synthetics.at(-1).sessionID, "root2"),
  )

  // delegated-worker は編集・終了ともゲート対象外
  sessions.worker2 = rootInfo("worker2", { agent: "delegated-worker" })
  messages.worker2 = [user("w2u1", "worker")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "worker2",
    agent: "delegated-worker",
    messageID: "wm2",
    id: "we2",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "we2", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  const beforeWorker = h.synthetics.length
  h.push({ type: "session.execution.started", data: { sessionID: "worker2" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "worker2" } })
  await sleep(200)
  check("worker-not-nudged", () => assert.equal(h.synthetics.length, beforeWorker))

  // 他 location は無視する
  sessions.other = rootInfo("other", { location: { directory: "/tmp/other-location" } })
  messages.other = [user("ou1", "other")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "other",
    agent: "build",
    messageID: "om1",
    id: "oe1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "oe1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  const beforeOther = h.synthetics.length
  h.push({ type: "session.execution.started", data: { sessionID: "other" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "other" } })
  await sleep(200)
  check("other-location-ignored", () => assert.equal(h.synthetics.length, beforeOther))

  // 中断・失敗は自動再開しない
  sessions.intr = rootInfo("intr", { outcome: "interrupted" })
  messages.intr = [user("iu1", "interrupted")]
  await callBefore(h, {
    tool: "edit",
    sessionID: "intr",
    agent: "build",
    messageID: "im1",
    id: "ie1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "ie1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  const beforeIntr = h.synthetics.length
  h.push({ type: "session.execution.started", data: { sessionID: "intr" } })
  h.push({ type: "session.execution.interrupted", data: { sessionID: "intr" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "intr" } })
  await sleep(200)
  check("interrupted-no-nudge", () => assert.equal(h.synthetics.length, beforeIntr))

  // 旧 success: 判定待ちの間に新しい実行が始まり、新しい実 user が配送されたら再開しない
  sessions.race = rootInfo("race")
  messages.race = [user("r1", "generation")]
  await callContext(h, "race")
  await callBefore(h, {
    tool: "edit",
    sessionID: "race",
    agent: "build",
    messageID: "rm1",
    id: "re1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "re1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  const beforeRace = h.synthetics.length
  let releaseRace
  let raceBlocked = false
  const raceGate = new Promise((resolve) => {
    releaseRace = resolve
  })
  const realContext = h.ctx.session.context
  h.ctx.session.context = async ({ sessionID }) => {
    if (sessionID === "race") {
      raceBlocked = true
      await raceGate
    }
    return realContext({ sessionID })
  }
  h.push({ type: "session.execution.started", data: { sessionID: "race" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "race" } })
  await waitFor(() => raceBlocked)
  messages.race.push(user("r2", "new user"))
  h.push({ type: "session.execution.started", data: { sessionID: "race" } })
  releaseRace()
  await sleep(350)
  h.ctx.session.context = realContext
  check("old-success-no-steer", () => assert.equal(h.synthetics.length, beforeRace))
  // 旧 job は synthetic を送らないだけでなく、次の turn の編集 pending を消さない
  check("old-success-keeps-pending", () =>
    assert.equal(fs.existsSync(path.join(process.env.TMPDIR, "claude-verify-gate-opencode-race")), true),
  )

  // unload: cleanup 後の旧 job は synthetic を送らない
  sessions.unload = rootInfo("unload")
  messages.unload = [user("ul1", "unload")]
  await callContext(h, "unload")
  await callBefore(h, {
    tool: "edit",
    sessionID: "unload",
    agent: "build",
    messageID: "ulm1",
    id: "ule1",
    input: { path: path.join(WORK, "opencode/hooks/harness.sh") },
  })
  await callAfter(h, { id: "ule1", status: "completed", result: { metadata: { status: "completed", exit: 0 } } })
  const beforeUnload = h.synthetics.length
  let releaseUnload
  const unloadGate = new Promise((resolve) => {
    releaseUnload = resolve
  })
  const realGet2 = h.ctx.session.get
  h.ctx.session.get = async ({ sessionID }) => {
    if (sessionID === "unload") await unloadGate
    return realGet2({ sessionID })
  }
  h.push({ type: "session.execution.started", data: { sessionID: "unload" } })
  h.push({ type: "session.execution.succeeded", data: { sessionID: "unload" } })
  await sleep(80)
  await cleanup()
  releaseUnload()
  await sleep(250)
  h.ctx.session.get = realGet2
  check("unload-no-steer", () => assert.equal(h.synthetics.length, beforeUnload))
  check("cleanup-disposes", () => assert.ok(h.disposed() >= 4))
  // 再開するのは verify-gate-resume だけで、警告・error は resume:false を明示する
  check("synthetic-resume-explicit", () => {
    for (const synthetic of h.synthetics) {
      const resumeKind = synthetic.metadata?.kind === "verify-gate-resume"
      assert.equal(synthetic.resume, resumeKind, `kind=${synthetic.metadata?.kind}`)
    }
  })

  // 必須 hook の登録失敗・adapter 不健全は setup を失敗させる（static ask を安全網として残す）
  const badRegister = makeCtx({}, {})
  badRegister.ctx.permission.hook = async () => {
    throw new Error("register failed")
  }
  await assert.rejects(plugin.setup(badRegister.ctx), /permission\.evaluate/)
  pass++

  const badTool = makeCtx({}, {})
  badTool.ctx.tool.hook = async () => {
    throw new Error("tool register failed")
  }
  await assert.rejects(plugin.setup(badTool.ctx), /tool\.execute\.before/)
  check("registration-failure-disposes", () => assert.ok(badTool.disposed() >= 1))

  const badHealth = makeCtx({}, {})
  const oldPath = process.env.PATH
  process.env.PATH = "/nonexistent"
  try {
    await assert.rejects(plugin.setup(badHealth.ctx), /健全性確認に失敗/)
    pass++
  } finally {
    process.env.PATH = oldPath
  }
} finally {
  if (cleanup) await cleanup()
  fs.rmSync(BASE, { recursive: true, force: true })
}

console.log(`  ✓ opencode-plugin: ${pass} 件すべて通過`)
