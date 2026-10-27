import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

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

  // ---- language ------------------------------------------------------------
  //
  // Catalogs in i18n/<code>.json, English underneath. `language` in
  // mokuzen.json forces one; empty follows Setup > Language like the shell.
  readonly property string language: String(config.language || I18n.language || "en")
  property var englishStrings: ({})
  property var languageStrings: ({})

  function parseCatalog(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      return (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (e) {
      return ({})
    }
  }

  FileView {
    path: root.pluginDir + "i18n/en.json"
    printErrors: false
    blockLoading: true
    onLoaded: root.englishStrings = root.parseCatalog(text())
  }

  FileView {
    path: root.language !== "en" ? root.pluginDir + "i18n/" + root.language.split("-")[0] + ".json" : ""
    printErrors: false
    blockLoading: true
    onLoaded: root.languageStrings = root.parseCatalog(text())
    onLoadFailed: root.languageStrings = ({})
    onPathChanged: if (path === "") root.languageStrings = ({})
  }

  // A string, or {"one": …, "other": …} picked by count.
  function t(key, count) {
    var layers = [root.languageStrings, root.englishStrings]
    for (var i = 0; i < layers.length; i++) {
      var value = layers[i][key]
      if (value && typeof value === "object") value = (count === 1 && value.one) ? value.one : value.other
      if (typeof value === "string" && value.length > 0) return value
    }
    return key
  }

  // Past an hour, hours and minutes — "1h05" — never "75 minutes".
  function duration(seconds) {
    seconds = Math.max(0, Math.round(seconds))
    if (seconds < 60) return t("duration.seconds", seconds).arg(seconds)
    var minutes = Math.round(seconds / 60)
    if (minutes < 60) return t("duration.minutes", minutes).arg(minutes)
    var rest = minutes % 60
    return Math.floor(minutes / 60) + "h" + (rest < 10 ? "0" : "") + rest
  }

  // ---- state -------------------------------------------------------------

  // The occurrence currently being shouted about, as produced by the agenda
  // reader: uid, occurrenceId, summary, start, end, location, link, calendar.
  property var currentEvent: null
  property string lastWarning: ""
  property bool checking: false

  // What the bar widget shows: meetings in progress and the next day of
  // meetings, refreshed on the agenda cadence rather than the poll cadence.
  property var inProgress: []
  property var upcoming: []
  readonly property var calendars: Array.isArray(config.calendars) ? config.calendars : []
  property bool busy: false
  property bool refreshAfterConfigLoad: false
  property bool configReadAgain: false

  // occurrenceId -> epoch seconds. Handled means "do not raise this again":
  // either the user dealt with it, or it is sleeping until a later moment.
  property var suppressed: ({})
  readonly property int maxSuppressed: 256

  // occurrenceId -> epoch seconds of the meeting's end. A snoozed meeting
  // comes back when its snooze runs out even if that is after graceSeconds,
  // for as long as it is still under way.
  property var snoozed: ({})

  PersistentProperties {
    id: persisted
    reloadableId: "mokuzen-service"
    property string suppressedJson: "{}"
    property string snoozedJson: "{}"
  }

  function restoreMap(saved) {
    try {
      var text = String(saved || "")
      var restored = text.length <= 262144 ? JSON.parse(text) : ({})
      return (restored && typeof restored === "object") ? restored : ({})
    } catch (e) {
      return ({})
    }
  }

  Component.onCompleted: {
    root.suppressed = restoreMap(persisted.suppressedJson)
    root.snoozed = restoreMap(persisted.snoozedJson)
    prune()
  }

  function nowSeconds() {
    return Math.floor(Date.now() / 1000)
  }

  // Suppressions are worthless once their meeting is long past; dropping them
  // keeps the persisted blob from growing for the life of the session.
  function pruneMap(map) {
    var now = nowSeconds()
    var rows = []
    for (var id in map) {
      var until = Number(map[id])
      if (Number.isFinite(until) && until > now) rows.push({ id: id, until: until })
    }
    rows.sort(function(a, b) { return b.until - a.until })
    var next = ({})
    for (var i = 0; i < Math.min(rows.length, root.maxSuppressed); i++) {
      next[rows[i].id] = rows[i].until
    }
    return next
  }

  function prune() {
    root.suppressed = pruneMap(root.suppressed)
    root.snoozed = pruneMap(root.snoozed)
    persisted.suppressedJson = JSON.stringify(root.suppressed)
    persisted.snoozedJson = JSON.stringify(root.snoozed)
  }

  function suppress(occurrenceId, untilSeconds) {
    if (!occurrenceId) return
    var next = ({})
    for (var id in root.suppressed) next[id] = root.suppressed[id]
    next[String(occurrenceId).slice(0, 768)] = Math.min(Number(untilSeconds), nowSeconds() + 604800)
    root.suppressed = next
    prune()
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
    forgetSnooze(id)
    root.currentEvent = null
    hideOverlay()
  }

  function forgetSnooze(occurrenceId) {
    if (!occurrenceId || root.snoozed[occurrenceId] === undefined) return
    var next = ({})
    for (var id in root.snoozed) if (id !== occurrenceId) next[id] = root.snoozed[id]
    root.snoozed = next
    persisted.snoozedJson = JSON.stringify(next)
  }

  function snooze(occurrenceId, seconds) {
    var id = occurrenceId || (root.currentEvent ? root.currentEvent.occurrenceId : "")
    var delay = Math.max(30, Number(seconds) || root.snoozeSeconds)
    var event = root.currentEvent
    if (id) {
      var next = ({})
      for (var key in root.snoozed) next[key] = root.snoozed[key]
      var end = event && event.end ? Number(event.end) : nowSeconds() + delay + 3600
      next[String(id).slice(0, 768)] = Math.min(Math.max(end, nowSeconds() + delay + 60), nowSeconds() + 604800)
      root.snoozed = next
    }
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

    // Every occurrence due or under way, earliest first; older readers only
    // sent `event`. Take the first one not handled yet, so dismissing one of
    // two simultaneous meetings does not hide the other.
    var candidates = Array.isArray(payload.candidates) ? payload.candidates
      : (payload.event ? [payload.event] : [])
    var open = root.currentEvent && root.shell && typeof root.shell.isPluginOpen === "function"
      && root.shell.isPluginOpen(root.pluginId)

    for (var i = 0; i < candidates.length; i++) {
      var event = candidates[i]
      if (!event || !event.occurrenceId) continue

      // Already on screen for this very occurrence: leave it alone rather
      // than re-summoning every poll.
      if (open && root.currentEvent.occurrenceId === event.occurrenceId) {
        root.currentEvent = event
        return
      }
      if (root.isSuppressed(event.occurrenceId)) continue

      // A meeting that started a while ago is not news any more — unless it
      // was snoozed, in which case this is exactly the moment asked for.
      var wasSnoozed = root.snoozed[event.occurrenceId] !== undefined
      if (Number(event.startsIn) < -root.graceSeconds && !wasSnoozed) continue

      // Something is already up: do not replace it with another meeting.
      if (open) return
      root.raise(event)
      return
    }
  }

  // ---- what the bar widget needs -----------------------------------------

  // A secret iCal address is a credential; the bar must never render one in
  // full, and a shoulder-surfed screenshot must not give the calendar away.
  function maskCalendar(source) {
    var text = String(source || "")
    if (!/^(https?|webcal):\/\//i.test(text)) return text
    var match = text.match(/^[a-z]+:\/\/([^\/]+)/i)
    if (!match) return "remote calendar"
    return match[1].replace(/^.*@/, "") + "/<redacted>"
  }

  // Never load mokuzen.json directly into the shell. Python applies strict
  // byte, schema and cardinality limits, then emits only bounded fields.
  function loadConfig(refreshAfter) {
    if (refreshAfter) root.refreshAfterConfigLoad = true
    if (configReader.running) {
      root.configReadAgain = true
      return
    }
    configReaderWatchdog.restart()
    configReader.running = true
  }

  Process {
    id: configReader
    command: ["python3", root.agendaScript, "config"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.config = (parsed && typeof parsed === "object") ? parsed : ({})
          if (root.lastWarning.indexOf("mokuzen.json") === 0) root.lastWarning = ""
          if (root.refreshAfterConfigLoad && !root.configReadAgain) {
            root.refreshAfterConfigLoad = false
            Qt.callLater(function() {
              root.refreshUpcoming()
              root.check()
            })
          }
        } catch (e) {
          root.config = ({})
          root.lastWarning = "mokuzen.json is invalid or too large"
        }
      }
    }
    onExited: function(exitCode) {
      configReaderWatchdog.stop()
      if (exitCode !== 0) {
        root.config = ({})
        root.lastWarning = "mokuzen.json is invalid or unreadable"
      }
      if (root.configReadAgain) {
        root.configReadAgain = false
        Qt.callLater(function() { root.loadConfig(false) })
      }
    }
  }

  Timer {
    id: configReaderWatchdog
    interval: 10000
    repeat: false
    onTriggered: root.killHard(configReader)
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.loadConfig(false)
  }

  // ---- hard deadlines on every Python child -------------------------------
  //
  // bin/mokuzen-agenda now bounds its own memory and CPU use against a
  // hostile calendar, but the process boundary is the last line of defense:
  // a wedged filesystem or a future regression must not be able to sit inside
  // the shell process forever. Network work also runs in a disposable child
  // so its deadline covers DNS, TLS, redirects and body reads. main() makes
  // the script its own process-group leader
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
      root.inProgress = []
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
          root.inProgress = Array.isArray(parsed.current) ? parsed.current : []
          root.upcoming = Array.isArray(parsed.events) ? parsed.events : []
        } catch (e) {
          root.inProgress = []
          root.upcoming = []
        }
      }
    }
    onExited: function(exitCode) { agendaListWatchdog.stop() }
  }

  Timer {
    id: agendaListWatchdog
    // Above Python's 15-second shared fetch deadline, with room for parsing
    // and clean shutdown regardless of how many calendars are configured.
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
  // and one file to back up. The bounded reader above notices the result.

  property var pendingConfigCommands: []

  function runConfig(args) {
    var queued = root.pendingConfigCommands.slice()
    if (queued.length >= 32) {
      root.lastWarning = "too many pending configuration changes"
      return
    }
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
      if (root.pendingConfigCommands.length > 0) root.startNextConfig()
      else {
        root.busy = false
        root.loadConfig(true)
      }
    }
  }

  Timer {
    id: configWatchdog
    // Setup verifies every configured calendar over the network before
    // returning. This stays above its own 45-second shared verification
    // deadline, with room for parsing and clean shutdown.
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

  // If the plugin is disabled or reloaded while a Python child is mid-run,
  // that child must not outlive this component — Quickshell tearing down the
  // Service is not the same as the process tree ending on its own.
  Component.onDestruction: {
    killHard(agendaList)
    killHard(configProcess)
    killHard(agendaCheck)
    killHard(configReader)
  }
}
