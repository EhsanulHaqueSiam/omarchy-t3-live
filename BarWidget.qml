import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// A compact island for T3 Code threads, worded like T3's mobile live
// notification: "T3 Working" for one thread, "T3 3 live" for several,
// "T3 3·1·1" (live, questions, approvals in their colors) for a mix, and
// "T3 Done" for a few seconds when one finishes. Clicking it drops down one
// row per thread; a thread waiting on you has a button that opens it.
// The threads come from Service.qml, which every monitor's widget shares.
BarWidget {
  id: root
  moduleName: "siam.t3-live"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("siam.t3-live") : null
  readonly property var threads: service ? service.threads : []
  readonly property string flash: service ? service.flash : ""
  readonly property bool active: service ? service.activeCount > 0 : false
  readonly property var counts: service ? service.counts : { live: 0, input: 0, perm: 0, stale: 0, failed: 0, limited: 0 }
  readonly property var hosts: [""].concat(Model.parseHosts(root.setting("sshHosts", "")))

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

  function openThread(t) {
    if (root.service) root.service.openThread(t)
    root.close()
  }

  // A row's buttons as [label, action, phase]. Anything that needs your
  // judgement (a question, an approval) opens the thread in T3; stopped
  // threads resume, wait for their limit, or snooze right here.
  function rowActions(t) {
    var s = root.service
    if (!s) return []
    if (t.state === "input") return [["answer", "open", "input"]]
    if (t.state === "perm") return [["approve", "open", "perm"]]
    if (s.isResuming(t)) return []
    if (t.state === "failed") return [["resume", "resume", "working"]]
    if (t.state !== "limited") return []
    if (s.isSnoozed(t)) return s.planFor(t) && s.planFor(t).snooze ? [["wake", "unsnooze", ""]] : []
    switch (s.limitPhase(t)) {
      case "reset": return [["resume", "resume", "working"]]
      case "armed": return [["cancel", "disarm", ""], ["snooze", "snooze", ""]]
      case "t3": return [["snooze", "snooze", ""]]
      default: return [["resumeAt", "arm", "working"], ["snooze", "snooze", ""]]
    }
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
    }
  }

  function clock(ms) {
    return new Date(ms).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  // The island is always black, so it always takes T3's light phase colors.
  function islandTint(phase) { return Model.tint(phase, false) || (phase === "stale" ? "#8a8a8a" : "#ffffff") }

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
  implicitWidth: !visible ? 0 : vertical ? barSize : island.width + Style.space(8)
  implicitHeight: !visible ? 0 : vertical ? island.height + Style.space(8) : barSize

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

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
  // shrinks a little, the new one grows in, and the island's width follows.
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
    scale: mouse.pressed ? 0.97 : 1

    Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    Behavior on height { NumberAnimation { duration: Style.duration(220); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
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
    // Out faster than in.
    Behavior on opacity { NumberAnimation { duration: Style.duration(face.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    Behavior on scale { NumberAnimation { duration: Style.duration(face.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

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

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.popupOpen = root.active && !root.popupOpen
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

    Column {
      id: list
      width: parent.width
      spacing: 0

      // "2 need you  5 active", like the live notification's title.
      Row {
        readonly property var head: Model.summary(root.threads)
        readonly property int activeTotal: root.threads.filter(function(t) { return !Model.finished(t) }).length
        x: Style.space(4)
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

        // working / starting: step and elapsed time; input: question, Answer;
        // perm: what it wants, Approve; stale: waiting for an update;
        // done / failed: how long it took (listed for 2 minutes).
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          readonly property string kind: modelData.state
          readonly property var actions: root.rowActions(modelData)
          readonly property bool asking: actions.length > 0
          readonly property bool dimmed: !!root.service && root.service.isSnoozed(modelData)
          readonly property color tint: Model.tint(kind, root.lightPopup) || Commons.Color.popups.text
          readonly property color ink: Commons.Color.popups.text
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
            x: Style.space(8)
            width: parent.width - Style.space(16)
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
            width: (row.asking ? buttons.x : trailing.x) - x - Style.space(10)
            spacing: Style.space(1)

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
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.meta
              color: row.ink
              opacity: 0.55
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Elapsed time while it runs, the outcome once it ends.
          Text {
            id: trailing
            visible: !row.asking
            x: row.width - width - Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: row.kind === "done" ? strings.t("done")
              : row.kind === "failed" ? strings.t("failed")
              : row.kind === "limited" ? strings.t("limit")
              : row.kind === "stale" ? "" : Model.elapsed(root.now - row.modelData.since)
            color: row.kind === "done" || row.kind === "failed" ? row.tint : row.ink
            font.family: root.barFont
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.features: { "tnum": 1 }
          }

          Row {
            id: buttons
            visible: row.asking
            x: row.width - width - Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)

            Repeater {
              model: row.actions
              delegate: Rectangle {
                id: capsule
                required property var modelData
                // A filled capsule acts; a plain one (Snooze, Cancel, Wake) is the quiet way out.
                readonly property bool filled: modelData[2] !== ""
                readonly property color fill: filled ? (Model.tint(modelData[2], root.lightPopup) || row.ink) : "transparent"
                width: capsuleLabel.implicitWidth + Style.space(filled ? 20 : 14)
                height: capsuleLabel.implicitHeight + Style.space(8)
                radius: height / 2
                color: fill
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
