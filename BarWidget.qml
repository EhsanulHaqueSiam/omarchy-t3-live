import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for T3 Code threads, worded like T3's own mobile live
// notification: "T3  Working" for one thread, "T3  3 live" for several,
// "T3  3 live │ 1 input │ 1 perm" for a mix, and "T3  Done" for a few
// seconds when one finishes. Clicking it drops down one pill per thread in
// T3's phase colors; a thread waiting on you has a button that opens it.
// The threads come from Service.qml, which every monitor's widget shares.
BarWidget {
  id: root
  moduleName: "siam.t3-live"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("siam.t3-live") : null
  readonly property var threads: service ? service.threads : []
  readonly property int liveCount: service ? service.liveCount : 0
  readonly property int inputCount: service ? service.inputCount : 0
  readonly property int permCount: service ? service.permCount : 0
  readonly property int staleCount: service ? service.staleCount : 0
  readonly property var chipWord: service ? service.chip : null
  readonly property string flash: service ? service.flash : ""
  readonly property bool active: service ? service.activeCount > 0 : false
  readonly property var hosts: [""].concat(Model.parseHosts(root.setting("sshHosts", "")))

  readonly property color fg: bar ? bar.barForeground : Commons.Color.foreground
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
  // Dark text means a light surface, which takes T3's darker phase colors.
  readonly property bool lightBar: luminance(fg) < 0.5
  readonly property bool lightPopup: luminance(Commons.Color.popups.text) < 0.5
  readonly property string monitorName: {
    var window = root.QsWindow.window
    var monitor = window && window.screen ? Hyprland.monitorFor(window.screen) : null
    return monitor ? monitor.name : ""
  }

  property bool popupOpen: false
  property real now: Date.now()
  function close() { popupOpen = false }

  function openThread(t) {
    if (root.service) root.service.openThread(t)
    root.close()
  }

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  function barTint(phase) { return Model.tint(phase, root.lightBar) || root.fg }
  function divider(before) { return before > 0 ? "│  " : "" }

  onActiveChanged: if (!active) close()

  // The widget owns the settings; the shared service follows them.
  Binding { target: root.service; when: !!root.service; property: "hosts"; value: root.hosts }
  Binding { target: root.service; when: !!root.service; property: "notify"; value: root.setting("notify", true) }

  Connections {
    target: root.service
    function onToggleRequested() {
      var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      if (focused === "" || focused === root.monitorName)
        root.popupOpen = root.active && !root.popupOpen
    }
  }

  visible: active || flash !== ""
  implicitWidth: !visible ? 0 : vertical ? barSize : pill.width + Style.space(8)
  implicitHeight: !visible ? 0 : vertical ? pill.height + Style.space(8) : barSize

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Ticks only while the list is open, for the elapsed times.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.popupOpen
    onTriggered: root.now = Date.now()
  }

  // ---- Bar ----
  Rectangle {
    id: pill
    anchors.centerIn: parent
    width: root.vertical ? root.barSize - Style.space(6) : chip.implicitWidth + Style.space(16)
    height: root.vertical ? chip.implicitHeight + Style.space(10)
      : Math.min(root.barSize - Style.space(6), chip.implicitHeight + Style.space(6))
    radius: Math.min(width, height) / 2
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, mouse.containsMouse || root.popupOpen ? 0.18 : 0.10)

    Grid {
      id: chip
      // flash: "Done" / "Failed"; word: one thread, or only working ones;
      // otherwise each count. A vertical bar always stacks the counts.
      readonly property string mode: root.flash !== "" ? "flash" : root.chipWord && !root.vertical ? "word" : "counts"
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 7
      columnSpacing: Style.space(6)
      rowSpacing: Style.space(2)
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      BarText { text: "T3"; font.bold: true }
      BarText {
        visible: chip.mode === "flash"
        text: root.vertical ? (root.flash === "done" ? "󰗠" : "󰀨") : strings.t(root.flash)
        color: root.barTint(root.flash)
        font.bold: true
      }
      BarText {
        visible: chip.mode === "word"
        text: root.chipWord ? strings.t(root.chipWord[0]).arg(root.chipWord[1]) : ""
        color: root.chipWord ? root.barTint(root.chipWord[2]) : root.fg
        font.bold: true
      }
      BarText {
        visible: chip.mode === "counts" && root.liveCount > 0
        text: root.vertical ? String(root.liveCount) : strings.t("live").arg(root.liveCount)
        color: root.barTint("working")
      }
      BarText {
        visible: chip.mode === "counts" && root.inputCount > 0
        text: root.vertical ? String(root.inputCount) : root.divider(root.liveCount) + strings.t("input").arg(root.inputCount)
        color: root.barTint("input")
        font.bold: true
      }
      BarText {
        visible: chip.mode === "counts" && root.permCount > 0
        text: root.vertical ? String(root.permCount) : root.divider(root.liveCount + root.inputCount) + strings.t("perm").arg(root.permCount)
        color: root.barTint("perm")
        font.bold: true
      }
      BarText {
        visible: chip.mode === "counts" && root.staleCount > 0
        text: root.vertical ? String(root.staleCount) : root.divider(root.liveCount + root.inputCount + root.permCount) + strings.t("staleCount").arg(root.staleCount)
        opacity: 0.6
      }
    }
  }

  component BarText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.barFont
    font.pixelSize: Style.font.body
    font.features: { "tnum": 1 }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.popupOpen = root.active && !root.popupOpen
  }

  // ---- Dropdown: mobile's summary, then one live-update pill per thread ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(list.implicitHeight)

    Column {
      id: list
      width: parent.width
      spacing: Style.space(6)

      // "1 needs you  ·  4 active", like the live notification's title.
      Row {
        readonly property var head: Model.summary(root.threads)
        readonly property int activeTotal: root.threads.filter(function(t) { return t.state !== "done" && t.state !== "failed" }).length
        x: Style.space(4)
        spacing: Style.space(8)
        bottomPadding: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: strings.tn(parent.head[0], parent.head[1]).arg(parent.head[1])
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        Text {
          visible: parent.activeTotal > 0 && parent.head[0] !== "summary.working"
          anchors.baseline: parent.children[0].baseline
          textFormat: Text.PlainText
          text: strings.tn("summary.active", parent.activeTotal).arg(parent.activeTotal)
          color: Commons.Color.popups.text
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Repeater {
        model: root.threads

        // starting / working: title, current step, project · machine · PR, elapsed
        // input: title, its question, Answer
        // perm:  title, what it wants to do, Approve
        // stale: title, "Waiting for an update" (its machine stopped answering)
        // done / failed: title, how long it took; listed for 2 minutes
        delegate: Rectangle {
          id: row
          required property var modelData
          readonly property string kind: modelData.state
          readonly property bool asking: kind === "input" || kind === "perm"
          readonly property bool quiet: kind === "done" || kind === "failed" || kind === "stale"
          readonly property color phaseColor: Model.tint(kind, root.lightPopup) || Commons.Color.popups.text
          readonly property color ink: quiet ? Commons.Color.popups.text : root.lightPopup ? "#ffffff" : Commons.Color.background
          readonly property string detail: {
            switch (kind) {
              case "input": return modelData.question !== "" ? modelData.question : strings.t("heading.input")
              case "perm":
                var p = Model.permText(modelData)
                return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
              case "stale": return strings.t("heading.stale")
              case "done": return strings.t("finishedIn").arg(Model.elapsed(modelData.ended - modelData.since))
              case "failed": return strings.t("failedAfter").arg(Model.elapsed(modelData.ended - modelData.since))
            }
            var s = Model.stepText(modelData.step)
            if (s[0] === "") return kind === "starting" ? strings.t("heading.starting") : ""
            return s[1] !== "" ? strings.t(s[0]).arg(s[1]) : strings.t(s[0])
          }
          readonly property string meta: {
            var parts = [modelData.project, modelData.host === "" ? strings.t("thisMachine") : modelData.host]
            var pr = Model.prText(modelData.pr)
            if (pr !== "") parts.push(strings.t(pr).arg(modelData.pr.n))
            return parts.filter(function(p) { return p !== "" }).join("  ·  ")
          }

          width: list.width
          height: content.implicitHeight + Style.space(18)
          radius: Style.space(14)
          color: quiet ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.08) : phaseColor
          border.width: kind === "failed" ? 1 : 0
          border.color: phaseColor
          opacity: hover.containsMouse && !button.hovered ? 0.88 : 1

          // Under the button, so a press on the button stays the button's.
          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openThread(row.modelData)
          }

          Text {
            id: mark
            x: Style.space(12)
            y: content.y
            width: Style.space(12)
            height: title.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: ({ done: "󰗠", failed: "󰀨", stale: "󰅐" })[row.kind] || "●"
            color: row.quiet && row.kind !== "stale" ? row.phaseColor : row.ink
            opacity: row.kind === "stale" ? 0.6 : 1
            font.family: root.barFont
            font.pixelSize: row.quiet ? Style.font.body : Style.font.caption
          }

          Column {
            id: content
            x: mark.x + mark.width + Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: (row.asking ? button.x : row.quiet ? row.width - Style.space(14) : trailing.x) - x - Style.space(10)
            spacing: Style.space(2)

            Text {
              id: title
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.modelData.title
              color: row.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              visible: row.detail !== ""
              width: parent.width
              wrapMode: row.asking ? Text.Wrap : Text.NoWrap
              maximumLineCount: row.asking ? 2 : 1
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.detail
              color: row.kind === "failed" ? row.phaseColor : row.ink
              opacity: row.kind === "stale" ? 0.7 : 1
              font.family: !row.quiet && row.modelData.step && row.modelData.step.type === "command_execution"
                ? root.barFont : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.meta
              color: row.ink
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            id: trailing
            visible: !row.asking && !row.quiet
            x: row.width - width - Style.space(14)
            y: content.y
            textFormat: Text.PlainText
            text: Model.elapsed(root.now - row.modelData.since)
            color: row.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            font.features: { "tnum": 1 }
          }

          Rectangle {
            id: button
            readonly property bool hovered: buttonMouse.containsMouse
            visible: row.asking
            x: row.width - width - Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: buttonLabel.implicitWidth + Style.space(24)
            height: buttonLabel.implicitHeight + Style.space(12)
            radius: height / 2
            color: row.ink
            opacity: hovered ? 0.85 : 1

            Text {
              id: buttonLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: strings.t(row.kind === "perm" ? "approve" : "answer")
              color: row.phaseColor
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            MouseArea {
              id: buttonMouse
              anchors.fill: parent
              enabled: row.asking
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openThread(row.modelData)
            }
          }
        }
      }
    }
  }
}
