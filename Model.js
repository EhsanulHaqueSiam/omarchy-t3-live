.pragma library

// Pure helpers for BarWidget.qml; tests/model.test.mjs runs them under node.

var UUID = /^[0-9a-fA-F-]{8,64}$/
var HOST = /^[A-Za-z0-9_.@][A-Za-z0-9_.@-]*$/

// "mac, box2" -> ["mac", "box2"]; drops names ssh could read as options.
function parseHosts(text) {
  return String(text || "").split(",").map(function(h) { return h.trim() })
    .filter(function(h) { return HOST.test(h) })
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
    if (!t || typeof t.id !== "string" || !UUID.test(t.id)) continue
    var since = Date.parse(t.since)
    threads.push({
      id: t.id,
      title: String(t.title || "").slice(0, 120),
      project: String(t.project || "").slice(0, 60),
      input: t.input === 1 || t.input === true,
      question: String(t.question || "").slice(0, 300),
      since: isNaN(since) ? 0 : since
    })
  }
  return { env: data.env, threads: threads }
}

// sources: { label: { env, threads } } -> one list, waiting-on-you first, then newest.
function merge(sources) {
  var all = []
  Object.keys(sources).forEach(function(label) {
    var s = sources[label]
    if (!s) return
    s.threads.forEach(function(t) {
      all.push({ id: t.id, title: t.title, project: t.project, input: t.input, question: t.question, since: t.since, env: s.env, host: label })
    })
  })
  all.sort(function(a, b) { return (b.input - a.input) || (b.since - a.since) })
  return all
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
