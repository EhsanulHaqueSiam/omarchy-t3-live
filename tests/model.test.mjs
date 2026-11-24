// node tests/model.test.mjs — checks Model.js, which the QML imports.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const names = "parseHosts parseLine merge count stateKey transitions keys asking stepText prText permText escapeMarkup safeArg elapsed threadUrl"
const M = vm.runInThisContext(`(() => { ${src}\nreturn { ${names.split(" ").join(", ")} } })()`)

const env = "7262cf01-c98b-4af8-af5f-e943001b545d"
const id = "cd44952b-1db2-4a50-acfd-dde0414d497e"
const id2 = "d6f5e8bb-2b83-43d5-8e6a-a1d71aa3ca38"

// Hosts: commas, spaces, and nothing ssh could take as an option.
assert.deepEqual(M.parseHosts(" mac, box2 ,,-oProxyCommand=x, a b"), ["mac", "box2"])

// Feed lines from another machine are untrusted: bad ids, unknown states and
// junk are dropped, text is clipped, odd shapes become null.
const parsed = M.parseLine(JSON.stringify({ env, threads: [
  { id, state: "input", title: "x".repeat(500), question: "q".repeat(900), step: ["command_execution", "c".repeat(900)],
    pr: { n: 12, state: "open", checks: "failure", review: null }, since: "2026-11-23T19:35:48.235Z", ended: "" },
  { id: "$(rm -rf ~)", state: "working", title: "evil" },
  { id, state: "hacked", title: "unknown state" },
  { id: id2, state: "done", title: "<img src=https://example.invalid/t>", step: "nope", pr: { n: "12" }, since: "x", ended: "2026-11-23T20:00:00Z" },
] }))
assert.equal(parsed.threads.length, 2)
const [ask, fin] = parsed.threads
assert.equal(ask.title.length, 120)
assert.equal(ask.question.length, 300)
assert.equal(ask.step.detail.length, 160)
assert.deepEqual(ask.pr, { n: 12, state: "open", checks: "failure", review: "" })
assert.equal(fin.step, null)
assert.equal(fin.pr, null)
assert.equal(fin.since, 0)
assert.ok(fin.ended > 0)
for (const bad of ["not json", "", JSON.stringify({ env: "../x", threads: [] })]) assert.equal(M.parseLine(bad), null)

// Merge: waiting on you first (oldest first), then working (newest), then finished.
const t = (id, state, since, ended = 0) => ({ id, state, since, ended, title: id, step: null, pr: null })
const merged = M.merge({
  "": { env, threads: [t("work-old", "working", 1), t("done", "done", 1, 50)] },
  mac: { env, threads: [t("perm", "perm", 9), t("work-new", "working", 5), t("input", "input", 3)] },
})
assert.deepEqual(merged.map(x => x.id + "@" + x.host), ["input@mac", "perm@mac", "work-new@mac", "work-old@", "done@"])
assert.equal(M.count(merged, "working"), 2)

// Transitions: a host's next snapshot toasts what newly waits or finishes, once.
const before = [t("a", "working", 1), t("b", "input", 2)]
const after = [t("a", "done", 1, 9), t("b", "input", 2), t("c", "perm", 3), t("d", "working", 4)]
assert.deepEqual(M.transitions(M.keys(before), after).map(x => x.id), ["a", "c"])
assert.deepEqual(M.transitions(M.keys(after), after), [])
// A second question on the same thread is a new state, so it toasts again.
assert.deepEqual(M.transitions(M.keys(before), [t("b", "input", 7)]).map(x => x.id), ["b"])

// Step and PR text.
assert.deepEqual(M.stepText({ type: "file_change", detail: "/home/u/x/README.md" }), ["step.edit", "README.md"])
assert.deepEqual(M.stepText({ type: "dynamic_tool", detail: "mcp__t3-code__t3_project_list" }), ["step.tool", "t3_project_list"])
assert.deepEqual(M.stepText({ type: "reasoning", detail: "" }), ["step.thinking", ""])
assert.deepEqual(M.stepText({ type: "checkpoint", detail: "" }), ["", ""])
assert.deepEqual(M.stepText(null), ["", ""])
assert.equal(M.prText({ state: "open", checks: "failure", review: "APPROVED" }), "pr.failing")
assert.equal(M.prText({ state: "merged", checks: "failure" }), "pr.merged")
assert.equal(M.prText({ state: "open", checks: "success", review: "CHANGES_REQUESTED" }), "pr.changes")
assert.equal(M.prText(null), "")

// Permission text names the command when the latest step is that command.
assert.deepEqual(M.permText({ askKind: "command", step: { type: "command_execution", detail: "rm -rf build" } }), ["perm.commandRun", "rm -rf build"])
assert.deepEqual(M.permText({ askKind: "command", step: null }), ["perm.command", ""])
assert.deepEqual(M.permText({ askKind: "file-change" }), ["perm.edit", ""])
assert.deepEqual(M.permText({ askKind: "permission" }), ["perm.other", ""])

// Toast text: markup shows as typed, and a leading "-" can't become a flag.
assert.equal(M.escapeMarkup("<img src=x> & <b>"), "&lt;img src=x&gt; &amp; &lt;b&gt;")
assert.equal(M.safeArg("--exec rm"), "​--exec rm")
assert.equal(M.safeArg("Done: x"), "Done: x")

assert.equal(M.elapsed(134000), "2:14")
assert.equal(M.elapsed(3725000), "1:02:05")
assert.equal(M.elapsed(-5), "0:00")
assert.equal(M.threadUrl({ env, id }), `t3code://threads/${env}/${id}`)

console.log("model tests passed")
