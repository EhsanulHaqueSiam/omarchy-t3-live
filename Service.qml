import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// One instance for the whole shell: runs feed.sh on this machine and over ssh
// on every host, holds the merged threads every bar's widget shows, and sends
// a toast when a thread starts waiting on the user or finishes.
// Each feed prints a line only when its threads change, so nothing here polls.
Item {
  id: root

  property var shell: null
  // Set by the bar widget from its settings.
  property var hosts: [""]
  property bool notify: true

  // host ("" for this machine) -> { env, threads } from that machine's feed.
  property var sources: ({})
  readonly property var threads: Model.merge(sources)
  readonly property int workingCount: Model.count(threads, "working")
  readonly property int inputCount: Model.count(threads, "input")
  readonly property int permCount: Model.count(threads, "perm")
  readonly property int activeCount: workingCount + inputCount + permCount

  // "done" or "failed" for a few seconds after a thread finishes, for the bar.
  property string flash: ""

  readonly property string feedPath: localPath("feed.sh")
  readonly property string openPath: localPath("open.sh")
  readonly property int escalateAfterMs: 5 * 60 * 1000
  readonly property real startedAt: Date.now()

  // host -> { threadId: stateKey } from its last snapshot; a host's first
  // snapshot (startup, reconnect) only fills this, so it never toasts.
  property var seen: ({})
  // stateKeys already escalated, so each question escalates once.
  property var escalated: ({})

  // Asks the widget on the focused monitor to open or close its list.
  signal toggleRequested()

  function localPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
  }

  function receive(host, parsed) {
    var first = !(host in root.seen)
    var events = first ? [] : Model.transitions(root.seen[host], parsed.threads)
    root.seen[host] = Model.keys(parsed.threads)
    setSource(host, parsed)
    events.forEach(function(t) { announce(Object.assign({}, t, { env: parsed.env, host: host }), false) })
  }

  function drop(host) {
    delete root.seen[host]
    setSource(host, null)
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

  function announce(t, still) {
    if (t.state === "done" || t.state === "failed") {
      root.flash = t.state
      flashTimer.restart()
    }
    if (!root.notify) return
    var took = Model.elapsed((t.ended || Date.now()) - t.since)
    var toast = {
      input: ["normal", "󱜸", still ? "toast.still" : "toast.input", t.question || strings.t("needsYou"), "answer"],
      perm: ["normal", "󰻌", still ? "toast.still" : "toast.perm", permLine(t), "review"],
      done: ["low", "󰗠", "toast.done", strings.t("finishedIn").arg(took), "open"],
      failed: ["normal", "󰀨", "toast.failed", strings.t("failedAfter").arg(took), "open"]
    }[t.state]
    if (!toast) return
    Util.execArgv(["omarchy-notification-send", "--app-name", "T3 Live",
      "-u", still ? "critical" : toast[0], "-g", toast[1],
      Model.safeArg(strings.t(toast[2]).arg(t.title)), Model.safeArg(Model.escapeMarkup(toast[3])),
      "--action", strings.t(toast[4]), "sh", root.openPath, t.env, t.id])
  }

  function permLine(t) {
    var p = Model.permText(t)
    return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Timer { id: flashTimer; interval: 4000; onTriggered: root.flash = "" }

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
  ShellIpc {
    target: "siam.t3-live"
    function toggle(): void { root.toggleRequested() }
    function status(): string {
      return JSON.stringify({ working: root.workingCount, input: root.inputCount, perm: root.permCount, threads: root.threads })
    }
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
      // An unreachable machine drops out of the counts until it answers again.
      onExited: {
        root.drop(feed.host)
        retry.start()
      }
    }

    Timer { id: retry; interval: 30000; onTriggered: proc.running = true }
  }
}
