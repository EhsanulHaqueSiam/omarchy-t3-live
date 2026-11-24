import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// A compact island for T3 Code threads, worded like T3's mobile live
// notification: "T3 Working" for one thread, "T3 3 live" for several,
// "T3 3·1·1" (live, questions, approvals, stopped, each in its color) for a
// mix, and "T3 Done" for a few seconds when one finishes. Clicking it drops
// down one row per thread, with only the buttons that thread's state needs.
// Surfaces follow the Omarchy theme; phases use T3's vivid colors (or the
// theme's, by the "Colors" setting).
// The threads come from Service.qml, which every monitor's widget shares.
BarWidget {
  id: root
  moduleName: "siam.t3-live"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("siam.t3-live") : null
  readonly property var threads: service ? service.threads : []
  readonly property bool active: service ? service.activeCount > 0 : false
  readonly property var counts: service ? service.counts : { live: 0, input: 0, perm: 0, waiting: 0, stale: 0, failed: 0, limited: 0 }
  // A finish flashes, unless a question or approval is waiting: that stays up.
  readonly property string flash: service && counts.input + counts.perm === 0 ? service.flash : ""
  readonly property var pal: service ? service.palette : { red: "#ff6b6b", green: "#6ee7b7", yellow: "#fcd34d", blue: "#7dd3fc", magenta: "#a5b4fc", cyan: "#7dd3fc", muted: "#808080", fg: "#ffffff", bg: "#000000" }

  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
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

  // A theme color, lifted until it reads on the surface it sits on.
  // Glyphs need 3:1; small text asks for 4.5.
  function onSurface(hex, surface, target) { return Model.readable(hex, String(surface), root.pal.fg, target) }
  function phaseOn(phase, surface, target) { return onSurface(Model.phaseColor(phase, root.pal), surface, target) }

  onThreadsChanged: {
    root.syncRows()
    if (threads.length === 0) close()
  }

  // The widget owns the settings; the shared service follows them. Plain
  // values, never restored: a widget leaving (a monitor unplugged) must not
  // put back defaults the other monitors' widgets still set.
  Binding { target: root.service; when: !!root.service; property: "hostsText"; value: String(root.setting("sshHosts", "")); restoreMode: Binding.RestoreNone }
  Binding { target: root.service; when: !!root.service; property: "notify"; value: root.setting("notify", true) === true; restoreMode: Binding.RestoreNone }
  Binding { target: root.service; when: !!root.service; property: "hostsReady"; value: true; restoreMode: Binding.RestoreNone }
  Binding { target: root.service; when: !!root.service; property: "linked"; value: root.setting("linked", true) === true; restoreMode: Binding.RestoreNone }
  Binding { target: root.service; when: !!root.service; property: "colors"; value: root.setting("colors", "T3") === "Theme" ? "theme" : "t3"; restoreMode: Binding.RestoreNone }

  Connections {
    target: root.service
    function onToggleRequested() {
      var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      if (focused === "" || focused === root.monitorName) root.toggle()
    }
  }

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Ticks only while the list is open, for the elapsed times.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.popupOpen
    onTriggered: root.now = Date.now()
  }

  // ---- The island's size ----
  // One animated length is both the island and the space the bar keeps for
  // it, so they never disagree. It grows at once, so a longer label has room
  // before it appears, and shrinks only once the old label has faded.
  readonly property bool shown: active || flash !== "" || popupOpen
  readonly property Item front: showA ? faceAItem : faceBItem
  readonly property real faceLength: vertical ? front.implicitHeight + Style.space(12) : front.implicitWidth + Style.space(18)
  readonly property real targetSpan: shown ? faceLength + Style.space(8) : 0
  property real span: 0
  onTargetSpanChanged: {
    spanAnim.stop()
    spanAnim.waitMs = targetSpan < span ? Style.duration(110) : 0
    spanAnim.to = targetSpan
    spanAnim.start()
  }
  SequentialAnimation {
    id: spanAnim
    property int waitMs: 0
    property real to: 0
    PauseAnimation { duration: spanAnim.waitMs }
    NumberAnimation { target: root; property: "span"; to: spanAnim.to; duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
  }

  visible: shown || span > 0.5
  implicitWidth: vertical ? barSize : span
  implicitHeight: vertical ? span : barSize

  // ---- The island ----
  // Two faces trade places when the content changes: the old one fades and
  // shrinks a little first, then the new one grows in once the island fits
  // it. Never both at once.
  readonly property var faceNow: Model.face(root.counts, root.flash, root.vertical)
  readonly property string faceKey: JSON.stringify(faceNow)
  property var faceA: []
  property var faceB: []
  property bool showA: true
  onFaceKeyChanged: {
    if (showA) { faceB = faceNow; showA = false }
    else { faceA = faceNow; showA = true }
  }
  Component.onCompleted: { faceA = faceNow; syncRows() }

  Rectangle {
    id: island
    anchors.centerIn: parent
    width: root.vertical ? root.barSize - Style.space(8) : Math.max(0, root.span - Style.space(8))
    height: root.vertical ? Math.max(0, root.span - Style.space(8)) : Math.min(root.barSize - Style.space(8), Style.space(20))
    radius: Math.min(width, height) / 2
    // The theme's background, ringed in its text color: an island in any theme.
    color: root.pal.bg
    border.width: 1
    border.color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, mouse.containsMouse || root.popupOpen ? 0.30 : 0.16)
    clip: true
    opacity: root.shown ? 1 : 0
    scale: mouse.pressed ? 0.97 : 1

    Behavior on opacity { NumberAnimation { duration: Style.duration(root.shown ? 180 : 120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
    Behavior on scale { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }
    Behavior on border.color { ColorAnimation { duration: Style.duration(160) } }
    Behavior on color { ColorAnimation { duration: Style.duration(220) } }

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
    // Out first (110 ms); in (170 ms) once the island has grown to fit.
    Behavior on opacity {
      SequentialAnimation {
        PauseAnimation { duration: face.shown ? Style.duration(150) : 0 }
        NumberAnimation { duration: Style.duration(face.shown ? 170 : 110); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }
    }
    Behavior on scale {
      SequentialAnimation {
        PauseAnimation { duration: face.shown ? Style.duration(150) : 0 }
        NumberAnimation { duration: Style.duration(face.shown ? 170 : 110); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
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
          color: root.pal.muted
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
          color: seg.modelData.phase ? root.phaseOn(seg.modelData.phase, root.pal.bg, seg.modelData.kind === "glyph" ? 3 : 4.5) : root.pal.fg
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

  // ---- The list's rows, kept by thread ----
  // Rows are updated in place, keyed by machine and thread, instead of being
  // rebuilt: a new thread fades in, a gone one fades out, a thread whose
  // state moved it glides to its new place, and a row's colors ease.
  ListModel { id: rows }
  function syncRows() {
    var want = root.threads
    var keys = want.map(function(t) { return t.host + "|" + t.id })
    for (var i = rows.count - 1; i >= 0; i--) if (keys.indexOf(rows.get(i).key) === -1) rows.remove(i)
    for (var j = 0; j < want.length; j++) {
      var json = JSON.stringify(want[j]), found = -1
      for (var k = j; k < rows.count; k++) if (rows.get(k).key === keys[j]) { found = k; break }
      if (found === -1) rows.insert(j, { key: keys[j], json: json })
      else {
        if (found !== j) rows.move(found, j, 1)
        if (rows.get(j).json !== json) rows.setProperty(j, "json", json)
      }
    }
  }

  // ---- Dropdown: mobile's summary, then one row per thread ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(348))
    // A long list scrolls inside a card about eight rows tall.
    contentHeight: popup.fittedContentHeight(list.contentHeight, Style.space(560))

    // Rows come in once per opening, a few at a time; they reset unseen
    // after the card has faded out.
    readonly property bool revealed: root.popupOpen || popup.visible
    readonly property color surface: Commons.Color.popups.background

    // A soft edge over the last visible row says there is more below.
    Rectangle {
      z: 2
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(28)
      visible: list.contentHeight > list.height + 1
      // A few pixels short of the end counts as the end (atYEnd can miss by one).
      opacity: list.contentY - list.originY + list.height >= list.contentHeight - Style.space(6) ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: popup.surface }
      }
    }

    ListView {
      id: list
      anchors.fill: parent
      model: rows
      clip: true
      // In a long list the headline comes back as soon as you scroll up.
      headerPositioning: ListView.PullBackHeader
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds

      // Only while the card is shown: rows that arrive while it is closed must
      // still come in with the opening stagger.
      add: Transition {
        enabled: popup.revealed
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
        NumberAnimation { property: "scale"; from: 0.97; to: 1; duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }
      remove: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: Style.duration(120); easing.type: Easing.OutCubic }
      }
      displaced: Transition {
        enabled: popup.revealed
        NumberAnimation { property: "y"; duration: Style.duration(200); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
        NumberAnimation { property: "opacity"; to: 1; duration: Style.duration(120) }
      }
      move: Transition {
        NumberAnimation { property: "y"; duration: Style.duration(200); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
      }

      // "2 need you  5 active", like the live notification's title, on the
      // rows' icon line. Snoozed threads are out of the way on purpose.
      // Opaque, because it pulls back over the rows mid-scroll.
      header: Rectangle {
        width: list.width
        height: headRow.height
        // Fully opaque even on a translucent theme, or rows show through it.
        color: Qt.rgba(popup.surface.r, popup.surface.g, popup.surface.b, 1)
        z: 2
        Row {
          id: headRow
          readonly property var awake: root.service ? root.service.awakeThreads : []
          readonly property var head: Model.summary(awake, root.service ? root.service.snoozedCount : 0)
          readonly property int activeTotal: awake.filter(function(t) { return Model.live(t) || Model.asking(t) }).length
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
            // Muted, yet 4.5:1 like every small text here.
            color: Model.readable(String(Qt.tint(Commons.Color.popups.text, Qt.rgba(popup.surface.r, popup.surface.g, popup.surface.b, 0.45))), String(popup.surface), root.pal.fg, 4.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Title across the full row; under it one line of what happens now and
      // a line of project · machine · PR · issue, with the state's buttons
      // (see Model.actions) beside those two lines, or the elapsed time.
      delegate: Item {
        id: row
        // Not "data": that name is every Item's list of children.
        required property string json
        required property int index
        readonly property var t: JSON.parse(json)
        readonly property string kind: t.state
        readonly property var buttonsFor: root.service ? root.service.rowActions(t) : []
        readonly property bool hasButtons: buttonsFor.length > 0
        readonly property bool dimmed: !!root.service && root.service.isSnoozed(t)
        readonly property bool resuming: !!root.service && root.service.isResuming(t)
        // A snoozed row is drawn in one muted color that still reads at 4.5:1;
        // fading it with opacity would sink its small text below that.
        readonly property color muted: Model.readable(String(Qt.tint(Commons.Color.popups.text, Qt.rgba(popup.surface.r, popup.surface.g, popup.surface.b, 0.5))), String(popup.surface), root.pal.fg, 4.5)
        readonly property color tint: dimmed ? muted : root.phaseOn(kind, popup.surface)
        readonly property color tintText: dimmed ? muted : root.phaseOn(kind, popup.surface, 4.5)
        readonly property color ink: dimmed ? muted : Commons.Color.popups.text
        readonly property real inset: Style.space(8)
        // A limit whose resume is already planned is handled, not an alarm.
        readonly property bool alert: (kind === "failed" || kind === "limited") && !resuming && !dimmed
          && !(kind === "limited" && root.service && ["t3", "t3reset", "armed"].indexOf(root.service.limitPhase(t)) !== -1)
        readonly property bool wraps: kind === "input" || kind === "perm" || kind === "failed"
        readonly property string detail: {
          switch (kind) {
            case "input": return t.question !== "" ? t.question : strings.t("heading.input")
            case "perm":
              var p = Model.permText(t)
              return p[1] !== "" ? strings.t(p[0]).arg(p[1]) : strings.t(p[0])
            case "stale": return strings.t("heading.stale")
            case "done": return strings.t("finishedIn").arg(Model.elapsed(t.ended - t.since))
          }
          if (kind === "failed" || kind === "limited") {
            if (resuming) return strings.t("resuming")
            var reset = t.failure ? t.failure.resetAt : 0
            if (kind === "limited" && root.service) {
              if (root.service.isSnoozed(t)) return strings.t("snoozedUntil").arg(root.clock(reset))
              switch (root.service.limitPhase(t)) {
                case "reset": return strings.t("limitReset")
                case "t3":
                case "t3reset":
                case "armed": return strings.t("resumesAt").arg(root.clock(reset))
                default: return strings.t("resetsAt").arg(root.clock(reset))
              }
            }
            return (t.failure && t.failure.message) || strings.t("failedAfter").arg(Model.elapsed(t.ended - t.since))
          }
          var s = Model.stepText(t.step)
          if (s[0] === "") return kind === "starting" ? strings.t("heading.starting") : ""
          return s[1] !== "" ? strings.t(s[0]).arg(s[1]) : strings.t(s[0])
        }
        // Project, machine, pull request and issue, each with its own icon and
        // theme color: [glyph, text, color].
        readonly property var metaParts: {
          var parts = []
          // Small text: lifted to 4.5:1 and drawn at full strength.
          var small = function(hex) { return row.dimmed ? String(row.muted) : Model.readable(hex, String(popup.surface), root.pal.fg, 4.5) }
          if (t.project) parts.push(["󰉋", t.project, small(Model.projectColor(t.projectColor, root.pal))])
          parts.push([t.host === "" ? "󰌢" : "󰒋", t.host === "" ? strings.t("thisMachine") : t.host, small(root.pal.cyan)])
          var pr = Model.prLook(t.pr, root.pal)
          if (pr) parts.push([pr[0], "#" + t.pr.n, small(pr[1])])
          // Octicons issue-opened.
          if (t.issue) parts.push(["\uf41b", t.issue, small(root.pal.green)])
          return parts
        }

        width: list.width
        height: content.implicitHeight + Style.space(14)

        // The opening stagger, a few rows at a time.
        opacity: popup.revealed ? 1 : 0
        transform: Translate {
          y: popup.revealed ? 0 : -Style.space(4)
          Behavior on y {
            SequentialAnimation {
              PauseAnimation { duration: popup.revealed ? Style.duration(Math.max(0, Math.min(row.index * 30, 120))) : 0 }
              NumberAnimation { duration: popup.revealed ? Style.duration(200) : 0; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
            }
          }
        }
        Behavior on opacity {
          SequentialAnimation {
            PauseAnimation { duration: popup.revealed ? Style.duration(Math.max(0, Math.min(row.index * 30, 120))) : 0 }
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
          onClicked: root.openThread(row.t)
        }

        Item {
          id: body
          anchors.fill: parent

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
            font.family: root.barFont
            font.pixelSize: Style.font.body
            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }

          Column {
            id: content
            x: mark.x + mark.width + Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
            width: row.width - x - row.inset
            spacing: Style.space(2)

            Text {
              id: title
              width: parent.width - (trailing.visible ? trailing.width + Style.space(10) : 0)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.t.title
              color: row.ink
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              Behavior on color { ColorAnimation { duration: Style.duration(180) } }
            }
            Text {
              id: detailLine
              visible: row.detail !== ""
              width: parent.width - (row.hasButtons ? buttons.width + Style.space(10) : 0)
              wrapMode: row.wraps ? Text.Wrap : Text.NoWrap
              maximumLineCount: row.wraps ? 2 : 1
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: row.detail
              color: row.alert ? row.tintText : row.ink
              opacity: row.alert || row.dimmed ? 1 : 0.82
              font.family: root.barFont
              font.pixelSize: Style.font.bodySmall
              Behavior on color { ColorAnimation { duration: Style.duration(200) } }
            }
            // Each part fits as a whole or not at all, so nothing ends cut mid-word.
            Row {
              id: metaLine
              width: detailLine.width
              height: Style.font.caption + Style.space(3)
              spacing: Style.space(10)
              clip: true

              Repeater {
                model: row.metaParts
                delegate: Row {
                  required property var modelData
                  required property int index
                  spacing: Style.space(3)
                  visible: x + implicitWidth <= metaLine.width || index === 0
                  Text {
                    textFormat: Text.PlainText
                    text: modelData[0]
                    color: modelData[2]
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    // The project gives way first, so the machine and PR stay in view.
                    width: index === 0 && row.t.project ? Math.min(implicitWidth, metaLine.width * 0.4)
                      : index <= 1 ? Math.min(implicitWidth, metaLine.width * 0.35) : implicitWidth
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: modelData[1]
                    color: modelData[2]
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          // Elapsed time while it runs, the outcome once it ends; on the title line.
          Text {
            id: trailing
            visible: !row.hasButtons && row.kind !== "stale" && !row.resuming
            x: row.width - width - row.inset
            y: content.y
            height: title.height
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: row.kind === "done" ? strings.t("done")
              : row.kind === "failed" ? strings.t("failed")
              : row.kind === "limited" ? strings.t("limit")
              : Model.elapsed(root.now - row.t.since)
            color: row.kind === "done" || row.alert ? row.tintText : row.ink
            font.family: root.barFont
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.features: { "tnum": 1 }
          }
        }

        // The state's buttons, beside the detail and meta lines so the title
        // keeps the full row. A filled capsule acts; a plain one is the way out.
        Row {
          id: buttons
          visible: row.hasButtons
          x: row.width - width - row.inset
          y: content.y + title.height + Style.space(2) + Math.max(0, (content.height - title.height - Style.space(2) - height) / 2)
          spacing: Style.space(5)

          Repeater {
            model: row.buttonsFor
            delegate: Rectangle {
              id: capsule
              required property var modelData
              readonly property bool filled: modelData[2] !== ""
              readonly property string fill: filled ? root.phaseOn(modelData[2], popup.surface) : ""
              width: capsuleLabel.implicitWidth + Style.space(filled ? 20 : 14)
              height: capsuleLabel.implicitHeight + Style.space(8)
              radius: height / 2
              color: filled ? fill : "transparent"
              border.width: filled ? 0 : 1
              readonly property color labelColor: Commons.Color.popups.text
              border.color: Qt.rgba(labelColor.r, labelColor.g, labelColor.b, 0.25)
              opacity: capsuleMouse.containsMouse ? 0.85 : 1
              scale: capsuleMouse.pressed ? 0.96 : 1
              Behavior on scale { NumberAnimation { duration: Style.duration(100); easing.type: Easing.OutCubic } }
              Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

              Text {
                id: capsuleLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: strings.t(capsule.modelData[0])
                // Black or white, whichever reads on this theme's fill.
                color: capsule.filled ? Model.inkOn(capsule.fill) : capsule.labelColor
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: capsule.filled
              }

              MouseArea {
                id: capsuleMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.act(row.t, capsule.modelData[1])
              }
            }
          }
        }
      }
    }
  }
}
