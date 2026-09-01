import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// The thing you cannot miss. A layer-shell surface on the overlay layer,
// covering the screen, holding keyboard focus while it is up.
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
  property int nowSeconds: Math.floor(Date.now() / 1000)

  readonly property int startsIn: event && event.start ? Number(event.start) - nowSeconds : 0
  readonly property string summary: event && event.summary ? String(event.summary) : ""
  readonly property string link: event && event.link ? String(event.link) : ""
  readonly property string location: event && event.location ? String(event.location) : ""
  readonly property string calendarName: event && event.calendar ? String(event.calendar) : ""

  // A fullscreen alert wants more presence than a bar popup, but the theme
  // still sets the scale: these are the shell's own tokens, multiplied.
  readonly property int countdownSize: Math.round(Style.font.displayLarge * 2.6)
  readonly property int titleSize: Math.round(Style.font.displayLarge * 1.5)
  readonly property int detailSize: Math.round(Style.font.title * 1.1)

  function open(payload) {
    var incoming = null
    if (payload) {
      try { incoming = JSON.parse(payload) } catch (e) { incoming = null }
    }
    // The service is the source of truth when it has something to say.
    if (root.service && root.service.currentEvent) incoming = root.service.currentEvent
    if (incoming) root.event = incoming
    root.nowSeconds = Math.floor(Date.now() / 1000)
    root.acceptsKeys = false
    inputGuard.restart()
    root.opened = true
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

  function snooze() {
    if (root.service) root.service.snooze(root.event ? root.event.occurrenceId : "", 0)
    else root.close()
  }

  function join() {
    if (root.service) root.service.join(root.link, root.event ? root.event.occurrenceId : "")
    else root.close()
  }

  function clockOf(epoch) {
    return Qt.formatDateTime(new Date(Number(epoch) * 1000), "HH:mm")
  }

  function countdownText() {
    var left = root.startsIn
    if (left <= 0 && left > -60) return "starting now"
    if (left <= -60) return "started " + Math.round(-left / 60) + " min ago"
    if (left < 60) return left + "s"
    var minutes = Math.floor(left / 60)
    var seconds = left % 60
    if (minutes >= 60) {
      var hours = Math.floor(minutes / 60)
      return hours + "h " + (minutes % 60) + "m"
    }
    return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
  }

  function linkLabel() {
    if (!root.link) return ""
    var match = String(root.link).match(/^https?:\/\/([^\/]+)/)
    return match ? match[1] : root.link
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

  PanelWindow {
    id: window

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mokuzen"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.background
      opacity: 0.97
    }

    FocusScope {
      id: scope
      anchors.fill: parent
      focus: root.opened

      onActiveFocusChanged: if (root.opened && !activeFocus) forceActiveFocus()

      Keys.onPressed: function(keyEvent) {
        if (!root.acceptsKeys) {
          keyEvent.accepted = true
          return
        }
        switch (keyEvent.key) {
        case Qt.Key_Escape:
          root.dismiss(); keyEvent.accepted = true; break
        case Qt.Key_Return:
        case Qt.Key_Enter:
          if (root.link) root.join(); else root.dismiss()
          keyEvent.accepted = true; break
        case Qt.Key_S:
          root.snooze(); keyEvent.accepted = true; break
        default:
          break
        }
      }

      ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(96), Style.space(880))
        spacing: Style.space(12)

        Text {
          Layout.alignment: Qt.AlignHCenter
          text: root.countdownText()
          color: root.startsIn <= 0 ? Color.urgent : Color.accent
          font.family: Style.font.family
          font.pixelSize: root.countdownSize
          font.weight: Font.Bold
        }

        Text {
          Layout.alignment: Qt.AlignHCenter
          Layout.fillWidth: true
          text: root.summary
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: root.titleSize
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
            var span = root.clockOf(root.event.start) + " – " + root.clockOf(root.event.end)
            return root.calendarName ? span + "  ·  " + root.calendarName : span
          }
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: root.detailSize
        }

        Text {
          Layout.alignment: Qt.AlignHCenter
          Layout.fillWidth: true
          visible: text !== ""
          text: root.link ? root.linkLabel() : root.location
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideMiddle
        }

        RowLayout {
          Layout.alignment: Qt.AlignHCenter
          Layout.topMargin: Style.space(20)
          spacing: Style.space(12)

          Repeater {
            model: [
              { label: root.link ? "Join" : "Got it", hint: "Enter", primary: true, action: "join" },
              { label: "Snooze", hint: "S", primary: false, action: "snooze" },
              { label: "Dismiss", hint: "Esc", primary: false, action: "dismiss" }
            ]

            delegate: Rectangle {
              required property var modelData

              implicitWidth: buttonRow.implicitWidth + Style.space(32)
              implicitHeight: buttonRow.implicitHeight + Style.space(18)
              radius: Style.cornerRadius
              color: modelData.primary ? Color.accent : "transparent"
              border.width: modelData.primary ? 0 : 1
              border.color: Color.muted

              RowLayout {
                id: buttonRow
                anchors.centerIn: parent
                spacing: Style.space(10)

                Text {
                  text: modelData.label
                  color: modelData.primary ? Color.background : Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                }

                Text {
                  text: modelData.hint
                  color: modelData.primary ? Color.background : Color.muted
                  opacity: 0.7
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (modelData.action === "join") {
                    if (root.link) root.join(); else root.dismiss()
                  } else if (modelData.action === "snooze") {
                    root.snooze()
                  } else {
                    root.dismiss()
                  }
                }
              }
            }
          }
        }

        Text {
          Layout.alignment: Qt.AlignHCenter
          Layout.topMargin: Style.space(8)
          visible: !!root.service && root.service.lastWarning !== ""
          text: root.service ? root.service.lastWarning : ""
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
