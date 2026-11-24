import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for live T3 Code threads, "T3  3 live │ 1 input", across this
// machine and every ssh host in settings. Clicking it drops down one
// live-update pill per thread. The threads come from Service.qml, which every
// monitor's widget shares.
BarWidget {
  id: root
  moduleName: "siam.t3-live"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("siam.t3-live") : null
  readonly property var threads: service ? service.threads : []
  readonly property int workingCount: service ? service.workingCount : 0
  readonly property int waitingCount: service ? service.waitingCount : 0
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

  onThreadsChanged: if (threads.length === 0) close()

  // The widget owns the setting; the shared service runs whatever it says.
  Binding {
    target: root.service
    when: !!root.service
    property: "hosts"
    value: root.hosts
  }

  Connections {
    target: root.service
    function onToggleRequested() {
      var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      if (focused === "" || focused === root.monitorName)
        root.popupOpen = root.threads.length > 0 && !root.popupOpen
    }
  }

  visible: threads.length > 0
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

  // ---- Bar: ( T3  3 live │ 1 input ), stacked counts on a vertical bar ----
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
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 4
      columnSpacing: Style.space(6)
      rowSpacing: Style.space(2)
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter

      BarText { text: "T3"; font.bold: true }
      BarText {
        visible: root.workingCount > 0
        text: root.vertical ? String(root.workingCount) : strings.t("live").arg(root.workingCount)
      }
      BarText { visible: !root.vertical && root.workingCount > 0 && root.waitingCount > 0; text: "│"; opacity: 0.35 }
      BarText {
        visible: root.waitingCount > 0
        text: root.vertical ? String(root.waitingCount) : strings.t("input").arg(root.waitingCount)
        color: root.urgentColor
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
    onClicked: root.popupOpen = !root.popupOpen
  }

  // ---- Dropdown: one live-update pill per thread ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(list.implicitHeight)

    Column {
      id: list
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.threads

        // A working thread: title, project · machine, elapsed time.
        // One waiting on you: title, its question, and an Answer button.
        delegate: Rectangle {
          id: row
          required property var modelData
          readonly property color ink: Commons.Color.background
          readonly property bool asking: modelData.input

          width: list.width
          height: content.implicitHeight + Style.space(18)
          radius: Style.space(14)
          color: asking ? Commons.Color.urgent : Commons.Color.accent
          opacity: hover.containsMouse && !answer.hovered ? 0.88 : 1

          // Under the button, so a press on the button stays the button's.
          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openThread(row.modelData)
          }

          Rectangle {
            id: dot
            x: Style.space(14)
            y: content.y + (title.height - height) / 2
            width: Style.space(7)
            height: width
            radius: width / 2
            color: row.ink
          }

          Column {
            id: content
            x: dot.x + dot.width + Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            width: (row.asking ? answer.x : trailing.x) - x - Style.space(10)
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
              visible: row.asking
              width: parent.width
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.modelData.question !== "" ? row.modelData.question : strings.t("needsYou")
              color: row.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.modelData.project + "  ·  " + (row.modelData.host === "" ? strings.t("thisMachine") : row.modelData.host)
              color: row.ink
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            id: trailing
            visible: !row.asking
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
            id: answer
            readonly property bool hovered: answerMouse.containsMouse
            visible: row.asking
            x: row.width - width - Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: answerLabel.implicitWidth + Style.space(24)
            height: answerLabel.implicitHeight + Style.space(12)
            radius: height / 2
            color: row.ink
            opacity: hovered ? 0.85 : 1

            Text {
              id: answerLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: strings.t("answer")
              color: Commons.Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            MouseArea {
              id: answerMouse
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
