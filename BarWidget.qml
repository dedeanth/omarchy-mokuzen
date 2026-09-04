import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The bar half of Mokuzen: what is next, and where you set it up.
//
// The bar injects `bar`, `moduleName` and `settings`; the service instance is
// reached through `bar.shell.serviceFor()`. Omarchy 4 has no settings-form
// renderer for third-party widgets — `settingsForm` takes built-in names and
// nothing consumes a plugin's `schema` — so this widget carries its own.
//
// Every configuration write is delegated to `mokuzen-agenda setup`, the same
// path the command line takes, so there is one notion of a valid config and
// the secret address stays in one owner-only file.
BarWidget {
  id: root

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("io.github.dedeanth.mokuzen") : null

  readonly property var events: service ? service.upcoming : []
  readonly property var nextEvent: events.length > 0 ? events[0] : null
  readonly property var calendars: service ? service.calendars : []
  readonly property bool configured: calendars.length > 0

  property int nowSeconds: Math.floor(Date.now() / 1000)
  readonly property int startsIn: nextEvent ? Number(nextEvent.start) - nowSeconds : -1
  readonly property int leadSeconds: service ? Number(service.leadSeconds) || 60 : 60

  // "countdown" | "time" | "title". Set with:
  //   omarchy bar set io.github.dedeanth.mokuzen label time
  readonly property string labelStyle: String(setting("label", "countdown"))
  readonly property bool hideWhenEmpty: setting("hideWhenEmpty", true) === true

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool imminent: nextEvent && startsIn >= 0 && startsIn <= Math.max(leadSeconds, 300)

  visible: !(hideWhenEmpty && configured && !nextEvent)
  implicitWidth: content.implicitWidth + Style.space(10)
  implicitHeight: bar ? bar.barSize : Style.space(22)

  Timer {
    interval: 20000
    running: true
    repeat: true
    onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
  }

  function clockOf(epoch) {
    return Qt.formatDateTime(new Date(Number(epoch) * 1000), "HH:mm")
  }

  function shortDelay(seconds) {
    if (seconds < 0) return "now"
    if (seconds < 60) return "<1m"
    var minutes = Math.round(seconds / 60)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    return hours + "h" + (minutes % 60 > 0 ? String(minutes % 60) : "")
  }

  function barLabel() {
    if (!root.configured) return "set up"
    if (!root.nextEvent) return ""
    switch (root.labelStyle) {
    case "time": return root.clockOf(root.nextEvent.start)
    case "title": return String(root.nextEvent.summary).slice(0, 22)
    default: return root.shortDelay(root.startsIn)
    }
  }

  RowLayout {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      text: "󰃭"
      color: root.imminent ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
    }

    Text {
      visible: text !== "" && !root.vertical
      text: root.barLabel()
      // In "title" mode this is the event summary from a calendar we do not
      // control.
      textFormat: Text.PlainText
      color: root.imminent ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // The address field only exists while you are typing into it — the same
  // shape as the clock's memento mori, which asks for a birth year on a
  // double-tap and shows nothing otherwise. A secret iCal address is a long
  // unreadable credential; leaving an input holding it open on the panel
  // gives it away to anyone glancing at the screen and buys nothing.
  property bool editingCalendar: false

  function startEditingCalendar() {
    editingCalendar = true
    // Deferred: the field is only instantiated once `visible` turns true.
    Qt.callLater(function() {
      addressField.text = ""
      addressField.forceActiveFocus()
    })
  }

  function cancelEditingCalendar() {
    addressField.text = ""
    editingCalendar = false
  }

  function commitCalendar() {
    var value = addressField.text.trim()
    if (value.length > 0 && root.service) root.service.addCalendar(value)
    cancelEditingCalendar()
  }

  function togglePanel() { panel.visible ? closePanel() : openPanel() }
  function openPanel() { panel.visible = true }
  function closePanel() {
    cancelEditingCalendar()
    panel.visible = false
  }

  // A bar surface exists per monitor, so several instances of this widget try
  // to claim the target; one wins and relays to its peers through the base's
  // broadcast(), which is what it is there for.
  IpcHandler {
    target: "mokuzen"

    function toggle(): void { root.broadcast("togglePanel") }
    function open(): void { root.broadcast("openPanel") }
    function close(): void { root.broadcast("closePanel") }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.service) root.service.refreshUpcoming()
        return
      }
      root.togglePanel()
    }
  }

  // ---- the panel ---------------------------------------------------------

  PanelWindow {
    id: panel

    visible: false
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mokuzen-settings"
    WlrLayershell.layer: WlrLayer.Top
    // OnDemand rather than Exclusive: the address field needs the keyboard,
    // but a settings panel has no business swallowing every key on the system.
    WlrLayershell.keyboardFocus: panel.visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Anywhere outside the card dismisses.
    MouseArea {
      anchors.fill: parent
      onClicked: root.closePanel()
    }

    Rectangle {
      id: card

      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      width: Math.min(420, panel.width - Style.space(16))
      height: cardBody.implicitHeight + Style.space(28)
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: 1
      border.color: Color.popups.border

      // Swallow clicks so they do not reach the dismissing area behind.
      MouseArea { anchors.fill: parent }

      Keys.onEscapePressed: root.editingCalendar ? root.cancelEditingCalendar() : root.closePanel()

      ColumnLayout {
        id: cardBody
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        Text {
          text: root.configured ? "Next up" : "Mokuzen is not set up yet"
          color: Color.popups.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        // ---- the next meetings
        Repeater {
          model: root.configured ? root.events.slice(0, 3) : []

          delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: root.clockOf(modelData.start)
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              Layout.fillWidth: true
              text: modelData.summary
              // Event summary, straight from the calendar.
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              visible: !!modelData.link
              text: "󰕧"
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.configured && root.events.length === 0
          text: "Nothing in the next 24 hours."
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Color.popups.border; opacity: 0.5 }

        // ---- the calendars
        Text {
          text: "Calendars"
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.calendars

          delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: root.service ? root.service.maskCalendar(modelData) : ""
              // A masked calendar address is still address-shaped text from
              // outside this plugin's control.
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Text {
              Layout.rightMargin: Style.space(4)
              text: "✕"
              color: Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) root.service.removeCalendar(modelData)
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Rectangle {
            id: addTrigger
            visible: !root.editingCalendar
            implicitWidth: addTriggerLabel.implicitWidth + Style.space(18)
            implicitHeight: addTriggerLabel.implicitHeight + Style.space(11)
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: Color.popups.border

            Text {
              id: addTriggerLabel
              anchors.centerIn: parent
              text: root.calendars.length > 0 ? "＋  Add a calendar" : "＋  Add your calendar"
              color: Color.popups.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startEditingCalendar()
            }
          }

          // Keeps the trigger its own width instead of stretching it across
          // the card.
          Item { Layout.fillWidth: true; visible: !root.editingCalendar }

          TextField {
            id: addressField
            visible: root.editingCalendar
            Layout.fillWidth: true
            maximumLength: 4096
            placeholderText: "paste the address, then Enter"
            Keys.onEscapePressed: root.cancelEditingCalendar()
            color: Color.popups.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            selectByMouse: true
            background: Rectangle {
              color: "transparent"
              border.width: 1
              border.color: addressField.activeFocus ? Color.accent : Color.popups.border
              radius: Style.cornerRadius
            }
            onAccepted: root.commitCalendar()
          }

          Rectangle {
            id: addButton
            visible: root.editingCalendar
            implicitWidth: addLabel.implicitWidth + Style.space(18)
            implicitHeight: addressField.implicitHeight
            radius: Style.cornerRadius
            color: addressField.text.length > 0 ? Color.accent : "transparent"
            border.width: addressField.text.length > 0 ? 0 : 1
            border.color: Color.popups.border

            Text {
              id: addLabel
              anchors.centerIn: parent
              text: "Add"
              color: addressField.text.length > 0 ? Color.popups.background : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.commitCalendar()
            }
          }
        }

        // ---- the two numbers worth tuning from here
        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          spacing: Style.space(16)

          Repeater {
            model: [
              { label: "Alert", suffix: "s before", key: "lead" },
              { label: "Snooze", suffix: "s", key: "snooze" }
            ]

            delegate: RowLayout {
              required property var modelData
              spacing: Style.space(6)

              readonly property int value: {
                if (!root.service || !modelData) return 0
                var raw = modelData.key === "lead" ? root.service.leadSeconds : root.service.snoozeSeconds
                return Number(raw) || 0
              }

              function apply(next) {
                if (!root.service) return
                if (modelData.key === "lead") root.service.setLead(next)
                else root.service.setSnooze(next)
              }

              Text {
                text: modelData.label
                color: Color.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: [{ glyph: "−", delta: -30 }, { glyph: "+", delta: 30 }]

                delegate: Text {
                  required property var modelData
                  text: modelData.glyph
                  color: Color.popups.text
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: parent.parent.apply(parent.parent.value + modelData.delta)
                  }
                }
              }

              Text {
                text: parent.value + modelData.suffix
                color: Color.popups.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: {
            if (root.service && root.service.busy) return "saving…"
            if (root.service && root.service.lastWarning !== "") return root.service.lastWarning
            return ""
          }
          // lastWarning can carry a fetch error, which can carry text from a
          // calendar server.
          textFormat: Text.PlainText
          color: root.service && root.service.busy ? Color.muted : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
