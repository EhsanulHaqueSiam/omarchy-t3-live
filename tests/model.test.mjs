// node tests/model.test.mjs — checks Model.js, which BarWidget.qml imports.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(".pragma library", "")
const M = vm.runInThisContext(`(() => { ${src}\nreturn { parseHosts, parseLine, merge, elapsed, threadUrl } })()`)

const env = "7262cf01-c98b-4af8-af5f-e943001b545d"
const id = "cd44952b-1db2-4a50-acfd-dde0414d497e"

// Hosts: commas, spaces, and nothing ssh could take as an option.
assert.deepEqual(M.parseHosts(" mac, box2 ,,-oProxyCommand=x, a b"), ["mac", "box2"])

// Feed lines from another machine are untrusted: bad ids and junk are dropped, text clipped.
const line = JSON.stringify({ env, threads: [
  { id, title: "x".repeat(500), project: "p", input: 1, question: "q".repeat(900), since: "2026-11-23T19:35:48.235Z" },
  { id: "$(rm -rf ~)", title: "evil" },
  { id, title: "<img src=https://example.invalid/t>", project: "q", input: 0, since: "nope" },
] })
const parsed = M.parseLine(line)
assert.equal(parsed.threads.length, 2)
assert.equal(parsed.threads[0].title.length, 120)
assert.equal(parsed.threads[0].input, true)
assert.equal(parsed.threads[0].question.length, 300)
assert.equal(parsed.threads[1].question, "")
assert.equal(parsed.threads[1].since, 0)
assert.equal(M.parseLine("not json"), null)
assert.equal(M.parseLine(""), null)
assert.equal(M.parseLine(JSON.stringify({ env: "../x", threads: [] })), null)

// Merge: waiting-on-you first, then newest, each tagged with its host.
const a = { env, threads: [{ id: "a0000000", input: false, since: 1 }] }
const b = { env, threads: [{ id: "b0000000", input: false, since: 5 }, { id: "c0000000", input: true, question: "Ship it?", since: 0 }] }
assert.deepEqual(M.merge({ "": a, mac: b }).map(t => t.id + "@" + t.host), ["c0000000@mac", "b0000000@mac", "a0000000@"])

assert.equal(M.merge({ mac: b })[0].question, "Ship it?")
assert.equal(M.elapsed(134000), "2:14")
assert.equal(M.elapsed(3725000), "1:02:05")
assert.equal(M.elapsed(-5), "0:00")
assert.equal(M.threadUrl({ env, id }), `t3code://threads/${env}/${id}`)

console.log("model tests passed")
