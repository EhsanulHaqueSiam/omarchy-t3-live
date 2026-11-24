import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// One instance for the whole shell: runs feed.sh on this machine and over ssh
// on every host, holds the merged threads every bar's widget shows, sends a
// toast when a thread starts waiting on the user, finishes, fails or hits a
// usage limit, and resumes stopped threads (now, or when their limit resets).
// Each feed prints a line only when its threads change, so nothing here polls.
Item {
  id: root

  property var shell: null
  // Set by the bar widget from its settings.
  property var hosts: [""]
  property bool notify: true

  // host ("" for this machine) -> { env, threads } from that machine's feed.
  property var sources: ({})
  readonly property var allThreads: Model.merge(sources)

  // What the user planned for limited threads, by planKey: { resetAt, resume,
  // snooze }. Kept in a file so a planned resume survives a shell restart.
  property var plan: ({})
  // planKeys sent a resume a moment ago: their row says "Resuming" until the
  // thread's machine reports it running again.
  property var resuming: ({})
  // Moves only while a limited thread is listed, so limits reset on time.
  property real now: Date.now()

  // Snoozed threads stay out of the bar and sit at the end of the list.
  readonly property var threads: {
    var awake = [], asleep = []
    root.allThreads.forEach(function(t) {
      (Model.snoozed(t, root.now, root.plan[planKey(t)]) ? asleep : awake).push(t)
    })
    return awake.concat(asleep)
  }
  readonly property var awakeThreads: allThreads.filter(function(t) { return !Model.snoozed(t, root.now, root.plan[planKey(t)]) })
  readonly property int liveCount: Model.count(awakeThreads, "working") + Model.count(awakeThreads, "starting")
  readonly property int inputCount: Model.count(awakeThreads, "input")
  readonly property int permCount: Model.count(awakeThreads, "perm")
  readonly property int staleCount: Model.count(awakeThreads, "stale")
  readonly property int failedCount: Model.count(awakeThreads, "failed")
  readonly property int limitedCount: Model.count(awakeThreads, "limited")
  readonly property int activeCount: liveCount + inputCount + permCount + staleCount + failedCount + limitedCount
  readonly property var counts: ({ live: liveCount, input: inputCount, perm: permCount, stale: staleCount, failed: failedCount, limited: limitedCount })

  // "done", "failed" or "limited" for a few seconds after a thread stops, for the bar.
  property string flash: ""

  readonly property string feedPath: localPath("feed.sh")
  readonly property string openPath: localPath("open.sh")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy-t3-live"
  readonly property int escalateAfterMs: 5 * 60 * 1000
  readonly property real startedAt: Date.now()
  // What T3 itself sends when it resumes a thread after a usage limit.
  readonly property string resumeMessage: "Continue where you left off."

  // host -> { threadId: stateKey } from its last snapshot; a host's first
  // snapshot (startup, reconnect) only fills this, so it never toasts.
  property var seen: ({})
  // stateKeys already escalated, so each question escalates once.
  property var escalated: ({})
  // host -> when its feed dropped; its threads show as stale for 10 minutes.
  property var staleSince: ({})

  // Asks the widget on the focused monitor to open or close its list.
  signal toggleRequested()

  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  function planKey(t) { return t.host + "|" + t.id }
  function planFor(t) { return root.plan[planKey(t)] }
  function limitPhase(t) { return Model.limitPhase(t, root.now, planFor(t)) }
  function isSnoozed(t) { return Model.snoozed(t, root.now, planFor(t)) }
  function isResuming(t) { return !!root.resuming[planKey(t)] }

  function receive(host, parsed) {
    delete root.staleSince[host]
    var first = !(host in root.seen)
    var events = first ? [] : Model.transitions(root.seen[host], parsed.threads)
    root.seen[host] = Model.keys(parsed.threads)
    setSource(host, parsed)
    tidy(host, parsed.threads)
    events.forEach(function(t) { announce(Object.assign({}, t, { env: parsed.env, host: host }), false) })
  }

  // Plans and "Resuming" marks end once the thread is no longer stopped, or
  // a newer limit replaced the one they were for.
  function tidy(host, list) {
    var byId = {}
    list.forEach(function(t) { byId[t.id] = t })
    var plan = Object.assign({}, root.plan), resuming = Object.assign({}, root.resuming), changed = false
    Object.keys(plan).forEach(function(key) {
      var parts = key.split("|"), t = byId[parts[1]]
      if (parts[0] !== host) return
      if (!t || t.state !== "limited" || !t.failure || t.failure.resetAt !== plan[key].resetAt) { delete plan[key]; changed = true }
    })
    Object.keys(resuming).forEach(function(key) {
      var parts = key.split("|"), t = byId[parts[1]]
      if (parts[0] === host && (!t || !Model.finished(t))) delete resuming[key]
    })
    root.resuming = resuming
    if (changed) setPlan(plan)
  }

  // The host is gone from settings: forget it.
  function drop(host) {
    delete root.seen[host]
    delete root.staleSince[host]
    setSource(host, null)
  }

  // The host's feed ended (machine asleep, network down): keep what it was
  // doing on screen as stale, like mobile's "Waiting for an update".
  function lose(host) {
    delete root.seen[host]
    var s = root.sources[host]
    if (!s) return
    // Retries that fail again keep the first drop time, so stale rows still leave.
    if (!(host in root.staleSince)) root.staleSince[host] = Date.now()
    setSource(host, { env: s.env, threads: Model.markStale(s.threads) })
  }

  function setSource(host, value) {
    var next = Object.assign({}, root.sources)
    if (value) next[host] = value
    else delete next[host]
    root.sources = next
  }

  function openThread(t) {
    Util.execArgv(["sh", root.openPath, t.env, t.id])
  }

  // ---- Resuming and snoozing stopped threads ----

  // Sends T3's own resume message through the `t3` CLI on the thread's machine.
  // Ids and hosts were validated when parsed, so they are safe in the ssh line.
  function resumeNow(t) {
    var key = planKey(t)
    var argv = t.host === ""
      ? ["bash", "-lc", 'exec "$@"', "bash", "t3", "thread", "send", t.id, root.resumeMessage]
      : ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", t.host,
         'PATH="$HOME/.local/bin:$HOME/.t3/bin:$PATH" t3 thread send ' + t.id + ' "' + root.resumeMessage + '"']
    var resuming = Object.assign({}, root.resuming)
    resuming[key] = true
    root.resuming = resuming
    var plan = Object.assign({}, root.plan)
    if (plan[key]) { delete plan[key]; setPlan(plan) }
    root.jobs = root.jobs.concat([{ argv: argv, key: key, title: t.title, env: t.env, id: t.id }])
    pump()
  }

  function setPlanned(t, field, value) {
    if (t.state !== "limited" || !t.failure) return
    var key = planKey(t), plan = Object.assign({}, root.plan)
    var entry = Object.assign({ resetAt: t.failure.resetAt, resume: false, snooze: false }, plan[key])
    entry[field] = value
    if (!entry.resume && !entry.snooze) delete plan[key]
    else plan[key] = entry
    setPlan(plan)
  }
  function armResume(t) { setPlanned(t, "resume", true) }
  function disarmResume(t) { setPlanned(t, "resume", false) }
  function snooze(t) { setPlanned(t, "snooze", true) }
  function unsnooze(t) { setPlanned(t, "snooze", false) }

  function setPlan(plan) {
    root.plan = plan
    planFile.setText(JSON.stringify(plan) + "\n")
  }

  // A plan read back from disk is checked like any other input.
  function loadPlan(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    if (!data || typeof data !== "object") return
    var plan = {}
    Object.keys(data).slice(0, 100).forEach(function(key) {
      var v = data[key]
      if (!/^[A-Za-z0-9_.@-]*\|[0-9a-fA-F-]{8,64}$/.test(key) || !v || typeof v.resetAt !== "number") return
      plan[key] = { resetAt: v.resetAt, resume: v.resume === true, snooze: v.snooze === true }
    })
    root.plan = plan
  }

  // A resume whose time has come, and the clock that makes limits reset.
  function tick() {
    root.now = Date.now()
    root.allThreads.forEach(function(t) {
      var p = planFor(t)
      if (p && p.resume && t.state === "limited" && Model.limitPhase(t, root.now, p) === "reset") resumeNow(t)
    })
  }

  // One resume at a time; each reports a failure as a toast.
  property var jobs: []
  property var job: null
  function pump() {
    if (resumer.running || root.jobs.length === 0) return
    root.job = root.jobs[0]
    root.jobs = root.jobs.slice(1)
    resumer.command = root.job.argv
    resumer.running = true
  }

  Process {
    id: resumer
    onExited: function(code) {
      var job = root.job
      root.job = null
      if (job && code !== 0) {
        var resuming = Object.assign({}, root.resuming)
        delete resuming[job.key]
        root.resuming = resuming
        Util.execArgv(["omarchy-notification-send", "--app-name", "T3 Live", "-u", "normal", "-g", "󰀨",
          Model.safeArg(strings.t("toast.resumeFailed").arg(job.title)), "--action", strings.t("open"), "sh", root.openPath, job.env, job.id])
      }
      root.pump()
    }
  }

  Process {
    running: true
    command: ["mkdir", "-p", root.stateDir]
    onExited: planFile.path = root.stateDir + "/plan.json"
  }

  FileView {
    id: planFile
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPlan(text())
  }

  // ---- Toasts ----

  function clock(ms) {
    return new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function announce(t, still) {
    if (t.state === "done" || t.state === "failed" || t.state === "limited") {
      root.flash = t.state
      flashTimer.restart()
    }
    if (!root.notify) return
    var took = Model.elapsed((t.ended || Date.now()) - t.since)
    var open = ["--action", strings.t("open"), "sh", root.openPath, t.env, t.id]
    var ipc = function(label, method) { return ["--action", strings.t(label), "omarchy-shell", "siam.t3-live", method, t.env, t.id] }
    var toast
    switch (t.state) {
      case "input": toast = ["normal", "󱜸", still ? "toast.still" : "toast.input", t.question || strings.t("heading.input"), open.slice(0, 1).concat([strings.t("answer")], open.slice(2))]; break
      case "perm": toast = ["normal", "󰻌", still ? "toast.still" : "toast.perm", permLine(t), open.slice(0, 1).concat([strings.t("approve")], open.slice(2))]; break
      case "done": toast = ["low", "󰗠", "toast.done", strings.t("finishedIn").arg(took), open]; break
      case "failed":
        toast = ["normal", "󰅙", "toast.failed", (t.failure && t.failure.message) || strings.t("failedAfter").arg(took), ipc("resume", "resume").concat(open)]
        break
      case "limited":
        var phase = Model.limitPhase(t, Date.now(), undefined)
        var reset = t.failure ? t.failure.resetAt : 0
        toast = ["normal", "󰔟", "toast.limited",
          phase === "t3" ? strings.t("resumesAt").arg(clock(reset)) : phase === "reset" ? strings.t("limitReset") : strings.t("resetsAt").arg(clock(reset)),
          phase === "wait" ? ipc("resumeAtReset", "resumeAtReset").concat(ipc("snooze", "snooze"))
            : phase === "reset" ? ipc("resume", "resume").concat(open) : open]
        break
      default: return
    }
    Util.execArgv(["omarchy-notification-send", "--app-name", "T3 Live",
      "-u", still ? "critical" : toast[0], "-g", toast[1],
      Model.safeArg(strings.t(toast[2]).arg(t.title)), Model.safeArg(Model.escapeMarkup(toast[3]))].concat(toast[4]))
  }

  function permLine(t) {
    var p = Model.permText(t)
    return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Timer { id: flashTimer; interval: 4000; onTriggered: root.flash = "" }

  // Limits reset on time and planned resumes fire, checked every 30 s while
  // a limited thread is listed.
  Timer {
    interval: 30000
    repeat: true
    triggeredOnStart: true
    running: Model.count(root.allThreads, "limited") > 0
    onTriggered: root.tick()
  }

  // Stale threads from a host that stays away leave after 10 minutes.
  Timer {
    interval: 60000
    repeat: true
    running: root.staleCount > 0
    onTriggered: {
      var now = Date.now()
      Object.keys(root.staleSince).forEach(function(host) {
        if (now - root.staleSince[host] < 10 * 60000) return
        delete root.staleSince[host]
        root.setSource(host, null)
      })
    }
  }

  // One critical toast for a question or permission left waiting too long.
  Timer {
    interval: 30000
    repeat: true
    running: root.inputCount + root.permCount > 0
    onTriggered: {
      var now = Date.now()
      root.threads.forEach(function(t) {
        var key = t.id + ":" + Model.stateKey(t)
        // Already overdue when the shell started: it escalated before a restart.
        var overdueAtStart = root.startedAt - t.since > root.escalateAfterMs
        if (!Model.asking(t) || now - t.since < root.escalateAfterMs || overdueAtStart || root.escalated[key]) return
        root.escalated[key] = true
        root.announce(t, true)
      })
    }
  }

  // `omarchy-shell siam.t3-live toggle` opens the list, e.g. from a keybinding.
  // resume / resumeAtReset / snooze take an environment id and thread id; toast
  // buttons call them.
  ShellIpc {
    target: "siam.t3-live"
    function toggle(): void { root.toggleRequested() }
    function status(): string {
      return JSON.stringify({ live: root.liveCount, input: root.inputCount, perm: root.permCount, stale: root.staleCount,
        failed: root.failedCount, limited: root.limitedCount, plan: root.plan, threads: root.threads })
    }
    function resume(env: string, id: string): void { root.withThread(env, id, root.resumeNow) }
    function resumeAtReset(env: string, id: string): void { root.withThread(env, id, root.armResume) }
    function snooze(env: string, id: string): void { root.withThread(env, id, root.snooze) }
  }

  function withThread(env, id, action) {
    var t = root.allThreads.filter(function(x) { return x.env === env && x.id === id })[0]
    if (t && Model.stopped(t)) action(t)
  }

  Instantiator {
    model: root.hosts
    delegate: Feed {
      required property string modelData
      host: modelData
    }
  }

  component Feed: Item {
    id: feed
    property string host: ""

    Component.onDestruction: root.drop(feed.host)

    Process {
      id: proc
      running: true
      command: feed.host === ""
        ? ["sh", root.feedPath]
        : ["sh", "-c", "exec ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \"$1\" sh -s < \"$2\"",
           "sh", feed.host, root.feedPath]
      stdout: SplitParser {
        onRead: function(line) {
          var parsed = Model.parseLine(line)
          if (parsed) root.receive(feed.host, parsed)
        }
      }
      // An unreachable machine's threads go stale until it answers again.
      onExited: {
        root.lose(feed.host)
        retry.start()
      }
    }

    Timer { id: retry; interval: 30000; onTriggered: proc.running = true }
  }
}
