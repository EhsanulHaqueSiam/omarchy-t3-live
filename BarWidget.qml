import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for T3 Code threads, "T3  3 live │ 1 input │ 1 perm", and a short
// "T3  Done" when one finishes. Clicking it drops down one live-update pill
// per thread; a thread waiting on you has a button that opens it in T3.
// The threads come from Service.qml, which every monitor's widget shares.
BarWidget {
  id: root
  moduleName: "siam.t3-live"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("siam.t3-live") : null
  readonly property var threads: service ? service.threads : []
  readonly property int workingCount: service ? service.workingCount : 0
  readonly property int inputCount: service ? service.inputCount : 0
  readonly property int permCount: service ? service.permCount : 0
  readonly property string flash: service ? service.flash : ""
  readonly property bool active: service ? service.activeCount > 0 : false
  readonly property var hosts: [""].concat(Model.parseHosts(root.setting("sshHosts", "")))

  readonly property color fg: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
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
      readonly property bool counts: root.flash === ""
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 6
      columnSpacing: Style.space(6)
      rowSpacing: Style.space(2)
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      BarText { text: "T3"; font.bold: true }
      // A finish shows on its own for a few seconds, then the counts return.
      BarText {
        visible: !chip.counts
        text: root.vertical ? (root.flash === "done" ? "󰗠" : "󰀨") : strings.t(root.flash)
        color: root.flash === "failed" ? root.urgentColor : root.fg
        font.bold: true
      }
      BarText {
        visible: chip.counts && root.workingCount > 0
        text: root.vertical ? String(root.workingCount) : strings.t("live").arg(root.workingCount)
      }
      BarText {
        visible: chip.counts && root.inputCount > 0
        text: root.vertical ? String(root.inputCount) : root.divider(root.workingCount) + strings.t("input").arg(root.inputCount)
        color: root.urgentColor
        font.bold: true
      }
      BarText {
        visible: chip.counts && root.permCount > 0
        text: root.vertical ? String(root.permCount) : root.divider(root.workingCount + root.inputCount) + strings.t("perm").arg(root.permCount)
        // The theme's warning can be too dim on the bar; its rows use it.
        font.bold: true
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

  // ---- Dropdown: one live-update pill per thread ----
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

      Repeater {
        model: root.threads

        // working: title, current step, project · machine · PR, elapsed time
        // input:   title, its question, Answer
        // perm:    title, what it wants to do, Review
        // done / failed: title, how long it took; listed for 2 minutes
        delegate: Rectangle {
          id: row
          required property var modelData
          readonly property string kind: modelData.state
          readonly property bool asking: kind === "input" || kind === "perm"
          readonly property bool finished: kind === "done" || kind === "failed"
          readonly property color ink: finished ? Commons.Color.popups.text : Commons.Color.background
          readonly property string stepLine: {
            var s = Model.stepText(modelData.step)
            return s[0] === "" ? "" : s[1] !== "" ? strings.t(s[0]).arg(s[1]) : strings.t(s[0])
          }
          readonly property string detail: {
            if (kind === "input") return modelData.question !== "" ? modelData.question : strings.t("needsYou")
            if (kind === "perm") {
              var p = Model.permText(modelData)
              return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
            }
            if (finished) return strings.t(kind === "done" ? "finishedIn" : "failedAfter").arg(Model.elapsed(modelData.ended - modelData.since))
            return stepLine
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
          color: kind === "input" ? Commons.Color.urgent
            : kind === "perm" ? Commons.Color.warning
            : finished ? Qt.rgba(Commons.Color.popups.text.r, Commons.Color.popups.text.g, Commons.Color.popups.text.b, 0.08)
            : Commons.Color.accent
          border.width: kind === "failed" ? 1 : 0
          border.color: Commons.Color.urgent
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
            text: row.kind === "done" ? "󰗠" : row.kind === "failed" ? "󰀨" : "●"
            color: row.kind === "failed" ? Commons.Color.urgent : row.ink
            font.family: root.barFont
            font.pixelSize: row.finished ? Style.font.body : Style.font.caption
          }

          Column {
            id: content
            x: mark.x + mark.width + Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: (row.asking ? button.x : row.finished ? row.width - Style.space(14) : trailing.x) - x - Style.space(10)
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
              color: row.kind === "failed" ? Commons.Color.urgent : row.ink
              font.family: !row.finished && row.modelData.step && row.modelData.step.type === "command_execution"
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
            visible: !row.asking && !row.finished
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
              text: strings.t(row.kind === "perm" ? "review" : "answer")
              color: row.color
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
