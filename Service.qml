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
  // Set by the bar widget from its settings. A string, so an unchanged
  // setting never rebuilds the feeds.
  property string hostsText: ""
  property bool notify: true
  // "t3": T3's own vivid phase colors (the default); "theme": the Omarchy
  // theme's palette. Surfaces, text and borders follow the theme either way.
  property string colors: "t3"
  // Linked T3 environments this machine can ssh into, found by discover.sh
  // (on by default; the widget's "Linked machines" setting).
  property bool linked: true
  // True after discovery's first complete answer; until then it retries every minute.
  property bool discovered: false
  property string linkedText: ""
  readonly property var hosts: {
    var out = [""]
    Model.parseHosts(hostsText).concat(linked ? Model.parseHosts(linkedText) : []).forEach(function(h) {
      if (out.indexOf(h) === -1) out.push(h)
    })
    return out
  }

  // host ("" for this machine) -> { env, threads } from that machine's feed.
  property var sources: ({})
  readonly property var allThreads: Model.merge(sources)

  // What the user planned for stopped threads, by planKey (environment and
  // thread, so it holds whichever host reaches the machine): { host, resetAt,
  // resume, snooze } for a limit, { host, dismissed: ended } for a dismissed
  // row. Kept in a file so a planned resume survives a shell restart.
  property var plan: ({})
  // planKey -> when a resume was sent: the row says "Resuming" until the
  // thread's machine reports it running again, or for 60 s at most.
  property var resuming: ({})
  // Moves only while a limited thread is listed, so limits reset on time.
  property real now: Date.now()

  // Dismissed threads are gone from the list; snoozed ones stay out of the
  // bar and sit at the end of the list.
  readonly property var threads: {
    var awake = [], asleep = []
    root.allThreads.forEach(function(t) {
      var p = root.plan[planKey(t)]
      if (Model.dismissed(t, p)) return
      ;(Model.snoozed(t, root.now, p) ? asleep : awake).push(t)
    })
    return awake.concat(asleep)
  }
  readonly property var awakeThreads: threads.filter(function(t) { return !Model.snoozed(t, root.now, root.plan[planKey(t)]) })
  readonly property int snoozedCount: threads.length - awakeThreads.length

  // ---- Theme ----
  // The current Omarchy theme's palette, read from its colors.toml like
  // Omarchy's own apps do, and read again whenever the shell reloads the
  // theme. Anything a theme leaves out falls back to the shell's own roles.
  property var themeColors: ({})
  readonly property var palette: {
    var c = root.themeColors, k = Commons.Color
    var pick = function(names, fallback) {
      for (var i = 0; i < names.length; i++) if (c[names[i]]) return c[names[i]]
      return String(fallback)
    }
    var base = { muted: String(k.muted), fg: String(k.foreground), bg: String(k.background) }
    if (root.colors !== "theme")
      return Object.assign(Model.t3Palette(Model.luminance(base.bg) > 0.4), base)
    return Object.assign({
      red: pick(["red", "color1"], k.urgent), green: pick(["green", "color2"], "#6ee7b7"),
      yellow: pick(["yellow", "color3"], k.warning), blue: pick(["blue", "color4"], k.accent),
      magenta: pick(["magenta", "color5"], "#a5b4fc"), cyan: pick(["cyan", "color6"], "#7dd3fc")
    }, base)
  }

  function loadTheme(text) {
    var out = {}
    String(text || "").split("\n").forEach(function(line) {
      var m = line.match(/^\s*([a-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) out[m[1]] = m[2].toLowerCase()
    })
    root.themeColors = out
  }

  FileView {
    id: themeFile
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadTheme(text())
    onFileChanged: reload()
  }
  // A theme switch replaces the theme folder; the shell's own colors change
  // when it does, so follow them.
  Connections {
    target: Commons.Color
    function onBackgroundChanged() { themeFile.reload() }
    function onAccentChanged() { themeFile.reload() }
  }
  readonly property int liveCount: Model.count(awakeThreads, "working") + Model.count(awakeThreads, "starting")
  readonly property int inputCount: Model.count(awakeThreads, "input")
  readonly property int permCount: Model.count(awakeThreads, "perm")
  readonly property int staleCount: Model.count(awakeThreads, "stale")
  readonly property int waitingCount: Model.count(awakeThreads, "waiting")
  readonly property int failedCount: Model.count(awakeThreads, "failed")
  readonly property int limitedCount: Model.count(awakeThreads, "limited")
  readonly property int activeCount: liveCount + inputCount + permCount + waitingCount + staleCount + failedCount + limitedCount
  readonly property var counts: ({ live: liveCount, input: inputCount, perm: permCount, waiting: waitingCount, stale: staleCount, failed: failedCount, limited: limitedCount })

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
  // host -> its latest snapshot, while another host shows the same machine.
  property var shadow: ({})

  // Asks the widget on the focused monitor to open or close its list.
  signal toggleRequested()

  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  function planKey(t) { return t.env + "|" + t.id }
  function planFor(t) { return root.plan[planKey(t)] }
  function limitPhase(t) { return Model.limitPhase(t, root.now, planFor(t)) }
  function isSnoozed(t) { return Model.snoozed(t, root.now, planFor(t)) }
  // Sent and waiting for its machine, or still queued behind another send.
  function isResuming(t) {
    var key = planKey(t)
    return !!root.resuming[key] || root.jobs.some(function(j) { return j.key === key })
  }
  function rowActions(t) {
    var p = planFor(t)
    return Model.actions(t, { phase: limitPhase(t), snoozed: isSnoozed(t), ownSnooze: !!(p && p.snooze), resuming: isResuming(t) })
  }

  function receive(host, parsed) {
    // One machine reached under two names (a manual host and a discovered
    // alias) is shown once: the first host to report an environment keeps it.
    // The other host's latest snapshot is kept, so it takes over the moment
    // the first one drops (its feed only prints again on a change).
    var owner = Model.owner(root.sources, root.staleSince, host, parsed.env)
    if (owner && owner.live) { root.shadow[host] = parsed; return }
    // A stale route's rows give way to this live one.
    if (owner) clear(owner.host)
    delete root.shadow[host]
    delete root.staleSince[host]
    var first = !(host in root.seen)
    var events = first ? [] : Model.transitions(root.seen[host], parsed.threads)
    if (!first && root.sources[host]) events = events.concat(Model.finishedWaits(root.sources[host].threads, parsed.threads, Date.now()))
    root.seen[host] = Model.keys(parsed.threads)
    setSource(host, parsed)
    tidy(parsed.env, host, parsed.threads)
    events.forEach(function(t) { announce(Object.assign({}, t, { env: parsed.env, host: host }), false) })
  }

  // Plans and "Resuming" marks end once the thread is no longer stopped, a
  // newer limit replaced the one they were for, or it stopped again since a
  // dismissal.
  function tidy(env, host, list) {
    var byId = {}
    list.forEach(function(t) { byId[t.id] = t })
    var plan = Object.assign({}, root.plan), resuming = Object.assign({}, root.resuming), changed = false
    Object.keys(plan).forEach(function(key) {
      var parts = key.split("|"), t = byId[parts[1]], e = plan[key]
      if (parts[0] !== env) {
        // Saved before plans followed the machine, under its host name: move it.
        if (parts[0] !== host) return
        delete plan[key]
        changed = true
        key = env + "|" + parts[1]
        if (plan[key]) return
        plan[key] = e
      }
      // A thread missing from a full snapshot may only be past the row cap.
      if (!t) { if (list.length < 50) { delete plan[key]; changed = true } return }
      // A plan belongs to one stop: the same reset and the same end time.
      var limitHolds = !(e.resume || e.snooze) || (t.state === "limited" && t.failure && t.failure.resetAt === e.resetAt && (!e.ended || t.ended === e.ended))
      var dismissalHolds = !e.dismissed || t.ended === e.dismissed
      if (!Model.stopped(t) || !limitHolds || !dismissalHolds) { delete plan[key]; changed = true }
    })
    Object.keys(resuming).forEach(function(key) {
      var parts = key.split("|"), t = byId[parts[1]]
      if (parts[0] === env && (!t || !Model.finished(t))) delete resuming[key]
    })
    root.resuming = resuming
    if (changed) setPlan(plan)
  }

  // The host is gone from settings: forget it, and let another host that
  // reaches the same machine show it.
  function drop(host) {
    var s = root.sources[host]
    clear(host)
    var alt = s ? standIn(s.env) : undefined
    if (alt !== undefined) {
      var p = root.shadow[alt]
      delete root.shadow[alt]
      receive(alt, p)
    }
  }
  function clear(host) {
    delete root.seen[host]
    delete root.staleSince[host]
    delete root.shadow[host]
    setSource(host, null)
  }
  // A host whose live feed reports this environment but isn't shown.
  function standIn(env) {
    return Object.keys(root.shadow).filter(function(h) { return root.shadow[h].env === env })[0]
  }

  // The host's feed ended (machine asleep, network down): keep what it was
  // doing on screen as stale, like mobile's "Waiting for an update".
  function lose(host) {
    delete root.shadow[host]
    var s = root.sources[host]
    // Another host still reaches that machine: it takes over, nothing goes stale.
    if (s && standIn(s.env) !== undefined) return drop(host)
    delete root.seen[host]
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
    // One send per stop: a second click, or a toast and the row, must not
    // queue a second turn (T3's CLI queues a message on a busy thread), and
    // a limit T3 resumes itself is left to T3.
    // Also once per stop across the queue and the send in flight.
    var queued = root.jobs.concat(root.job ? [root.job] : []).some(function(j) { return j.key === key && j.ended === t.ended })
    if (queued || root.resuming[key] || !Model.stopped(t) || (t.recovery && t.recovery.autoResume)) return
    root.jobs = root.jobs.concat([{ key: key, title: t.title, env: t.env, id: t.id, ended: t.ended }])
    pump()
  }

  function setPlanned(t, field, value) {
    if (field !== "dismissed" && (t.state !== "limited" || !t.failure)) return
    if (field === "dismissed" && !Model.stopped(t)) return
    var key = planKey(t), plan = Object.assign({}, root.plan)
    var entry = Object.assign({ resetAt: t.failure ? t.failure.resetAt : 0, ended: t.ended, resume: false, snooze: false, dismissed: 0 }, plan[key])
    entry[field] = value
    if (!entry.resume && !entry.snooze && !entry.dismissed) delete plan[key]
    else plan[key] = entry
    setPlan(plan)
  }
  function dismiss(t) { setPlanned(t, "dismissed", t.ended || 1) }
  function armResume(t) { setPlanned(t, "resume", true) }
  function disarmResume(t) { setPlanned(t, "resume", false) }
  function snooze(t) { setPlanned(t, "snooze", true) }
  function unsnooze(t) { setPlanned(t, "snooze", false) }

  // Plans past any use end on their own (Model.planExpired), checked hourly
  // and on load; a feed that still shows the thread tidies them sooner.
  function pruneExpired() {
    var plan = Object.assign({}, root.plan), changed = false, now = Date.now()
    Object.keys(plan).forEach(function(key) {
      if (Model.planExpired(plan[key], now)) { delete plan[key]; changed = true }
    })
    if (changed) setPlan(plan)
  }
  Timer { interval: 3600000; repeat: true; running: true; onTriggered: root.pruneExpired() }
  onHostsChanged: syncHosts()

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
      // Environment|thread, or host|thread from before plans followed the
      // machine (tidy moves those on the host's first snapshot).
      if (!/^[A-Za-z0-9_.@-]*\|[0-9a-fA-F-]{8,64}$/.test(key) || !v || typeof v !== "object") return
      plan[key] = { resetAt: typeof v.resetAt === "number" ? v.resetAt : 0, ended: typeof v.ended === "number" ? v.ended : 0,
        resume: v.resume === true, snooze: v.snooze === true,
        dismissed: typeof v.dismissed === "number" ? v.dismissed : 0 }
    })
    root.plan = plan
    // Check the loaded plan against what the feeds already reported.
    // Not a stale machine's: its stopped threads are hidden, not gone.
    Object.keys(root.sources).forEach(function(h) { if (root.sources[h] && !(h in root.staleSince)) root.tidy(root.sources[h].env, h, root.sources[h].threads) })
    pruneExpired()
  }

  // A resume whose time has come, and the clock that makes limits reset.
  function tick() {
    root.now = Date.now()
    root.allThreads.forEach(function(t) {
      var p = planFor(t)
      // T3's own auto-resume, armed since, owns the reset: never send twice.
      if (t.recovery && t.recovery.autoResume) return
      // The plan must be for this very stop, even if it loaded after the snapshot.
      var forThisStop = p && t.failure && p.resetAt === t.failure.resetAt && (!p.ended || p.ended === t.ended)
      if (forThisStop && p.resume && t.state === "limited" && Model.limitPhase(t, root.now, p) === "reset") resumeNow(t)
    })
  }

  // One resume at a time; each reports a failure as a toast.
  property var jobs: []
  property var job: null
  // Each send is checked against the latest snapshot first: the thread must
  // still be stopped at the same stop, and not since armed by T3 itself.
  function pump() {
    while (!resumer.running && root.jobs.length > 0) {
      var job = root.jobs[0]
      root.jobs = root.jobs.slice(1)
      var t = root.allThreads.filter(function(x) { return planKey(x) === job.key })[0]
      if (!t || !Model.stopped(t) || t.ended !== job.ended || (t.recovery && t.recovery.autoResume) || Model.dismissed(t, root.plan[job.key])) {
        var resuming = Object.assign({}, root.resuming)
        delete resuming[job.key]
        root.resuming = resuming
        continue
      }
      root.job = job
      // The 60 s "Resuming" window starts when the send goes out, and a plan
      // for this stop is used up only now.
      var marks = Object.assign({}, root.resuming)
      marks[job.key] = Date.now()
      root.resuming = marks
      if (root.plan[job.key]) { var plan = Object.assign({}, root.plan); delete plan[job.key]; setPlan(plan) }
      // Through whichever host shows the machine now; 60 s at most, so one
      // hung send can't hold up every later resume.
      resumer.command = t.host === ""
        ? ["bash", "-lc", 'exec "$@"', "bash", "timeout", "60", "t3", "thread", "send", t.id, root.resumeMessage]
        : ["timeout", "60", "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", t.host,
           'PATH="$HOME/.local/bin:$HOME/.t3/bin:$PATH" t3 thread send ' + t.id + ' "' + root.resumeMessage + '"']
      resumer.running = true
    }
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
        if (root.notify)
          Util.execArgv(["omarchy-notification-send", "--app-name", "T3 Live", "-u", "normal", "-g", "󰀨",
            Model.safeArg(Model.toastText(strings.t("toast.resumeFailed").arg(job.title))), "--action", strings.t("open"), "sh", root.openPath, job.env, job.id])
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
    // Toast buttons name the exact stop they were for, so an old toast can't
    // act on a later failure of the same thread.
    var ipc = function(label, method) { return ["--action", strings.t(label), "omarchy-shell", "siam.t3-live", method, t.env, t.id, String(t.ended)] }
    var toast
    switch (t.state) {
      case "input": toast = ["normal", "󱜸", still ? "toast.still" : "toast.input", t.question || strings.t("heading.input"), open.slice(0, 1).concat([strings.t("answer")], open.slice(2))]; break
      case "perm": toast = ["normal", "󰻌", still ? "toast.still" : "toast.perm", permLine(t), open.slice(0, 1).concat([strings.t("approve")], open.slice(2))]; break
      case "done": toast = ["low", "󰗠", "toast.done", strings.t("finishedIn").arg(took), open]; break
      case "failed":
        // Open goes first: clicking a toast's body runs its first action, and
        // that must never send anything.
        toast = ["normal", "󰅙", "toast.failed", (t.failure && t.failure.message) || strings.t("failedAfter").arg(took), open.concat(ipc("resume", "resume"))]
        break
      case "limited":
        var phase = Model.limitPhase(t, Date.now(), undefined)
        var reset = t.failure ? t.failure.resetAt : 0
        toast = ["normal", "󰔟", "toast.limited",
          phase === "t3" || phase === "t3reset" ? strings.t("resumesAt").arg(clock(reset)) : phase === "reset" ? strings.t("limitReset") : strings.t("resetsAt").arg(clock(reset)),
          phase === "wait" ? open.concat(ipc("resumeAtReset", "resumeAtReset"), ipc("snooze", "snooze"))
            : phase === "reset" ? open.concat(ipc("resume", "resume")) : open]
        break
      default: return
    }
    Util.execArgv(["omarchy-notification-send", "--app-name", "T3 Live",
      "-u", still ? "critical" : toast[0], "-g", toast[1],
      Model.safeArg(Model.toastText(strings.t(toast[2]).arg(t.title))), Model.safeArg(Model.toastText(toast[3]))].concat(toast[4]))
  }

  function permLine(t) {
    var p = Model.permText(t)
    return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Timer { id: flashTimer; interval: 4000; onTriggered: root.flash = "" }

  // A resume that started nothing within 60 s gets its buttons back.
  Timer {
    interval: 10000
    repeat: true
    running: Object.keys(root.resuming).length > 0
    onTriggered: {
      var now = Date.now(), resuming = Object.assign({}, root.resuming), changed = false
      Object.keys(resuming).forEach(function(k) { if (now - resuming[k] > 60000) { delete resuming[k]; changed = true } })
      if (changed) root.resuming = resuming
    }
  }

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
        // Gone for good; another route to the same machine takes over.
        root.drop(host)
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
  // resume / resumeAtReset / snooze take an environment id, a thread id and the
  // stop's end time; toast buttons call them, and only that stop is acted on.
  ShellIpc {
    target: "siam.t3-live"
    function toggle(): void { root.toggleRequested() }
    function status(): string {
      return JSON.stringify({ live: root.liveCount, input: root.inputCount, perm: root.permCount, waiting: root.waitingCount, stale: root.staleCount,
        failed: root.failedCount, limited: root.limitedCount, plan: root.plan, threads: root.threads })
    }
    function resume(env: string, id: string, stop: string): void { root.withThread(env, id, stop, root.resumeNow) }
    function resumeAtReset(env: string, id: string, stop: string): void { root.withThread(env, id, stop, root.armResume) }
    function snooze(env: string, id: string, stop: string): void { root.withThread(env, id, stop, root.snooze) }
  }

  // Acts only on the very stop the caller saw (its end time).
  function withThread(env, id, stop, action) {
    var t = root.allThreads.filter(function(x) { return x.env === env && x.id === id })[0]
    if (t && Model.stopped(t) && String(t.ended) === stop) action(t)
  }

  // Linked environments, found at start and every 10 minutes.
  Process {
    id: discover
    command: ["sh", root.localPath("discover.sh")]
    stdout: StdioCollector {
      // Only a complete answer (ending in "ok") replaces what was known.
      onStreamFinished: {
        var lines = text.split("\n").filter(function(l) { return l !== "" })
        if (lines[lines.length - 1] !== "ok") return
        root.linkedText = Model.parseHosts(lines.slice(0, -1).join(",")).join(",")
        root.discovered = true
      }
    }
  }
  // Every 10 minutes; every minute until the first answer (T3 starts late at login).
  Timer {
    interval: root.discovered ? 600000 : 60000
    repeat: true
    running: root.linked
    triggeredOnStart: true
    onTriggered: if (!discover.running) discover.running = true
  }

  // Synced in place, so a machine coming or going never restarts the others' feeds.
  ListModel { id: hostModel }
  function syncHosts() {
    for (var i = hostModel.count - 1; i >= 0; i--)
      if (root.hosts.indexOf(hostModel.get(i).name) === -1) hostModel.remove(i)
    root.hosts.forEach(function(h) {
      for (var j = 0; j < hostModel.count; j++) if (hostModel.get(j).name === h) return
      hostModel.append({ name: h })
    })
  }
  Component.onCompleted: syncHosts()
  Instantiator {
    model: hostModel
    delegate: Feed {
      required property string name
      host: name
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
