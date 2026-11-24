import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// A compact island for T3 Code threads, worded like T3's mobile live
// notification: "T3 Working" for one thread, "T3 3 live" for several,
// "T3 3·1·1" (live, questions, approvals, stopped in their colors) for a mix,
// and "T3 Done" for a few seconds when one finishes. Clicking it drops down
// one row per thread, with only the buttons that thread's state needs.
// The threads come from Service.qml, which every monitor's widget shares.
BarWidget {
  id: root
  moduleName: "siam.t3-live"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("siam.t3-live") : null
  readonly property var threads: service ? service.threads : []
  readonly property bool active: service ? service.activeCount > 0 : false
  readonly property var counts: service ? service.counts : { live: 0, input: 0, perm: 0, stale: 0, failed: 0, limited: 0 }
  // A finish flashes, unless a question or approval is waiting: that stays up.
  readonly property string flash: service && counts.input + counts.perm === 0 ? service.flash : ""

  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
  readonly property bool lightPopup: luminance(Commons.Color.popups.text) < 0.5
  readonly property string monitorName: {
    var window = root.QsWindow.window
    var monitor = window && window.screen ? Hyprland.monitorFor(window.screen) : null
    return monitor ? monitor.name : ""
  }

  property bool popupOpen: false
  property real now: Date.now()
  function close() { popupOpen = false }
  // The list opens whenever it has rows, a finished thread's included.
  function toggle() { popupOpen = root.threads.length > 0 && !popupOpen }

  function openThread(t) {
    if (root.service) root.service.openThread(t)
    root.close()
  }

  function act(t, action) {
    var s = root.service
    if (!s) return
    switch (action) {
      case "open": root.openThread(t); return
      case "resume": s.resumeNow(t); return
      case "arm": s.armResume(t); return
      case "disarm": s.disarmResume(t); return
      case "snooze": s.snooze(t); return
      case "unsnooze": s.unsnooze(t); return
      case "dismiss": s.dismiss(t); return
    }
  }

  function clock(ms) {
    return new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  // The island is always black, so it always takes T3's light phase colors.
  function islandTint(phase) { return Model.tint(phase, false) || (phase === "stale" ? "#8a8a8a" : "#ffffff") }

  onThreadsChanged: if (threads.length === 0) close()

  // The widget owns the settings; the shared service follows them. Plain
  // values, never restored: a widget leaving (a monitor unplugged) must not
  // put back defaults the other monitors' widgets still set.
  Binding { target: root.service; when: !!root.service; property: "hostsText"; value: String(root.setting("sshHosts", "")); restoreMode: Binding.RestoreNone }
  Binding { target: root.service; when: !!root.service; property: "notify"; value: root.setting("notify", true) === true; restoreMode: Binding.RestoreNone }

  Connections {
    target: root.service
    function onToggleRequested() {
      var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      if (focused === "" || focused === root.monitorName) root.toggle()
    }
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- Showing and hiding ----
  // The island fades and the space it takes eases open or shut, so the icons
  // beside it slide instead of jumping. It stays while its list is open.
  readonly property bool shown: active || flash !== "" || popupOpen
  readonly property real islandSpan: root.vertical ? island.height + Style.space(8) : island.width + Style.space(8)
  property real span: shown ? islandSpan : 0
  Behavior on span { NumberAnimation { duration: Style.duration(root.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

  visible: shown || span > 0.5
  implicitWidth: vertical ? barSize : span
  implicitHeight: vertical ? span : barSize

  // Ticks only while the list is open, for the elapsed times.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.popupOpen
    onTriggered: root.now = Date.now()
  }

  // ---- Bar: the island ----
  // Two faces trade places when the content changes: the old one fades and
  // shrinks a little first, then the new one grows in, while the island's
  // width eases to fit. Never both at once.
  readonly property var faceNow: Model.face(root.counts, root.flash, root.vertical)
  readonly property string faceKey: JSON.stringify(faceNow)
  property var faceA: []
  property var faceB: []
  property bool showA: true
  onFaceKeyChanged: {
    if (showA) { faceB = faceNow; showA = false }
    else { faceA = faceNow; showA = true }
  }
  Component.onCompleted: faceA = faceNow

  Rectangle {
    id: island
    readonly property Item front: root.showA ? faceAItem : faceBItem
    anchors.centerIn: parent
    width: root.vertical ? root.barSize - Style.space(8) : front.implicitWidth + Style.space(18)
    height: root.vertical ? front.implicitHeight + Style.space(12) : Math.min(root.barSize - Style.space(8), Style.space(20))
    radius: Math.min(width, height) / 2
    color: "#000000"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, mouse.containsMouse || root.popupOpen ? 0.28 : 0.14)
    clip: true
    opacity: root.shown ? 1 : 0
    scale: mouse.pressed ? 0.97 : 1

    Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    Behavior on height { NumberAnimation { duration: Style.duration(220); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    Behavior on opacity { NumberAnimation { duration: Style.duration(root.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    Behavior on scale { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }
    Behavior on border.color { ColorAnimation { duration: Style.duration(160) } }

    Face { id: faceAItem; segments: root.faceA; shown: root.showA }
    Face { id: faceBItem; segments: root.faceB; shown: !root.showA }
  }

  component Face: Grid {
    id: face
    property var segments: []
    property bool shown: false
    anchors.centerIn: parent
    columns: root.vertical ? 1 : Math.max(1, segments.length)
    columnSpacing: Style.space(5)
    rowSpacing: Style.space(1)
    horizontalItemAlignment: Grid.AlignHCenter
    verticalItemAlignment: Grid.AlignVCenter
    opacity: shown ? 1 : 0
    scale: shown ? 1 : 0.94
    // Out first (120 ms), then in (180 ms), so two labels never overlap.
    Behavior on opacity {
      SequentialAnimation {
        PauseAnimation { duration: face.shown ? Style.duration(120) : 0 }
        NumberAnimation { duration: Style.duration(face.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }
    }
    Behavior on scale {
      SequentialAnimation {
        PauseAnimation { duration: face.shown ? Style.duration(120) : 0 }
        NumberAnimation { duration: Style.duration(face.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }
    }

    Repeater {
      model: face.segments
      delegate: Item {
        id: seg
        required property var modelData
        readonly property bool dot: modelData.kind === "sep"
        implicitWidth: dot ? Style.space(3) : label.implicitWidth
        implicitHeight: dot ? Style.space(3) : label.implicitHeight

        Rectangle {
          visible: seg.dot
          anchors.centerIn: parent
          width: Style.space(3)
          height: width
          radius: width / 2
          color: "#5a5a5a"
        }
        Text {
          id: label
          visible: !seg.dot
          textFormat: Text.PlainText
          text: {
            var m = seg.modelData
            if (m.kind === "mark") return "T3"
            if (m.kind === "glyph") return Model.glyph(m.phase)
            if (m.kind === "word") return m.arg !== "" ? strings.t(m.key).arg(m.arg) : strings.t(m.key)
            return m.arg || ""
          }
          color: root.islandTint(seg.modelData.phase)
          font.family: root.barFont
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          font.letterSpacing: seg.modelData.kind === "mark" ? -0.3 : 0
          font.features: { "tnum": 1 }
        }
      }
    }
  }

  // "3 working · 1 question · 1 approval": the colors, named.
  readonly property string tipText: Model.tooltip(root.counts).map(function(p) { return strings.tn(p[0], p[1]).arg(p[1]) }).join("  ·  ")

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (root.bar) root.bar.hideTooltip(root)
      root.toggle()
    }
    onEntered: if (root.bar && !root.popupOpen && root.tipText !== "") root.bar.showTooltip(root, root.tipText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ---- Dropdown: mobile's summary, then one row per thread ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(336))
    contentHeight: popup.fittedContentHeight(list.implicitHeight)

    // Rows come in once per opening, a few at a time; they reset unseen
    // after the card has faded out.
    readonly property bool revealed: root.popupOpen || popup.visible

    // A long list scrolls inside the card instead of running off the screen.
    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: list.implicitHeight
      clip: true
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds

    Column {
      id: list
      width: parent.width
      spacing: 0

      // "2 need you  5 active", like the live notification's title, on the
      // rows' icon line.
      Row {
        // Snoozed threads are out of the way on purpose: the headline skips them.
        readonly property var awake: root.service ? root.service.awakeThreads : []
        readonly property var head: Model.summary(awake)
        readonly property int activeTotal: awake.filter(function(t) { return !Model.finished(t) }).length
        x: Style.space(6)
        spacing: Style.space(8)
        bottomPadding: Style.space(6)

        Text {
          id: headline
          textFormat: Text.PlainText
          text: strings.tn(parent.head[0], parent.head[1]).arg(parent.head[1])
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          visible: parent.activeTotal > 0 && parent.head[0] !== "summary.working"
          anchors.baseline: headline.baseline
          textFormat: Text.PlainText
          text: strings.tn("summary.active", parent.activeTotal).arg(parent.activeTotal)
          color: Commons.Color.popups.text
          opacity: 0.55
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Repeater {
        model: root.threads

        // Title across the full row; under it one line of what happens now and
        // a line of project · machine · PR, with the state's buttons (see
        // Model.actions) beside those two lines, or the elapsed time / outcome.
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          readonly property string kind: modelData.state
          readonly property var buttonsFor: root.service ? root.service.rowActions(modelData) : []
          readonly property bool hasButtons: buttonsFor.length > 0
          readonly property bool dimmed: !!root.service && root.service.isSnoozed(modelData)
          readonly property color tint: Model.tint(kind, root.lightPopup) || Commons.Color.popups.text
          readonly property color ink: Commons.Color.popups.text
          readonly property real inset: Style.space(8)
          readonly property string detail: {
            switch (kind) {
              case "input": return modelData.question !== "" ? modelData.question : strings.t("heading.input")
              case "perm":
                var p = Model.permText(modelData)
                return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
              case "stale": return strings.t("heading.stale")
              case "done": return strings.t("finishedIn").arg(Model.elapsed(modelData.ended - modelData.since))
            }
            if (kind === "failed" || kind === "limited") {
              if (root.service && root.service.isResuming(modelData)) return strings.t("resuming")
              var reset = modelData.failure ? modelData.failure.resetAt : 0
              if (kind === "limited" && root.service) {
                if (root.service.isSnoozed(modelData)) return strings.t("snoozedUntil").arg(root.clock(reset))
                switch (root.service.limitPhase(modelData)) {
                  case "reset": return strings.t("limitReset")
                  case "t3":
                  case "armed": return strings.t("resumesAt").arg(root.clock(reset))
                  default: return strings.t("resetsAt").arg(root.clock(reset))
                }
              }
              return (modelData.failure && modelData.failure.message) || strings.t("failedAfter").arg(Model.elapsed(modelData.ended - modelData.since))
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
          height: content.implicitHeight + Style.space(14)

          opacity: popup.revealed ? (dimmed ? 0.5 : 1) : 0
          transform: Translate {
            y: popup.revealed ? 0 : -Style.space(4)
            Behavior on y {
              SequentialAnimation {
                PauseAnimation { duration: popup.revealed ? Style.duration(Math.min(row.index * 30, 120)) : 0 }
                NumberAnimation { duration: popup.revealed ? Style.duration(200) : 0; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
              }
            }
          }
          Behavior on opacity {
            SequentialAnimation {
              PauseAnimation { duration: popup.revealed ? Style.duration(Math.min(row.index * 30, 120)) : 0 }
              NumberAnimation { duration: popup.revealed ? Style.duration(200) : 0; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
            }
          }

          Rectangle {
            anchors.fill: parent
            radius: Style.space(10)
            color: row.ink
            opacity: hover.containsMouse ? 0.06 : 0
            Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }
          }
          Rectangle {
            visible: row.index > 0
            anchors.top: parent.top
            x: row.inset
            width: parent.width - row.inset * 2
            height: 1
            color: row.ink
            opacity: 0.07
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openThread(row.modelData)
          }

          Text {
            id: mark
            x: Style.space(6)
            y: content.y
            width: Style.space(14)
            height: title.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: Model.glyph(row.kind)
            color: row.tint
            opacity: row.kind === "stale" ? 0.6 : 1
            font.family: root.barFont
            font.pixelSize: Style.font.body
          }

          Column {
            id: content
            x: mark.x + mark.width + Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
            width: row.width - x - row.inset
            spacing: Style.space(1)

            Text {
              id: title
              width: parent.width - (trailing.visible ? trailing.width + Style.space(10) : 0)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.modelData.title
              color: row.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              id: detailLine
              visible: row.detail !== ""
              width: parent.width - (row.hasButtons ? buttons.width + Style.space(10) : 0)
              wrapMode: row.kind === "input" || row.kind === "perm" ? Text.Wrap : Text.NoWrap
              maximumLineCount: row.kind === "input" || row.kind === "perm" ? 2 : 1
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.detail
              color: row.kind === "failed" || row.kind === "limited" ? row.tint : row.ink
              opacity: row.kind === "failed" || row.kind === "limited" ? 1 : 0.82
              font.family: root.barFont
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              id: metaLine
              width: detailLine.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.meta
              color: row.ink
              opacity: 0.55
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Elapsed time while it runs, the outcome once it ends; on the title line.
          Text {
            id: trailing
            visible: !row.hasButtons && row.kind !== "stale"
            x: row.width - width - row.inset
            y: content.y
            height: title.height
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: row.kind === "done" ? strings.t("done")
              : row.kind === "failed" ? strings.t("failed")
              : row.kind === "limited" ? strings.t("limit")
              : Model.elapsed(root.now - row.modelData.since)
            color: row.kind === "done" || row.kind === "failed" || row.kind === "limited" ? row.tint : row.ink
            font.family: root.barFont
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.features: { "tnum": 1 }
          }

          // The state's buttons, beside the detail and meta lines so the title
          // keeps the full row. A filled capsule acts; a plain one is the way out.
          Row {
            id: buttons
            visible: row.hasButtons
            x: row.width - width - row.inset
            y: content.y + title.height + Style.space(1) + Math.max(0, (content.height - title.height - Style.space(1) - height) / 2)
            spacing: Style.space(5)

            Repeater {
              model: row.buttonsFor
              delegate: Rectangle {
                id: capsule
                required property var modelData
                readonly property bool filled: modelData[2] !== ""
                width: capsuleLabel.implicitWidth + Style.space(filled ? 20 : 14)
                height: capsuleLabel.implicitHeight + Style.space(8)
                radius: height / 2
                color: filled ? (Model.tint(modelData[2], root.lightPopup) || row.ink) : "transparent"
                border.width: filled ? 0 : 1
                border.color: Qt.rgba(row.ink.r, row.ink.g, row.ink.b, 0.25)
                opacity: capsuleMouse.containsMouse ? 0.85 : 1
                scale: capsuleMouse.pressed ? 0.96 : 1
                Behavior on scale { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }

                Text {
                  id: capsuleLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: strings.t(capsule.modelData[0])
                  color: capsule.filled ? (root.lightPopup ? "#ffffff" : "#000000") : row.ink
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: capsule.filled
                }

                MouseArea {
                  id: capsuleMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.act(row.modelData, capsule.modelData[1])
                }
              }
            }
          }
        }
      }
    }
    }
  }
}
