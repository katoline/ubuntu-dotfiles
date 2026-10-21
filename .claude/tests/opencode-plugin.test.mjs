// shared-harness.js の state テスト。実際の adapter → 共通 guard / pr-mode / verify-gate を使う。
// OpenCode 本体は起動せず、plugin が受け取る公開 hook の event shape を再現する。
import assert from "node:assert/strict"
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

  // /pr の明示 user で PR 権限が立ち、commit が ask → allow になる
  sessions.pr = rootInfo("pr")
  messages.pr = [user("p1", "/pr")]
  await callContext(h, "pr")
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m1",
    id: "c1",
    input: { command: "git commit -m x", workdir: WORK },
  })
  const prAllow = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "m1", id: "c1" },
    effect: "ask",
  }
  await callPermission(h, prAllow)
  check("explicit-pr-commit-allow", () => assert.equal(prAllow.effect, "allow"))

  // 同じ user のまま context hook が再実行されても切り替えない（prompt admission 相当）
  await callContext(h, "pr")
  const stillPr = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "m1", id: "c1" },
    effect: "ask",
  }
  await callPermission(h, stillPr)
  check("pr-stays-on-same-user", () => assert.equal(stillPr.effect, "allow"))

  // plugin 自身が送る synthetic（検証の再開・警告）は新しい実 user として扱わない
  messages.pr.push(user("syn1", "verify-gate: warning", { metadata: { source: "dotfiles.shared-harness" } }))
  await callContext(h, "pr")
  const stillPrSynthetic = { ...stillPr, effect: "ask" }
  await callPermission(h, stillPrSynthetic)
  check("synthetic-not-new-user", () => assert.equal(stillPrSynthetic.effect, "allow"))

  // 通常 user が来たら PR 権限を解除する
  messages.pr.push(user("p2", "hello"))
  await callContext(h, "pr")
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m2",
    id: "c2",
    input: { command: "git commit -m x", workdir: WORK },
  })
  const normal = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "m2", id: "c2" },
    effect: "ask",
  }
  await callPermission(h, normal)
  check("normal-prompt-clears-pr", () => assert.equal(normal.effect, "deny"))

  // 通常本文に引用された marker / SKILL の H1 では PR モードを開始しない
  messages.pr.push(user("p3", "`<!-- pr-mode-enable -->` と `# PR作成` は本文中の言及"))
  await callContext(h, "pr")
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m3",
    id: "c3",
    input: { command: "git commit -m x", workdir: WORK },
  })
  const quoted = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "m3", id: "c3" },
    effect: "ask",
  }
  await callPermission(h, quoted)
  check("quoted-marker-not-start", () => assert.equal(quoted.effect, "deny"))

  // P1: context hook だけが失敗しても、permission 評価の直前に最新 user を引き直して deny する
  sessions.stale = rootInfo("stale")
  messages.stale = [user("s1", "/pr")]
  await callContext(h, "stale")
  await callBefore(h, {
    tool: "shell",
    sessionID: "stale",
    agent: "build",
    messageID: "sm1",
    id: "sc1",
    input: { command: "git commit -m x", workdir: WORK },
  })
  const stalePr = {
    sessionID: "stale",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "sm1", id: "sc1" },
    effect: "ask",
  }
  await callPermission(h, stalePr)
  check("stale-pr-allow", () => assert.equal(stalePr.effect, "allow"))
  messages.stale.push(user("s2", "normal follow-up"))
  const realStaleContext = h.ctx.session.context
  h.ctx.session.context = async ({ sessionID }) => {
    if (sessionID === "stale") throw new Error("context failed")
    return realStaleContext({ sessionID })
  }
  await callContext(h, "stale")
  h.ctx.session.context = realStaleContext
  await callBefore(h, {
    tool: "shell",
    sessionID: "stale",
    agent: "build",
    messageID: "sm2",
    id: "sc2",
    input: { command: "git commit -m x", workdir: WORK },
  })
  const staleAllow = {
    sessionID: "stale",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "sm2", id: "sc2" },
    effect: "ask",
  }
  await callPermission(h, staleAllow)
  check("stale-pr-denied-after-new-user", () => assert.equal(staleAllow.effect, "deny"))

  // session.get に失敗したら、古い権限を使わず deny する
  sessions.getfail = rootInfo("getfail")
  messages.getfail = [user("g1", "/pr")]
  await callContext(h, "getfail")
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

  // 通常子・worker の Git 書き込みは agent_id 付きで拒否する
  sessions.child = rootInfo("child", { parentID: "pr" })
  messages.child = [user("cu1", "do it")]
  await callBefore(h, {
    tool: "shell",
    sessionID: "child",
    agent: "build",
    messageID: "cm1",
    id: "cc1",
    input: { command: "git commit -m x", workdir: WORK },
  })
  const child = {
    sessionID: "child",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    source: { type: "tool", messageID: "cm1", id: "cc1" },
    effect: "ask",
  }
  await callPermission(h, child)
  check("child-git-deny", () => assert.equal(child.effect, "deny"))

  sessions.worker = rootInfo("worker", { agent: "delegated-worker" })
  messages.worker = [user("wu1", "work")]
  await callBefore(h, {
    tool: "shell",
    sessionID: "worker",
    agent: "delegated-worker",
    messageID: "wm1",
    id: "wc1",
    input: { command: "git push origin x", workdir: WORK },
  })
  const worker = {
    sessionID: "worker",
    agent: "delegated-worker",
    action: "shell",
    resources: ["git push origin x"],
    source: { type: "tool", messageID: "wm1", id: "wc1" },
    effect: "ask",
  }
  await callPermission(h, worker)
  check("worker-git-deny", () => assert.equal(worker.effect, "deny"))

  // force push は /pr 中でも拒否、merge は allow にしない
  messages.pr.push(user("p4", "/pr"))
  await callContext(h, "pr")
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m4",
    id: "c4",
    input: { command: "git push --force origin x", workdir: WORK },
  })
  const force = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["git push --force origin x"],
    source: { type: "tool", messageID: "m4", id: "c4" },
    effect: "ask",
  }
  await callPermission(h, force)
  check("force-push-deny", () => assert.equal(force.effect, "deny"))

  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m5",
    id: "c5",
    input: { command: "gh pr merge 1", workdir: WORK },
  })
  const merge = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["gh pr merge 1"],
    source: { type: "tool", messageID: "m5", id: "c5" },
    effect: "ask",
  }
  await callPermission(h, merge)
  check("merge-keeps-ask", () => assert.equal(merge.effect, "ask"))

  // resources しか無い fallback は制限の追加だけ。pr-request の allow に昇格しない。
  const fallbackInstall = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["npm install -g pkg"],
    effect: "ask",
  }
  await callPermission(h, fallbackInstall)
  check("fallback-install-stays-ask", () => assert.equal(fallbackInstall.effect, "ask"))
  const fallbackGit = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: ["git commit -m x"],
    effect: "ask",
  }
  await callPermission(h, fallbackGit)
  // /pr 中でもフル入力が無いため allow には上げない
  check("fallback-git-stays-ask", () => assert.equal(fallbackGit.effect, "ask"))

  fs.mkdirSync(SAFE, { recursive: true })
  const safeRm = `rm -rf ${SAFE}`
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m6",
    id: "c6",
    input: { command: safeRm, workdir: WORK },
  })
  const safe = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: [safeRm],
    source: { type: "tool", messageID: "m6", id: "c6" },
    effect: "ask",
  }
  await callPermission(h, safe)
  check("safe-guard-family-downgraded", () => assert.equal(safe.effect, "allow"))

  const compositeCmd = `rm -rf ${SAFE} && npm install -g pkg`
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m7",
    id: "c7",
    input: { command: compositeCmd, workdir: WORK },
  })
  const composite = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: [compositeCmd],
    source: { type: "tool", messageID: "m7", id: "c7" },
    effect: "ask",
  }
  await callPermission(h, composite)
  check("composite-not-downgraded", () => assert.equal(composite.effect, "ask"))

  const findCmd = "find . -delete"
  await callBefore(h, {
    tool: "shell",
    sessionID: "pr",
    agent: "build",
    messageID: "m8",
    id: "c8",
    input: { command: findCmd, workdir: WORK },
  })
  const findDelete = {
    sessionID: "pr",
    agent: "build",
    action: "shell",
    resources: [findCmd],
    source: { type: "tool", messageID: "m8", id: "c8" },
    effect: "ask",
  }
  await callPermission(h, findDelete)
  check("find-not-downgraded", () => assert.notEqual(findDelete.effect, "allow"))

  const explicitDeny = {
    sessionID: "pr",
    action: "shell",
    resources: ["rm -rf /"],
    effect: "deny",
  }
  await callPermission(h, explicitDeny)
  check("explicit-deny-kept", () => assert.equal(explicitDeny.effect, "deny"))

  // context が取れない session は、共通 flag が無いので pr-pre が拒否する
  sessions.broken = rootInfo("broken")
  await callContext(h, "broken")
  const broken = {
    sessionID: "broken",
    action: "shell",
    resources: ["git commit -m x"],
    effect: "ask",
  }
  await callPermission(h, broken)
  check("no-user-context-no-authority", () => assert.equal(broken.effect, "deny"))

  // P1: 中断時の canonical clear が失敗したら保持し、次の評価で再試行し、失敗中は deny
  sessions.clearfail = rootInfo("clearfail")
  messages.clearfail = [user("cf1", "/pr")]
  await callContext(h, "clearfail")
  const realPath = process.env.PATH
  process.env.PATH = "/nonexistent"
  h.push({ type: "session.execution.interrupted", data: { sessionID: "clearfail" } })
  await sleep(150)
  const clearBroken = {
    sessionID: "clearfail",
    action: "shell",
    resources: ["git commit -m x"],
    effect: "ask",
  }
  await callPermission(h, clearBroken)
  process.env.PATH = realPath
  check("clear-failure-denies", () => {
    assert.equal(clearBroken.effect, "deny")
    assert.match(clearBroken.message, /解除|PR/)
  })
  const clearRecovered = {
    sessionID: "clearfail",
    action: "shell",
    resources: ["git commit -m x"],
    effect: "ask",
  }
  await callPermission(h, clearRecovered)
  check("clear-retry-then-clear", () => assert.equal(clearRecovered.effect, "deny"))

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
