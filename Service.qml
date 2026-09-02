import QtQuick
import Quickshell
import Quickshell.Io

// Mokuzen's clock. It asks bin/mokuzen-agenda what is about to start, and
// when something is, it summons the overlay entry point of this same plugin.
//
// The shell hands this instance to the overlay through `item.service`, so the
// two halves share state in memory: the overlay reads `currentEvent` and calls
// back into `join()`, `snooze()`, `dismiss()`. Nothing is written to disk.
Item {
  id: root

  // Injected by omarchy-shell when the service is mounted.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: manifest && manifest.id ? manifest.id : "io.github.dedeanth.mokuzen"
  // Qt.resolvedUrl(".") ends in a slash and points at this plugin's directory,
  // wherever the user installed it.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string agendaScript: pluginDir + "bin/mokuzen-agenda"
  // Mirrors bin/mokuzen-agenda's own config_path(): honor XDG_CONFIG_HOME
  // when set, rather than assuming ~/.config, so the panel watches the same
  // file the script actually reads.
  readonly property string configHome: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    return (xdg && xdg.length > 0) ? xdg : (Quickshell.env("HOME") + "/.config")
  }
  readonly property string configPath: configHome + "/omarchy/mokuzen.json"

  // ---- configuration -----------------------------------------------------

  property var config: ({})

  readonly property bool enabled: config.enabled !== false
  // Mirrors what the agenda reader uses, so the bar can show and tune it.
  readonly property int leadSeconds: Math.max(0, Number(config.leadSeconds) || 60)
  readonly property int pollSeconds: Math.max(10, Number(config.pollSeconds) || 30)
  readonly property int snoozeSeconds: Math.max(30, Number(config.snoozeSeconds) || 60)
  readonly property int autoDismissSeconds: Math.max(0, Number(config.autoDismissSeconds) || 0)
  readonly property int graceSeconds: Math.max(0, Number(config.graceSeconds) || 120)
  readonly property bool hasCalendars: Array.isArray(config.calendars) && config.calendars.length > 0

  // ---- state -------------------------------------------------------------

  // The occurrence currently being shouted about, as produced by the agenda
  // reader: uid, occurrenceId, summary, start, end, location, link, calendar.
  property var currentEvent: null
  property string lastWarning: ""
  property bool checking: false

  // What the bar widget shows: the next day of meetings, refreshed on the
  // agenda cadence rather than the poll cadence.
  property var upcoming: []
  readonly property var calendars: Array.isArray(config.calendars) ? config.calendars : []
  property bool busy: false

  // occurrenceId -> epoch seconds. Handled means "do not raise this again":
  // either the user dealt with it, or it is sleeping until a later moment.
  property var suppressed: ({})

  PersistentProperties {
    id: persisted
    reloadableId: "mokuzen-service"
    property string suppressedJson: "{}"
  }

  Component.onCompleted: {
    try {
      var restored = JSON.parse(persisted.suppressedJson)
      if (restored && typeof restored === "object") root.suppressed = restored
    } catch (e) {
      root.suppressed = ({})
    }
    prune()
  }

  function nowSeconds() {
    return Math.floor(Date.now() / 1000)
  }

  // Suppressions are worthless once their meeting is long past; dropping them
  // keeps the persisted blob from growing for the life of the session.
  function prune() {
    var now = nowSeconds()
    var next = ({})
    for (var id in root.suppressed) {
      if (Number(root.suppressed[id]) > now) next[id] = root.suppressed[id]
    }
    root.suppressed = next
    persisted.suppressedJson = JSON.stringify(next)
  }

  function suppress(occurrenceId, untilSeconds) {
    if (!occurrenceId) return
    var next = ({})
    for (var id in root.suppressed) next[id] = root.suppressed[id]
    next[occurrenceId] = untilSeconds
    root.suppressed = next
    persisted.suppressedJson = JSON.stringify(next)
  }

  function isSuppressed(occurrenceId) {
    var until = Number(root.suppressed[occurrenceId] || 0)
    return until > nowSeconds()
  }

  // ---- the alert ---------------------------------------------------------

  function raise(event) {
    root.currentEvent = event
    if (!root.shell || typeof root.shell.summon !== "function") {
      console.warn("mokuzen: no shell handle, cannot summon the overlay")
      return
    }
    // The overlay reads currentEvent off this service; the payload is passed
    // too so `omarchy-shell shell summon <id> '<json>'` can drive it by hand.
    root.shell.summon(root.pluginId, JSON.stringify(event))
  }

  function hideOverlay() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // Called by the overlay.
  function dismiss(occurrenceId) {
    var id = occurrenceId || (root.currentEvent ? root.currentEvent.occurrenceId : "")
    var event = root.currentEvent
    // Silence it until well past the end, so a long meeting cannot re-alert.
    var until = event && event.end ? Number(event.end) + 3600 : nowSeconds() + 3600
    suppress(id, until)
    root.currentEvent = null
    hideOverlay()
  }

  function snooze(occurrenceId, seconds) {
    var id = occurrenceId || (root.currentEvent ? root.currentEvent.occurrenceId : "")
    var delay = Math.max(30, Number(seconds) || root.snoozeSeconds)
    suppress(id, nowSeconds() + delay)
    root.currentEvent = null
    hideOverlay()
  }

  function join(link, occurrenceId) {
    if (link) Quickshell.execDetached(["xdg-open", String(link)])
    dismiss(occurrenceId)
  }

  // ---- polling -----------------------------------------------------------

  function handleCheck(text) {
    var payload = null
    try {
      payload = JSON.parse(text)
    } catch (e) {
      console.warn("mokuzen: agenda returned unparseable output:", String(text).slice(0, 200))
      return
    }
    root.lastWarning = (payload.warnings && payload.warnings.length) ? String(payload.warnings[0]) : ""

    var event = payload.event
    if (!event || !event.occurrenceId) return
    if (root.isSuppressed(event.occurrenceId)) return

    // Already on screen for this very occurrence: leave it alone rather than
    // re-summoning every poll.
    if (root.currentEvent && root.currentEvent.occurrenceId === event.occurrenceId
      && root.shell && typeof root.shell.isPluginOpen === "function"
      && root.shell.isPluginOpen(root.pluginId)) {
      root.currentEvent = event
      return
    }

    // A meeting that started a while ago is not news any more.
    if (Number(event.startsIn) < -root.graceSeconds) return

    root.raise(event)
  }

  // ---- what the bar widget needs -----------------------------------------

  // A secret iCal address is a credential; the bar must never render one in
  // full, and a shoulder-surfed screenshot must not give the calendar away.
  function maskCalendar(source) {
    var text = String(source || "")
    if (!/^(https?|webcal):\/\//.test(text)) return text
    var match = text.match(/^[a-z]+:\/\/([^\/]+)\/(.*)$/)
    if (!match) return "remote calendar"
    var tail = match[2].length > 10 ? match[2].slice(-10) : match[2]
    return match[1] + "/…" + tail
  }

  // ---- hard deadlines on every Python child -------------------------------
  //
  // bin/mokuzen-agenda now bounds its own memory and CPU use against a
  // hostile calendar, but the process boundary is the last line of defense:
  // a wedged filesystem, a hung DNS lookup outside the script's own network
  // timeout, or a future regression must not be able to sit inside the shell
  // process forever. main() makes the script its own process-group leader
  // (os.setpgid(0, 0)) whenever it isn't attached to a terminal — which a
  // Process launched from here never is — deliberately not a `setsid`
  // wrapper, since that utility only forks when the *caller* is already a
  // process-group leader, which depends on how this Process type itself
  // spawns children and is not ours to assume. A watchdog Timer below kills
  // the whole group that self-setpgid made, not just the tracked PID, if a
  // run goes past its budget.

  function killHard(proc) {
    if (!proc.running) return
    var pid = proc.processId
    proc.signal(9) // SIGKILL the tracked child directly.
    if (pid !== null && pid !== undefined) {
      // ...and the rest of its self-made process group, in case it ever
      // spawns a child of its own.
      Quickshell.execDetached(["kill", "-9", "--", "-" + String(pid)])
    }
  }

  function refreshUpcoming() {
    if (!root.hasCalendars) {
      root.upcoming = []
      return
    }
    agendaListWatchdog.restart()
    agendaList.running = true
  }

  Process {
    id: agendaList
    command: ["python3", root.agendaScript, "list", "--days", "1", "--limit", "20"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.upcoming = Array.isArray(parsed.events) ? parsed.events : []
        } catch (e) {
          root.upcoming = []
        }
      }
    }
    onExited: function(exitCode) { agendaListWatchdog.stop() }
  }

  Timer {
    id: agendaListWatchdog
    // Python's own shared fetch deadline (FETCH_TOTAL_DEADLINE) plus one
    // worst-case socket-read overshoot is ~23s; this stays comfortably
    // above that regardless of how many calendars are configured.
    interval: 30000
    repeat: false
    onTriggered: root.killHard(agendaList)
  }

  Timer {
    interval: Math.max(60, root.pollSeconds * 4) * 1000
    running: root.enabled && root.hasCalendars
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshUpcoming()
  }

  // ---- configuration, driven from the bar panel --------------------------
  //
  // Every write goes through the same `mokuzen-agenda setup` the command line
  // uses, so there is one implementation of "what a valid config looks like"
  // and one file to back up. The FileView above notices the result.

  property var pendingConfigCommands: []

  function runConfig(args) {
    var queued = root.pendingConfigCommands.slice()
    queued.push(args)
    root.pendingConfigCommands = queued
    if (!configProcess.running) startNextConfig()
  }

  function startNextConfig() {
    if (root.pendingConfigCommands.length === 0) {
      root.busy = false
      return
    }
    var queued = root.pendingConfigCommands.slice()
    var next = queued.shift()
    root.pendingConfigCommands = queued
    root.busy = true
    configProcess.command = ["python3", root.agendaScript, "setup"].concat(next)
    configWatchdog.restart()
    configProcess.running = true
  }

  Process {
    id: configProcess
    onExited: function(exitCode) {
      // A non-zero exit here is usually "that address does not answer", which
      // the panel surfaces; the write itself already happened.
      configWatchdog.stop()
      root.startNextConfig()
      if (root.pendingConfigCommands.length === 0) {
        root.refreshUpcoming()
        root.check()
      }
    }
  }

  Timer {
    id: configWatchdog
    // Setup verifies every configured calendar over the network before
    // returning, against its own shared SETUP_VERIFY_DEADLINE (45s) plus
    // one worst-case socket-read overshoot — this stays above that.
    interval: 70000
    repeat: false
    onTriggered: root.killHard(configProcess)
  }

  function addCalendar(source) {
    var trimmed = String(source || "").trim()
    if (!trimmed) return
    runConfig(["--calendar", trimmed])
  }

  function removeCalendar(source) {
    if (!source) return
    runConfig(["--remove-calendar", String(source), "--no-verify"])
  }

  function setLead(seconds) { runConfig(["--lead", String(Math.max(0, seconds)), "--no-verify"]) }
  function setSnooze(seconds) { runConfig(["--snooze", String(Math.max(30, seconds)), "--no-verify"]) }

  Process {
    id: agendaCheck
    // python3 explicitly rather than relying on the file mode surviving a
    // clone, a zip download, or a copy across filesystems. The script makes
    // itself its own process group leader on startup, so the watchdog below
    // can kill the whole group, not just this PID.
    command: ["python3", root.agendaScript, "check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleCheck(text)
    }
    onExited: function(exitCode) {
      checkWatchdog.stop()
      root.checking = false
      if (exitCode !== 0) console.warn("mokuzen: agenda check exited", exitCode)
    }
  }

  Timer {
    id: checkWatchdog
    // See agendaListWatchdog: comfortably above Python's own worst case.
    interval: 30000
    repeat: false
    onTriggered: root.killHard(agendaCheck)
  }

  function check() {
    if (root.checking || !root.enabled || !root.hasCalendars) return
    root.checking = true
    checkWatchdog.restart()
    agendaCheck.running = true
  }

  Timer {
    interval: root.pollSeconds * 1000
    running: root.enabled && root.hasCalendars
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.prune()
      root.check()
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.config = (parsed && typeof parsed === "object") ? parsed : ({})
      } catch (e) {
        console.warn("mokuzen: mokuzen.json is not valid JSON, ignoring it")
        root.config = ({})
      }
    }
    onLoadFailed: root.config = ({})
    onFileChanged: reload()
  }

  // If the plugin is disabled or reloaded while a Python child is mid-run,
  // that child must not outlive this component — Quickshell tearing down the
  // Service is not the same as the process tree ending on its own.
  Component.onDestruction: {
    killHard(agendaList)
    killHard(configProcess)
    killHard(agendaCheck)
  }
}
