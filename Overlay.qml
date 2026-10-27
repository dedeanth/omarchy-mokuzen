import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// The thing you cannot miss. A layer-shell surface on the overlay layer on
// every screen — a meeting is just as easy to miss on the monitor you are not
// looking at. The screen that had focus when it opened holds the keyboard; the
// buttons work on all of them.
//
// The look: the wallpaper, blurred and dimmed, under a centred column — title,
// time span, how long until it starts, the notes and calendar buttons, Join
// and Close, then the snooze choices. The clock sits top right.
//
// omarchy-shell drives the lifecycle: summon() calls open(payload), hide()
// calls close(), and `opened` is what the shell reads back. The event itself
// comes from the service instance the shell injects as `service`; the payload
// is only a fallback so the overlay can be driven by hand for testing.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var service: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // Read by the shell to answer "is this plugin open?".
  property bool opened: false

  // This surface takes exclusive keyboard focus the instant it appears, which
  // means whatever the user was typing lands here. Swallow keys briefly so an
  // in-flight keystroke cannot launch a browser or dismiss the alert unseen.
  property bool acceptsKeys: false

  property var event: null
  // Name of the screen that takes the keyboard, chosen when the alert opens.
  property string keyboardScreen: ""
  property int nowSeconds: Math.floor(Date.now() / 1000)

  // Shared by every screen, so opening the notes on one opens them on all.
  property bool showNotes: false
  property bool showLinkMenu: false
  property bool showMoreSnooze: false

  readonly property int startsIn: event && event.start ? Number(event.start) - nowSeconds : 0
  readonly property string summary: event && event.summary ? String(event.summary) : ""
  readonly property string link: event && event.link ? String(event.link) : ""
  readonly property string location: event && event.location ? String(event.location) : ""
  readonly property string notes: event && event.notes ? String(event.notes) : ""
  readonly property string calendarUrl: event && event.calendarUrl ? String(event.calendarUrl) : ""
  readonly property string calendarName: event && event.calendar ? String(event.calendar) : ""

  readonly property string wallpaperPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy/current/background"

  // The theme sets the scale; these are its tokens, multiplied.
  readonly property int titleSize: Math.round(Style.font.displayLarge * 1.3)
  readonly property int spanSize: Math.round(Style.font.displayLarge * 0.85)
  readonly property int statusSize: Style.font.title
  readonly property int buttonSize: Style.font.title
  readonly property int radius: Math.max(Style.cornerRadius, Style.space(7))
  readonly property int actionWidth: Style.space(210)
  // Titles and labels read better in the desktop's sans-serif; the Nerd Font
  // stays for the glyphs.
  readonly property string textFamily: "sans-serif"
  readonly property string glyphFamily: Style.font.family

  readonly property color ink: Color.foreground
  readonly property color line: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.75)
  readonly property color quiet: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.7)

  function tr(key, count) {
    return root.service ? root.service.t(key, count) : key
  }

  function duration(seconds) {
    if (root.service) return root.service.duration(seconds)
    return Math.round(seconds / 60) + " min"
  }

  function open(payload) {
    var incoming = null
    if (payload) {
      try { incoming = JSON.parse(payload) } catch (e) { incoming = null }
    }
    // The service is the source of truth when it has something to say.
    if (root.service && root.service.currentEvent) incoming = root.service.currentEvent
    if (incoming) root.event = incoming
    root.keyboardScreen = focusedScreenName()
    root.nowSeconds = Math.floor(Date.now() / 1000)
    root.showNotes = false
    root.showLinkMenu = false
    root.showMoreSnooze = false
    root.acceptsKeys = false
    inputGuard.restart()
    root.opened = true
  }

  readonly property bool keyboardScreenPresent: {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (String(Quickshell.screens[i].name) === root.keyboardScreen) return true
    }
    return false
  }

  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i].name === name) return name
    }
    return Quickshell.screens.length > 0 ? String(Quickshell.screens[0].name) : ""
  }

  function close() {
    root.opened = false
    root.acceptsKeys = false
    inputGuard.stop()
  }

  function dismiss() {
    if (root.service) root.service.dismiss(root.event ? root.event.occurrenceId : "")
    else root.close()
  }

  // seconds: 0 means the configured snooze delay.
  function snooze(seconds) {
    if (root.service) root.service.snooze(root.event ? root.event.occurrenceId : "", seconds || 0)
    else root.close()
  }

  function join() {
    if (root.service) root.service.join(root.link, root.event ? root.event.occurrenceId : "")
    else root.close()
  }

  function copyLink() {
    if (root.link) Quickshell.execDetached(["wl-copy", "--", root.link])
    root.showLinkMenu = false
  }

  function openCalendar() {
    if (root.calendarUrl) Quickshell.execDetached(["xdg-open", root.calendarUrl])
  }

  function clockOf(epoch) {
    return Qt.formatDateTime(new Date(Number(epoch) * 1000), "HH:mm")
  }

  function statusText() {
    var left = root.startsIn
    if (left > 0) return tr("alert.startsIn").arg(duration(left))
    if (left > -60) return tr("alert.startingNow")
    return tr("alert.startedAgo").arg(duration(-left))
  }

  function linkLabel() {
    var match = String(root.link).match(/^https?:\/\/([^\/]+)/)
    return match ? match[1] : root.link
  }

  readonly property int configuredSnooze: root.service ? Number(root.service.snoozeSeconds) || 60 : 60

  // The snooze row: the configured delay and five minutes, then "when it
  // starts" while that is still ahead; more delays behind the ⋯ button.
  readonly property var snoozeChoices: {
    var seconds = [root.configuredSnooze]
    if (seconds.indexOf(300) < 0) seconds.push(300)
    if (root.showMoreSnooze) {
      var more = [600, 900, 1800]
      for (var i = 0; i < more.length; i++) if (seconds.indexOf(more[i]) < 0) seconds.push(more[i])
    }
    seconds.sort(function(a, b) { return a - b })
    var rows = seconds.map(function(value) {
      return { label: root.tr("alert.snoozeFor").arg(root.duration(value)), seconds: value }
    })
    if (root.startsIn > 30) rows.push({ label: root.tr("alert.snoozeAtStart"), seconds: root.startsIn })
    return rows
  }

  Timer {
    id: inputGuard
    interval: 750
    repeat: false
    onTriggered: root.acceptsKeys = true
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: {
      root.nowSeconds = Math.floor(Date.now() / 1000)
      var limit = root.service ? Number(root.service.autoDismissSeconds) : 0
      if (limit > 0 && root.startsIn <= -limit) root.dismiss()
    }
  }

  // An outlined pill, the shape of every secondary control here.
  component Pill: Rectangle {
    id: pill

    property string label: ""
    property string glyph: ""
    property bool primary: false
    property int fontSize: root.buttonSize
    property int minWidth: 0
    signal activated()

    implicitWidth: Math.max(minWidth, pillRow.implicitWidth + Style.space(30))
    implicitHeight: pillRow.implicitHeight + Style.space(16)
    radius: root.radius
    color: primary ? Color.accent : (pillMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
    border.width: primary ? 0 : 1
    border.color: root.line

    RowLayout {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        visible: pill.glyph !== ""
        text: pill.glyph
        color: pill.primary ? Color.background : root.ink
        font.family: root.glyphFamily
        font.pixelSize: pill.fontSize + 2
      }

      Text {
        visible: pill.label !== ""
        text: pill.label
        color: pill.primary ? Color.background : root.ink
        font.family: root.textFamily
        font.pixelSize: pill.fontSize
        font.weight: Font.DemiBold
        elide: Text.ElideRight
        Layout.maximumWidth: Style.space(220)
      }
    }

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.activated()
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: window

      required property var modelData
      // Only one surface can hold exclusive focus; two would fight over it.
      // If that screen went away, the first remaining one takes over.
      readonly property bool takesKeyboard: String(modelData.name) === root.keyboardScreen
        || (!root.keyboardScreenPresent && Quickshell.screens.length > 0
          && Quickshell.screens[0] === modelData)

      screen: modelData
      visible: root.opened
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "mokuzen"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: root.opened && takesKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Fully opaque on purpose: the theme colour first, the blurred wallpaper
      // over it once loaded, then a dimming veil so the text always reads.
      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1.0)
      }

      Image {
        id: wallpaper
        anchors.fill: parent
        visible: false
        source: root.opened ? "file://" + root.wallpaperPath : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        sourceSize: Qt.size(Math.max(1, window.width / 2), Math.max(1, window.height / 2))
      }

      MultiEffect {
        anchors.fill: parent
        source: wallpaper
        visible: wallpaper.status === Image.Ready
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: 96
        blurMultiplier: 1.4
        saturation: 0.15
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.45)
      }

      FocusScope {
        id: scope
        anchors.fill: parent
        focus: root.opened && window.takesKeyboard

        onActiveFocusChanged: if (root.opened && window.takesKeyboard && !activeFocus) forceActiveFocus()

        Keys.onPressed: function(keyEvent) {
          if (!root.acceptsKeys) {
            keyEvent.accepted = true
            return
          }
          switch (keyEvent.key) {
          case Qt.Key_Escape:
            if (root.showLinkMenu || root.showNotes) {
              root.showLinkMenu = false
              root.showNotes = false
            } else {
              root.dismiss()
            }
            keyEvent.accepted = true; break
          case Qt.Key_Return:
          case Qt.Key_Enter:
            if (root.link) root.join(); else root.dismiss()
            keyEvent.accepted = true; break
          case Qt.Key_S:
            root.snooze(0); keyEvent.accepted = true; break
          default:
            break
          }
        }

        // A click on the background closes the link menu, nothing more.
        MouseArea {
          anchors.fill: parent
          onClicked: root.showLinkMenu = false
        }

        Text {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(18)
          text: Qt.formatDateTime(new Date(root.nowSeconds * 1000), "HH:mm:ss")
          color: root.ink
          font.family: root.textFamily
          font.pixelSize: Style.font.subtitle
          font.weight: Font.DemiBold
          font.features: { "tnum": 1 }
        }

        ColumnLayout {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(96), Style.space(980))
          spacing: Style.space(6)

          Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            text: root.summary
            // The event title comes straight from a calendar we do not
            // control; AutoText would let it be interpreted as rich text.
            textFormat: Text.PlainText
            color: root.ink
            font.family: root.textFamily
            font.pixelSize: root.titleSize
            font.weight: Font.Bold
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            visible: !!root.event
            text: {
              if (!root.event) return ""
              // A reminder (start = end) has a time, not a span.
              return Number(root.event.end) > Number(root.event.start)
                ? root.clockOf(root.event.start) + " – " + root.clockOf(root.event.end)
                : root.clockOf(root.event.start)
            }
            color: root.ink
            font.family: root.textFamily
            font.pixelSize: root.spanSize
            font.features: { "tnum": 1 }
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.statusText()
            color: root.startsIn <= 0 ? Color.urgent : root.ink
            font.family: root.textFamily
            font.pixelSize: root.statusSize
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            visible: text !== ""
            // calendarName is the calendar's own X-WR-CALNAME and the
            // location is free text; both are calendar-controlled.
            text: [root.location, root.calendarName].filter(function(part) { return part !== "" }).join("  ·  ")
            textFormat: Text.PlainText
            color: root.quiet
            font.family: root.textFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
          }

          // Notes and calendar, as small square buttons.
          RowLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(8)
            visible: root.notes !== "" || root.calendarUrl !== ""
            spacing: Style.space(12)

            Pill {
              visible: root.notes !== ""
              glyph: "󰍩"
              implicitWidth: implicitHeight
              color: root.showNotes ? Qt.rgba(1, 1, 1, 0.16) : "transparent"
              onActivated: root.showNotes = !root.showNotes
            }

            Pill {
              visible: root.calendarUrl !== ""
              glyph: "󰃭"
              implicitWidth: implicitHeight
              onActivated: root.openCalendar()
            }
          }

          Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(8)
            Layout.preferredWidth: Math.min(Style.space(620), parent.width)
            Layout.preferredHeight: notesText.implicitHeight + Style.space(24)
            visible: root.showNotes && root.notes !== ""
            radius: root.radius
            color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.55)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)

            Text {
              id: notesText
              anchors.fill: parent
              anchors.margins: Style.space(12)
              text: root.notes
              // Event description: calendar-controlled, already stripped of
              // HTML by the agenda reader, never rendered as rich text.
              textFormat: Text.PlainText
              color: root.ink
              font.family: root.textFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              maximumLineCount: 14
              elide: Text.ElideRight
            }
          }

          // Join, with the link's own menu behind the chevron.
          Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(30)
            Layout.preferredWidth: root.actionWidth
            Layout.preferredHeight: joinLabel.implicitHeight + Style.space(16)
            visible: root.link !== ""
            radius: root.radius
            color: Color.accent

            RowLayout {
              anchors.fill: parent
              spacing: 0

              Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                RowLayout {
                  id: joinLabel
                  anchors.centerIn: parent
                  spacing: Style.space(10)

                  Text {
                    text: "󰕧"
                    color: Color.background
                    font.family: root.glyphFamily
                    font.pixelSize: root.buttonSize + 4
                  }

                  Text {
                    text: root.tr("alert.join")
                    color: Color.background
                    font.family: root.textFamily
                    font.pixelSize: root.buttonSize
                    font.weight: Font.Bold
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.join()
                }
              }

              Rectangle {
                Layout.fillHeight: true
                implicitWidth: 1
                color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.35)
              }

              Item {
                Layout.fillHeight: true
                implicitWidth: Style.space(40)

                Text {
                  anchors.centerIn: parent
                  text: root.showLinkMenu ? "󰅃" : "󰅀"
                  color: Color.background
                  font.family: root.glyphFamily
                  font.pixelSize: root.buttonSize + 2
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showLinkMenu = !root.showLinkMenu
                }
              }
            }
          }

          ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: root.actionWidth
            visible: root.showLinkMenu && root.link !== ""
            spacing: Style.space(4)

            Text {
              Layout.fillWidth: true
              text: root.linkLabel()
              // The link host is calendar-controlled.
              textFormat: Text.PlainText
              color: root.quiet
              font.family: root.textFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideMiddle
            }

            Pill {
              Layout.fillWidth: true
              label: root.tr("alert.copyLink")
              glyph: "󰆏"
              fontSize: Style.font.body
              onActivated: root.copyLink()
            }
          }

          Pill {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: root.link !== "" ? Style.space(4) : Style.space(30)
            Layout.preferredWidth: root.actionWidth
            label: root.tr("alert.close")
            primary: root.link === ""
            onActivated: root.dismiss()
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(56)
            text: root.tr("alert.snooze")
            color: root.ink
            font.family: root.textFamily
            font.pixelSize: Style.font.subtitle
          }

          RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Style.space(10)

            Repeater {
              model: root.snoozeChoices

              delegate: Pill {
                required property var modelData
                label: modelData.label
                fontSize: Style.font.body
                minWidth: Style.space(150)
                onActivated: root.snooze(modelData.seconds)
              }
            }

            Text {
              text: "󰇘"
              color: root.quiet
              font.family: root.glyphFamily
              font.pixelSize: Style.font.title

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showMoreSnooze = !root.showMoreSnooze
              }
            }
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(28)
            text: (root.link ? root.tr("alert.keys") : root.tr("alert.keysNoLink"))
              .arg(root.duration(root.configuredSnooze))
            color: root.quiet
            font.family: root.textFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(8)
            visible: !!root.service && root.service.lastWarning !== ""
            text: root.service ? root.service.lastWarning : ""
            // Warnings can echo a fetch error, which can echo calendar-server
            // content; never let it be interpreted as rich text.
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: root.textFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
