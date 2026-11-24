.pragma library

// Pure helpers for Service.qml and BarWidget.qml; tests/model.test.mjs runs
// them under node.

var UUID = /^[0-9a-fA-F-]{8,64}$/
var HOST = /^[A-Za-z0-9_.@][A-Za-z0-9_.@-]*$/
var STATES = ["working", "input", "perm", "done", "failed"]
var ASKING = ["input", "perm"]

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
    threads.push({
      id: t.id,
      title: clip(t.title, 120),
      project: clip(t.project, 60),
      state: t.state,
      askKind: clip(t.askKind, 40),
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
function finished(t) { return t.state === "done" || t.state === "failed" }

// sources: { host: { env, threads } } -> one list: waiting on you first
// (oldest first), then working (newest first), then just finished.
function merge(sources) {
  var all = []
  Object.keys(sources).forEach(function(host) {
    var s = sources[host]
    if (!s) return
    s.threads.forEach(function(t) {
      all.push(Object.assign({}, t, { env: s.env, host: host }))
    })
  })
  var rank = function(t) { return asking(t) ? 0 : finished(t) ? 2 : 1 }
  all.sort(function(a, b) {
    return (rank(a) - rank(b)) || (rank(a) === 0 ? a.since - b.since : (b.ended || b.since) - (a.ended || a.since))
  })
  return all
}

function count(threads, state) {
  return threads.filter(function(t) { return t.state === state }).length
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
    return t.state !== "working" && prev[t.id] !== stateKey(t)
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

// What a perm thread asks for, as an i18n key and its argument: the command
// it wants to run when that is its latest step.
function permText(t) {
  if (t.askKind === "command")
    return t.step && t.step.type === "command_execution" && t.step.detail ? ["perm.commandRun", t.step.detail] : ["perm.command", ""]
  return [{ "file-read": "perm.read", "file-change": "perm.edit" }[t.askKind] || "perm.other", ""]
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
