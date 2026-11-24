import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// One instance for the whole shell: runs feed.sh on this machine and over ssh
// on every host, and holds the merged live threads every bar's widget shows.
// Each feed prints a line only when its threads change, so nothing here polls.
Item {
  id: root

  property var shell: null
  // Set by the bar widget from its "Other machines" setting.
  property var hosts: [""]

  // host ("" for this machine) -> { env, threads } from that machine's feed.
  property var sources: ({})
  readonly property var threads: Model.merge(sources)
  readonly property int waitingCount: threads.filter(function(t) { return t.input }).length
  readonly property int workingCount: threads.length - waitingCount
  readonly property string feedPath: decodeURIComponent(String(Qt.resolvedUrl("feed.sh")).replace(/^file:\/\//, ""))

  // Asks the widget on the focused monitor to open or close its list.
  signal toggleRequested()

  function setSource(host, value) {
    var next = Object.assign({}, root.sources)
    if (value) next[host] = value
    else delete next[host]
    root.sources = next
  }

  // The T3 Code desktop app opens t3code:// links; without it the thread
  // opens in this machine's T3 web UI instead.
  function openThread(t) {
    opener.command = ["sh", "-c",
      "xdg-open \"$1\" 2>/dev/null || xdg-open \"$(jq -r .origin \"${T3CODE_HOME:-$HOME/.t3}/userdata/server-runtime.json\")/$2/$3\"",
      "sh", Model.threadUrl(t), t.env, t.id]
    opener.running = true
  }

  // `omarchy-shell siam.t3-live toggle` opens the list, e.g. from a keybinding.
  ShellIpc {
    target: "siam.t3-live"
    function toggle(): void { root.toggleRequested() }
    function status(): string {
      return JSON.stringify({ working: root.workingCount, waiting: root.waitingCount, threads: root.threads })
    }
  }

  Process { id: opener }

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

    Component.onDestruction: root.setSource(feed.host, null)

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
          if (parsed) root.setSource(feed.host, parsed)
        }
      }
      // An unreachable machine drops out of the counts until it answers again.
      onExited: {
        root.setSource(feed.host, null)
        retry.start()
      }
    }

    Timer { id: retry; interval: 30000; onTriggered: proc.running = true }
  }
}
