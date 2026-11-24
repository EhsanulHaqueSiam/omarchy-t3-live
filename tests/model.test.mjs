// node tests/model.test.mjs — checks Model.js, which the QML imports.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const names = "parseHosts parseLine owner merge count stateKey transitions keys asking markStale chip face glyph summary limitPhase snoozed dismissed actions tooltip toastText readable inkOn contrast phaseColor projectColor prLook t3Palette luminance stepText prText permText escapeMarkup safeArg elapsed threadUrl"
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

// Merge in mobile's order: needs you (longest waiting first), failed, working
// and starting (newest first), then done and stale.
const t = (id, state, since, ended = 0) => ({ id, state, since, ended, title: id, step: null, pr: null })
const merged = M.merge({
  "": { env, threads: [t("work-old", "working", 1), t("done", "done", 1, 50), t("failed", "failed", 1, 40)] },
  mac: { env, threads: [t("perm", "perm", 9), t("start", "starting", 5), t("input", "input", 3)] },
})
assert.deepEqual(merged.map(x => x.id + "@" + x.host), ["input@mac", "perm@mac", "failed@", "start@mac", "work-old@", "done@"])
assert.equal(M.count(merged, "working"), 1)

// A dropped host: in-flight threads go stale, finished ones leave.
assert.deepEqual(M.markStale([t("a", "working", 1), t("b", "input", 2), t("c", "done", 1, 2)]).map(x => x.id + ":" + x.state), ["a:stale", "b:stale"])

// The bar chip follows mobile: one thread says its phase, only-working
// threads say "N live" (9+), and a mix shows each count instead.
const c = (live, input = 0, perm = 0, stale = 0) => ({ live, input, perm, stale })
assert.deepEqual(M.chip(c(1)), ["working", "", "working"])
assert.deepEqual(M.chip(c(0, 1)), ["answer", "", "input"])
assert.deepEqual(M.chip(c(0, 0, 1)), ["approve", "", "perm"])
assert.deepEqual(M.chip(c(0, 0, 0, 1)), ["offline", "", "stale"])

// Waiting (T3's sidebar word: a watch, background work, or another thread):
// its own word, "N waiting" when alone, a muted count in a mix, ranked after
// working and before done, and never a toast.
const w = (n, live = 0) => ({ live, input: 0, perm: 0, waiting: n, stale: 0 })
assert.deepEqual(M.chip(w(1)), ["waiting", "", "waiting"])
assert.deepEqual(M.chip(w(2)), ["waitingCount", "2", "waiting"])
assert.equal(M.chip(w(1, 2)), null)
assert.deepEqual(M.face(w(1, 2), "").filter(x => x.kind === "num").map(x => x.phase + x.arg), ["working2", "waiting1"])
assert.deepEqual(M.tooltip(w(1, 2)), [["tip.working", 2], ["tip.waiting", 1]])
assert.deepEqual(M.summary([t("a", "waiting", 1), t("b", "done", 1, 2)]), ["summary.waiting", 1])
assert.deepEqual(M.summary([t("a", "waiting", 1), t("b", "working", 1)]), ["summary.working", 1])
assert.deepEqual(M.merge({ "": { env, threads: [t("d", "done", 1, 9), t("w", "waiting", 1), t("x", "working", 1)] } }).map(x => x.id), ["x", "w", "d"])
assert.equal(M.parseLine(JSON.stringify({ env, threads: [{ id, state: "waiting", step: ["watch_pr", "76"] }] })).threads[0].state, "waiting")
assert.deepEqual(M.transitions({}, [t("w", "waiting", 1)]), [])
assert.deepEqual(M.stepText({ type: "watch_pr", detail: "76" }), ["step.watchPr", "76"])
assert.deepEqual(M.stepText({ type: "wait_thread", detail: "" }), ["step.waitThread", ""])
assert.deepEqual(M.stepText({ type: "background", detail: "" }), ["step.backgroundAny", ""])
assert.deepEqual(M.chip(c(3)), ["liveCount", "3", "working"])
assert.deepEqual(M.chip(c(12)), ["liveCount", "9+", "working"])
assert.equal(M.chip(c(2, 1)), null)
assert.equal(M.chip(c(0, 1, 1)), null)

// Failed and limited threads: failure and T3's own recovery are parsed and
// clipped; junk becomes null.
const lim = M.parseLine(JSON.stringify({ env, threads: [
  { id, state: "limited", title: "x", since: "2026-11-24T10:00:00Z", ended: "2026-11-24T10:05:00Z",
    failure: { class: "usage_limit", message: "m".repeat(500), resetAt: "2026-11-24T12:00:00Z" }, recovery: { autoResume: true, snooze: "yes" } },
  { id: id2, state: "failed", title: "y", failure: "nope", recovery: 7 },
] })).threads
assert.equal(lim[0].failure.cls, "usage_limit")
assert.equal(lim[0].failure.message.length, 200)
assert.deepEqual(lim[0].recovery, { autoResume: true, snooze: false })
assert.equal(lim[1].failure, null)
assert.equal(lim[1].recovery, null)

// Where a limited thread stands, and whether it is snoozed out of the bar.
const reset = Date.parse("2026-11-24T12:00:00Z"), early = reset - 60000, late = reset + 1
const L = (recovery = null) => ({ state: "limited", failure: { cls: "usage_limit", resetAt: reset }, recovery })
assert.equal(M.limitPhase(L(), late, undefined), "reset")
assert.equal(M.limitPhase(L({ autoResume: true, snooze: false }), early, { resume: true }), "t3")
assert.equal(M.limitPhase(L(), early, { resume: true }), "armed")
assert.equal(M.limitPhase(L(), early, undefined), "wait")
assert.equal(M.limitPhase({ state: "limited", failure: { resetAt: 0 } }, early), "reset")
assert.equal(M.snoozed(L(), early, { snooze: true }), true)
assert.equal(M.snoozed(L({ autoResume: false, snooze: true }), early), true)
assert.equal(M.snoozed(L(), late, { snooze: true }), false)
assert.equal(M.snoozed(L(), early, undefined), false)
assert.equal(M.snoozed({ state: "failed", failure: { resetAt: reset } }, early, { snooze: true }), false)

// One failed or limited thread says so; in a mix they share one red count.
assert.deepEqual(M.chip({ live: 0, input: 0, perm: 0, stale: 0, failed: 1, limited: 0 }), ["failed", "", "failed"])
assert.deepEqual(M.chip({ live: 0, input: 0, perm: 0, stale: 0, failed: 0, limited: 1 }), ["limit", "", "limited"])
const mixStop = M.face({ live: 2, input: 0, perm: 0, stale: 0, failed: 1, limited: 1 }, "").filter(x => x.kind === "num")
assert.deepEqual(mixStop.map(x => x.arg + ":" + x.phase), ["2:working", "2:failed"])
assert.deepEqual(M.summary([t("a", "working", 1), t("b", "limited", 1, 2)]), ["summary.stopped", 1])

// Every state's buttons: only what that state needs.
const A = (state, ctx = {}) => M.actions({ state }, Object.assign({ phase: "wait", snoozed: false, ownSnooze: false, resuming: false }, ctx)).map(x => x[0]).join(",")
for (const s of ["starting", "working", "stale", "done"]) assert.equal(A(s), "", s)
assert.equal(A("input"), "answer")
assert.equal(A("perm"), "approve")
assert.equal(A("failed"), "resume,dismiss")
assert.equal(A("failed", { resuming: true }), "")
assert.equal(A("limited", { phase: "wait" }), "resumeAt,snooze")
assert.equal(A("limited", { phase: "armed" }), "cancel,snooze")
assert.equal(A("limited", { phase: "t3" }), "snooze")
assert.equal(A("limited", { phase: "reset" }), "resume,dismiss")
assert.equal(A("limited", { phase: "wait", snoozed: true, ownSnooze: true }), "wake")
assert.equal(A("limited", { phase: "wait", snoozed: true, ownSnooze: false }), "")
assert.equal(A("limited", { phase: "reset", resuming: true }), "")
// Opening is the only thing a question or approval offers, whatever else is true.
assert.equal(A("input", { resuming: true, snoozed: true }), "answer")
for (const [, , phase] of [].concat(...["input", "perm", "failed"].map(s => M.actions({ state: s }, { phase: "wait" }))))
  assert.ok(["input", "perm", "working", ""].includes(phase))

// Dismissed: a stopped thread hides until it stops again.
assert.equal(M.dismissed({ state: "failed", ended: 5 }, { dismissed: 5 }), true)
assert.equal(M.dismissed({ state: "failed", ended: 9 }, { dismissed: 5 }), false)
assert.equal(M.dismissed({ state: "working", ended: 5 }, { dismissed: 5 }), false)
assert.equal(M.dismissed({ state: "failed", ended: 5 }, undefined), false)

// Approval text comes from the approval's own item.
assert.deepEqual(M.permText({ askKind: "command", permDetail: "rm -rf build" }), ["perm.commandRun", "rm -rf build"])
assert.deepEqual(M.permText({ askKind: "file-change", permDetail: "/a/b/Hero.tsx" }), ["perm.editFile", "Hero.tsx"])
assert.deepEqual(M.permText({ askKind: "command", permDetail: "", step: { type: "command_execution", detail: "other" } }), ["perm.command", ""])

// The tooltip names each count.
assert.deepEqual(M.tooltip({ live: 3, input: 1, perm: 0, stale: 0, failed: 1, limited: 1 }), [["tip.working", 3], ["tip.input", 1], ["tip.stopped", 2]])

// T3 owns a limit it armed itself: no Resume before or after its reset.
assert.equal(M.limitPhase(L({ autoResume: true, snooze: false }), late, undefined), "t3reset")
assert.equal(A("limited", { phase: "t3reset" }), "")

// The headline: working means running now; stale-only and snoozed-only say so.
assert.deepEqual(M.summary([t("s", "stale", 1)], 0), ["summary.stale", 1])
assert.deepEqual(M.summary([], 2), ["summary.snoozed", 2])
assert.deepEqual(M.summary([t("w", "working", 1), t("s", "stale", 1)], 0), ["summary.working", 1])

// Theme colors: too-dim colors are lifted to read; button labels pick black or white.
const pal = { red: "#c38b7b", green: "#87a9b0", yellow: "#6B5E73", blue: "#b59790", magenta: "#c4d8e2", cyan: "#a5a0b6", muted: "#584e51", fg: "#e0e0e0", bg: "#101315" }
assert.ok(M.contrast(M.readable(pal.yellow, pal.bg, pal.fg), pal.bg) >= 3)
assert.equal(M.readable("#7dd3fc", "#000000", "#ffffff"), "#7dd3fc")
assert.equal(M.inkOn("#fcd34d"), "#000000")
assert.equal(M.inkOn("#4f46e5"), "#ffffff")
assert.equal(M.phaseColor("input", pal), pal.magenta)
assert.equal(M.phaseColor("limited", pal), pal.red)
assert.equal(M.projectColor("indigo", pal), pal.magenta)
assert.equal(M.projectColor("sky", pal), pal.blue)
assert.equal(M.projectColor("gray", pal), pal.muted)
assert.deepEqual(M.prLook({ state: "merged" }, pal), ["\uf419", pal.magenta])
assert.deepEqual(M.prLook({ state: "open", checks: "failure" }, pal), ["\uf407", pal.red])
assert.equal(M.prLook(null, pal), null)

// T3's vivid palette by default, its darker stops on a light surface.
assert.equal(M.t3Palette(false).yellow, "#fcd34d")
assert.equal(M.t3Palette(true).magenta, "#4f46e5")
assert.ok(M.luminance("#ffffff") > 0.9 && M.luminance("#101315") < 0.1)

// Small text reaches 4.5:1; Qt's translucent "#aarrggbb" still counts.
assert.ok(M.contrast(M.readable("#584e51", "#101315", "#e0e0e0", 4.5), "#101315") >= 4.5)
assert.ok(M.contrast(M.readable(pal.yellow, "#cc101315", pal.fg), pal.bg) >= 3)
// Toast text can't turn into markup, however many times it is decoded.
assert.equal(M.toastText("<b>x</b>"), "\u2039b\u203ax\u2039/b\u203a")
for (const s of ["&lt;b&gt;x&lt;/b&gt;", "&#60;b&#62;", "&#x3c;a href=&quot;u&quot;&#x3e;", "&amp;lt;b&amp;gt;"])
  assert.ok(!/&#?[A-Za-z0-9]+;/.test(M.toastText(s)), s)

// New fields from another machine are checked too.
const extra = M.parseLine(JSON.stringify({ env, threads: [{ id, state: "working", title: "x", projectColor: "Blue; rm", issue: "#40471" }, { id: id2, state: "working", title: "y", projectColor: "indigo", issue: "<b>1</b>" }] })).threads
assert.deepEqual(extra.map(x => [x.projectColor, x.issue]), [["", "#40471"], ["indigo", ""]])

// The island face: one word when chip() gives one, colored counts for a mix,
// the finish word during a flash, and numbers only on a vertical bar.
const text = f => f.map(x => x.kind === "mark" ? "T3" : x.kind === "sep" ? "·" : x.kind === "glyph" ? "*" : x.kind === "word" ? x.key + (x.arg ? "(" + x.arg + ")" : "") : x.arg).join(" ")
assert.equal(text(M.face(c(1), "")), "T3 working")
assert.equal(M.face(c(1), "")[1].phase, "")
assert.equal(text(M.face(c(3), "")), "T3 liveCount(3)")
assert.equal(text(M.face(c(3, 1, 1), "")), "T3 3 · 1 · 1")
assert.deepEqual(M.face(c(3, 1, 1), "").filter(x => x.kind === "num").map(x => x.phase), ["working", "input", "perm"])
assert.equal(text(M.face(c(0, 1), "")), "T3 answer")
assert.equal(M.face(c(0, 1), "")[1].phase, "input")
assert.equal(text(M.face(c(2), "done")), "T3 done")
assert.equal(text(M.face(c(3, 1), "", true)), "T3 3 1")
assert.equal(text(M.face(c(1), "failed", true)), "T3 *")
assert.equal(M.glyph("input"), "󰋗")

// The list's headline, mobile's summary.
assert.deepEqual(M.summary([t("a", "input", 1), t("b", "perm", 1), t("c", "working", 1)]), ["summary.needYou", 2])
assert.deepEqual(M.summary([t("a", "working", 1), t("b", "failed", 1, 2)]), ["summary.stopped", 1])
assert.deepEqual(M.summary([t("a", "working", 1), t("b", "starting", 1)]), ["summary.working", 2])
assert.deepEqual(M.summary([t("b", "failed", 1, 2), t("c", "done", 1, 2)]), ["summary.finishedStopped", 1])
assert.deepEqual(M.summary([t("c", "done", 1, 2)]), ["summary.allFinished", 0])


// Transitions: a host's next snapshot toasts what newly waits or finishes, once.
const before = [t("a", "working", 1), t("b", "input", 2)]
const after = [t("a", "done", 1, 9), t("b", "input", 2), t("c", "perm", 3), t("d", "working", 4), t("e", "stale", 1), t("f", "starting", 5)]
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

// One machine reached under two names: a live route keeps it, a stale one gives way.
const routes = { mac: { env, threads: [] }, "mac-wan": { env, threads: [] }, box: { env: id, threads: [] } }
assert.deepEqual(M.owner(routes, {}, "mac", env), { host: "mac-wan", live: true })
assert.deepEqual(M.owner(routes, { "mac-wan": 1 }, "mac", env), { host: "mac-wan", live: false })
assert.equal(M.owner(routes, {}, "box", id), null)
assert.equal(M.owner({ mac: null }, {}, "x", env), null)

console.log("model tests passed")
