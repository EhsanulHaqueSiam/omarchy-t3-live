.pragma library

// Pure helpers for Service.qml and BarWidget.qml; tests/model.test.mjs runs
// them under node.

var UUID = /^[0-9a-fA-F-]{8,64}$/
var HOST = /^[A-Za-z0-9_.@][A-Za-z0-9_.@-]*$/
// The phases of T3's own mobile live notification, by our names:
// starting, working (running), input, perm (approval), stale, done, failed,
// plus limited: a run that stopped at a usage limit.
var STATES = ["starting", "working", "input", "perm", "stale", "done", "failed", "limited"]
var ASKING = ["input", "perm"]
var TOASTS = ["input", "perm", "done", "failed", "limited"]

// "mac, box2" -> ["mac", "box2"]; drops names ssh could read as options.
function parseHosts(text) {
  return String(text || "").split(",").map(function(h) { return h.trim() })
    .filter(function(h) { return HOST.test(h) })
}

function clip(value, max) {
  return typeof value === "string" ? value.slice(0, max) : ""
}

function time(value) {
  var ms = Date.parse(value)
  return isNaN(ms) ? 0 : ms
}

// One feed.sh line -> { env, threads } or null. The line comes from another
// machine's database, so every field is checked and clipped here.
function parseLine(line) {
  var data
  try { data = JSON.parse(line) } catch (e) { return null }
  if (!data || typeof data.env !== "string" || !UUID.test(data.env) || !Array.isArray(data.threads)) return null
  var threads = []
  for (var i = 0; i < data.threads.length && threads.length < 50; i++) {
    var t = data.threads[i]
    if (!t || typeof t.id !== "string" || !UUID.test(t.id) || STATES.indexOf(t.state) === -1) continue
    var step = Array.isArray(t.step) ? { type: clip(t.step[0], 40), detail: clip(t.step[1], 160) } : null
    var pr = t.pr && typeof t.pr === "object" && Number.isInteger(t.pr.n) && t.pr.n > 0
      ? { n: t.pr.n, state: clip(t.pr.state, 20), checks: clip(t.pr.checks, 20), review: clip(t.pr.review, 40) }
      : null
    var failure = t.failure && typeof t.failure === "object"
      ? { cls: clip(t.failure["class"], 40), message: clip(t.failure.message, 200), resetAt: time(t.failure.resetAt) }
      : null
    var recovery = t.recovery && typeof t.recovery === "object"
      ? { autoResume: t.recovery.autoResume === true, snooze: t.recovery.snooze === true }
      : null
    threads.push({
      id: t.id,
      failure: failure,
      recovery: recovery,
      title: clip(t.title, 120),
      project: clip(t.project, 60),
      projectColor: /^[a-z]{3,16}$/.test(t.projectColor) ? t.projectColor : "",
      issue: /^#?[A-Za-z0-9_.-]{1,24}$/.test(t.issue) ? t.issue : "",
      state: t.state,
      askKind: clip(t.askKind, 40),
      permDetail: clip(t.permDetail, 160),
      question: clip(t.question, 300),
      step: step,
      pr: pr,
      since: time(t.since),
      ended: time(t.ended)
    })
  }
  return { env: data.env, threads: threads }
}

function asking(t) { return ASKING.indexOf(t.state) !== -1 }
function stopped(t) { return t.state === "failed" || t.state === "limited" }
function finished(t) { return t.state === "done" || stopped(t) }
function live(t) { return t.state === "working" || t.state === "starting" }

// Mobile's order: needs you, failed (and limited), working, then done and stale.
function rank(t) {
  return asking(t) ? 0 : stopped(t) ? 1 : live(t) ? 2 : 3
}

// Where a limited thread stands, given what the plugin planned for it
// (plan: { resume, snooze } or undefined):
//   "reset"  the limit has reset: it can resume now
//   "armed"  the plugin resumes it at the reset
//   "wait"   nothing planned yet
//   "t3" / "t3reset" T3 itself resumes it at the reset (its own auto-resume
//                    is armed), before / after the reset: the plugin never sends
function limitPhase(t, now, plan) {
  var reset = t.failure ? t.failure.resetAt : 0
  var due = !reset || now >= reset
  if (t.recovery && t.recovery.autoResume) return due ? "t3reset" : "t3"
  if (due) return "reset"
  if (plan && plan.resume) return "armed"
  return "wait"
}

// A limited thread snoozed until its reset, by T3 or by the plugin, stays
// out of the bar until then.
function snoozed(t, now, plan) {
  if (t.state !== "limited" || !t.failure || !(now < t.failure.resetAt)) return false
  return !!((plan && plan.snooze) || (t.recovery && t.recovery.snooze))
}

// sources: { host: { env, threads } } -> one list in mobile's order; within
// a group, the longest waiting question first, otherwise the newest.
function merge(sources) {
  var all = []
  Object.keys(sources).forEach(function(host) {
    var s = sources[host]
    if (!s) return
    s.threads.forEach(function(t) {
      all.push(Object.assign({}, t, { env: s.env, host: host }))
    })
  })
  all.sort(function(a, b) {
    return (rank(a) - rank(b)) || (rank(a) === 0 ? a.since - b.since : (b.ended || b.since) - (a.ended || a.since))
  })
  return all
}

function count(threads, state) {
  return threads.filter(function(t) { return t.state === state }).length
}

// A host whose feed dropped: what was in flight is now out of date.
function markStale(threads) {
  return threads.filter(function(t) { return !finished(t) })
    .map(function(t) { return Object.assign({}, t, { state: "stale" }) })
}

// counts: { live, input, perm, stale, failed, limited }. One thread, or only
// working ones, gets mobile's one-word chip as [i18n key, argument, phase]; a
// mix gets null, and the bar shows each count.
function chip(c) {
  var failed = c.failed || 0, limited = c.limited || 0
  var total = c.live + c.input + c.perm + c.stale + failed + limited
  if (total === 1) {
    if (c.live) return ["working", "", "working"]
    if (c.input) return ["answer", "", "input"]
    if (c.perm) return ["approve", "", "perm"]
    if (failed) return ["failed", "", "failed"]
    if (limited) return ["limit", "", "limited"]
    return ["waiting", "", "stale"]
  }
  if (total > 1 && total === c.live) return ["liveCount", c.live > 9 ? "9+" : String(c.live), "working"]
  return null
}

// The island's face as segments: a T3 mark, then one word (one thread, only
// working ones, or a finish) or colored counts for a mix. `phase` picks the
// color; "" is plain. numbersOnly (a vertical bar) never uses words.
//   1 working -> T3 Working · 3 live -> T3 3 live · mix -> T3 3·1·1 · done -> T3 Done
function face(c, flash, numbersOnly) {
  if (flash) return numbersOnly
    ? [{ kind: "mark", phase: flash }, { kind: "glyph", phase: flash }]
    : [{ kind: "mark", phase: flash }, { kind: "word", key: flash, arg: "", phase: flash }]
  var w = numbersOnly ? null : chip(c)
  if (w) return [{ kind: "mark", phase: w[2] }, { kind: "word", key: w[0], arg: w[1], phase: w[2] === "working" ? "" : w[2] }]
  var out = [{ kind: "mark", phase: c.live || c.input || c.perm ? "working" : "" }]
  var n = { live: c.live, input: c.input, perm: c.perm, stopped: (c.failed || 0) + (c.limited || 0), stale: c.stale }
  ;[["live", "working"], ["input", "input"], ["perm", "perm"], ["stopped", "failed"], ["stale", "stale"]].forEach(function(p) {
    if (!(n[p[0]] > 0)) return
    if (out.length > 1 && !numbersOnly) out.push({ kind: "sep", phase: "" })
    out.push({ kind: "num", arg: String(n[p[0]]), phase: p[1] })
  })
  return out
}

// A row's glyph, by phase.
function glyph(phase) {
  return { working: "󱥸", starting: "󰝦", input: "󰋗", perm: "󰀨", done: "󰗠", failed: "󰅙", limited: "󰔟", stale: "󰅐" }[phase] || "●"
}

// The list's headline, mobile's summary: [i18n key, count]. threads are the
// awake ones; snoozedCount the rest, so a list of only snoozed limits says so.
function summary(threads, snoozedCount) {
  var attention = threads.filter(asking).length
  var failed = threads.filter(stopped).length
  var working = threads.filter(live).length
  var stale = count(threads, "stale")
  if (attention > 0) return ["summary.needYou", attention]
  if (working + stale > 0 && failed > 0) return ["summary.stopped", failed]
  if (working > 0) return ["summary.working", working]
  if (stale > 0) return ["summary.stale", stale]
  if (failed > 0) return ["summary.finishedStopped", failed]
  if (snoozedCount > 0) return ["summary.snoozed", snoozedCount]
  return ["summary.allFinished", 0]
}

// ---- Colors ----
// A palette is { red, green, yellow, blue, magenta, cyan, muted, fg, bg } as
// "#rrggbb". Surfaces (fg, bg, muted) always come from the Omarchy theme; the
// phase colors are T3's vivid ones (t3Palette) or the theme's, by setting.

// "#rrggbb", or Qt's "#aarrggbb" for a translucent color.
function rgb(hex) {
  var m = /^#?(?:[0-9a-f]{2})?([0-9a-f]{6})$/i.exec(String(hex || ""))
  if (!m) return null
  var n = parseInt(m[1], 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}
function hexOf(c) {
  return "#" + c.map(function(v) { var h = Math.round(Math.max(0, Math.min(255, v))).toString(16); return h.length < 2 ? "0" + h : h }).join("")
}
function luminance(hex) {
  var c = rgb(hex)
  if (!c) return 0
  var l = c.map(function(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) })
  return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
}
function contrast(a, b) {
  var x = luminance(a), y = luminance(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}
// A color too close to its background is mixed toward the theme's text color
// until it reads: 3:1 by default (bold UI text, glyphs), 4.5:1 for small text.
function readable(hex, bg, fg, target) {
  if (!rgb(hex) || !rgb(bg) || !rgb(fg)) return hex
  var a = rgb(hex), f = rgb(fg), need = target || 3
  for (var i = 0; i <= 10; i++) {
    var c = hexOf(a.map(function(v, k) { return v + (f[k] - v) * i / 10 }))
    if (contrast(c, bg) >= need) return c
  }
  return fg
}

// Toast text shows as typed: Omarchy's notifications decode entities more
// than once before rendering their few allowed tags, so escaping alone can't
// keep "<b>" literal. Angle brackets become look-alikes instead.
// Entities are broken too, so "&lt;b&gt;" can't decode into a tag.
function toastText(text) {
  return String(text || "").replace(/&(?=#?[A-Za-z0-9]+;)/g, "&\u2060").replace(/</g, "\u2039").replace(/>/g, "\u203a")
}
// Black or white, whichever reads better on a filled button.
function inkOn(fill) {
  return contrast(fill, "#000000") >= contrast(fill, "#ffffff") ? "#000000" : "#ffffff"
}

// Which palette color each phase takes.
var PHASE_SLOT = { starting: "blue", working: "blue", input: "magenta", perm: "yellow",
  failed: "red", limited: "red", done: "green", stale: "muted" }
function phaseColor(phase, pal) {
  return pal[PHASE_SLOT[phase]] || pal.fg
}

// T3's own vivid phase colors as a palette (Tailwind 300 stops on a dark
// surface, 600 on a light one): sky, indigo, amber, red, emerald, cyan.
function t3Palette(light) {
  return light
    ? { red: "#dc2626", green: "#059669", yellow: "#d97706", blue: "#0284c7", magenta: "#4f46e5", cyan: "#0891b2" }
    : { red: "#fca5a5", green: "#6ee7b7", yellow: "#fcd34d", blue: "#7dd3fc", magenta: "#a5b4fc", cyan: "#67e8f9" }
}

// T3's project icon colors (Tailwind names) folded onto the theme's palette.
function projectColor(name, pal) {
  var slot = {
    red: "red", rose: "red", pink: "red", orange: "yellow", amber: "yellow", yellow: "yellow",
    lime: "green", green: "green", emerald: "green", teal: "cyan", cyan: "cyan", sky: "blue",
    blue: "blue", indigo: "magenta", violet: "magenta", purple: "magenta", fuchsia: "magenta"
  }[name]
  return slot ? pal[slot] : pal.muted
}

// A pull request's glyph and color: merged, closed, failing, or open.
function prLook(pr, pal) {
  if (!pr) return null
  // Octicons: git-merge, git-pull-request-closed, git-pull-request.
  if (pr.state === "merged") return ["\uf419", pal.magenta]
  if (pr.state === "closed") return ["\uf4dc", pal.red]
  if (pr.checks === "failure" || pr.review === "CHANGES_REQUESTED") return ["\uf407", pal.red]
  if (pr.checks === "pending") return ["\uf407", pal.yellow]
  return ["\uf407", pal.green]
}


// A stopped thread the user dismissed stays out of sight until it stops
// again (a new run ends at a new time).
function dismissed(t, plan) {
  return !!(plan && plan.dismissed && stopped(t) && plan.dismissed === t.ended)
}

// The buttons a row shows, as [i18n key, action, phase]; only what that state
// needs. Questions and approvals open the thread in T3 (they need its
// context); stopped threads resume, wait for their limit, snooze or dismiss
// right in the list. ctx: { phase: limitPhase(), snoozed, ownSnooze, resuming }.
//   question -> Answer · approval -> Approve · failed -> Resume, Dismiss
//   limit: not planned -> On reset, Snooze · planned -> Cancel, Snooze
//          T3 resumes it -> Snooze · reset -> Resume, Dismiss
//   snoozed by you -> Wake · snoozed by T3, resuming, anything else -> none
function actions(t, ctx) {
  if (t.state === "input") return [["answer", "open", "input"]]
  if (t.state === "perm") return [["approve", "open", "perm"]]
  if (!stopped(t) || ctx.resuming) return []
  if (t.state === "failed") return [["resume", "resume", "working"], ["dismiss", "dismiss", ""]]
  if (ctx.snoozed) return ctx.ownSnooze ? [["wake", "unsnooze", ""]] : []
  switch (ctx.phase) {
    case "reset": return [["resume", "resume", "working"], ["dismiss", "dismiss", ""]]
    case "armed": return [["cancel", "disarm", ""], ["snooze", "snooze", ""]]
    case "t3": return [["snooze", "snooze", ""]]
    case "t3reset": return []
    default: return [["resumeAt", "arm", "working"], ["snooze", "snooze", ""]]
  }
}

// The island's tooltip: each count by name, [i18n key, n] pairs.
function tooltip(c) {
  var out = []
  if (c.live) out.push(["tip.working", c.live])
  if (c.input) out.push(["tip.input", c.input])
  if (c.perm) out.push(["tip.perm", c.perm])
  var stoppedN = (c.failed || 0) + (c.limited || 0)
  if (stoppedN) out.push(["tip.stopped", stoppedN])
  if (c.stale) out.push(["tip.stale", c.stale])
  return out
}

// What a state change is about, so a change toasts once: a new question gets
// a new `since`, a new finish a new `ended`.
function stateKey(t) {
  return t.state + "@" + (finished(t) ? t.ended : t.since)
}

// prev: { id: stateKey } from the last snapshot of the same host. Returns
// the threads that just started waiting on the user, or just finished.
function transitions(prev, threads) {
  return threads.filter(function(t) {
    return TOASTS.indexOf(t.state) !== -1 && prev[t.id] !== stateKey(t)
  })
}

function keys(threads) {
  var out = {}
  threads.forEach(function(t) { out[t.id] = stateKey(t) })
  return out
}

// A step as an i18n key and its argument: ["step.edit", "README.md"].
function stepText(step) {
  if (!step) return ["", ""]
  var d = step.detail
  switch (step.type) {
    case "command_execution": return d ? ["step.command", d] : ["", ""]
    case "file_change": return d ? ["step.edit", d.split("/").pop()] : ["", ""]
    case "dynamic_tool": return d ? ["step.tool", d.split("__").pop()] : ["", ""]
    case "subagent": return ["step.subagent", d]
    case "web_search": return ["step.search", ""]
    case "reasoning": return ["step.thinking", ""]
    case "assistant_message": return ["step.writing", ""]
    default: return ["", ""]
  }
}

// A pull request as an i18n key: the one thing worth knowing about it now.
function prText(pr) {
  if (!pr) return ""
  if (pr.state === "merged") return "pr.merged"
  if (pr.state === "closed") return "pr.closed"
  if (pr.checks === "failure") return "pr.failing"
  if (pr.review === "CHANGES_REQUESTED") return "pr.changes"
  if (pr.review === "APPROVED") return "pr.approved"
  if (pr.checks === "pending") return "pr.pending"
  if (pr.checks === "success") return "pr.passing"
  return "pr.open"
}

// What a perm thread asks for, as an i18n key and its argument, taken from
// the approval's own item: the command to run, or the file to read or edit.
function permText(t) {
  var d = t.permDetail || ""
  if (d !== "" && t.askKind === "command") return ["perm.commandRun", d]
  if (d !== "" && t.askKind === "file-change") return ["perm.editFile", d.split("/").pop()]
  if (d !== "" && t.askKind === "file-read") return ["perm.readFile", d.split("/").pop()]
  return [{ command: "perm.command", "file-read": "perm.read", "file-change": "perm.edit" }[t.askKind] || "perm.other", ""]
}

// Notification bodies are markup; thread text must show as typed.
function escapeMarkup(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// omarchy-notification-send reads a leading "-" as one of its flags; a
// zero-width space keeps a title like "--exec x" plain text.
function safeArg(text) {
  var s = String(text || "")
  return s.charAt(0) === "-" ? "​" + s : s
}

// 134000 -> "2:14", 3725000 -> "1:02:05".
function elapsed(ms) {
  var s = Math.max(0, Math.floor(ms / 1000))
  var h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = s % 60
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec)
}

function threadUrl(t) {
  return "t3code://threads/" + t.env + "/" + t.id
}
