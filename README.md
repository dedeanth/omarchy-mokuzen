# Mokuzen

**目前 — "before the eyes."**

A fullscreen alert before every meeting, for [Omarchy](https://omarchy.org)'s
Quickshell desktop. One minute before a calendar event starts, Mokuzen takes
over the screen with the title, a live countdown, and one key to join the call.
It is hard to ignore on purpose: a notification you can miss is a meeting you
can miss.

## Install

```bash
omarchy plugin add https://github.com/dedeanth/omarchy-mokuzen --enable
```

Then copy the sample configuration and point it at your calendars:

```bash
cp ~/.config/omarchy/plugins/io.github.dedeanth.mokuzen/mokuzen.json.example ~/.config/omarchy/mokuzen.json
$EDITOR ~/.config/omarchy/mokuzen.json
```

The shell watches that file: saved changes take effect immediately, with no
restart. Until `calendars` has at least one entry, Mokuzen stays asleep and
polls nothing.

## Remove

```bash
omarchy plugin remove io.github.dedeanth.mokuzen
rm -f ~/.config/omarchy/mokuzen.json
rm -rf ~/.cache/mokuzen
```

Mokuzen writes nothing else: no state in your shell configuration, no files
outside those two paths.

## Calendars

`calendars` accepts, in any mix:

- a secret iCal address (Google Calendar → *Settings for my calendars* →
  *Integrate calendar* → *Secret address in iCal format*)
- any other public or private `.ics` URL, including `webcal://`
- a path to a local `.ics` file
- a path to a directory, in which case every `.ics` file under it is read —
  which is how you point Mokuzen at a locally synced calendar

Remote calendars are fetched at most every `refreshSeconds` and cached under
`~/.cache/mokuzen`. When the network is down the cached copy is used, and the
overlay says so rather than pretending your day is empty.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `calendars` | `[]` | URLs, files, or directories. Empty means Mokuzen does nothing. |
| `leadSeconds` | `60` | How long before the start the alert appears. |
| `pollSeconds` | `30` | How often the agenda is consulted. |
| `refreshSeconds` | `300` | How often remote calendars are refetched. |
| `snoozeSeconds` | `60` | How long the snooze key hides an alert. |
| `graceSeconds` | `120` | An event that started longer ago than this is not raised. |
| `autoDismissSeconds` | `0` | Close by itself this long after the start. `0` keeps it up. |
| `ignoreAllDay` | `true` | Skip all-day events. |
| `skipCancelled` | `true` | Skip events with `STATUS:CANCELLED`. |
| `skipDeclined` | `true` | Skip events you declined — needs `selfEmails`. |
| `selfEmails` | `[]` | Your addresses, used to recognise your own declines. |
| `ignoreTitles` | `[]` | Regular expressions; a matching title never alerts. |
| `onlyWithLink` | `false` | Only alert for events that carry a meeting link. |
| `enabled` | `true` | Set to `false` to keep the plugin installed but silent. |

## On screen

| Key | Action |
| --- | --- |
| `Enter` | Join the meeting in your browser, then dismiss |
| `S` | Snooze for `snoozeSeconds` |
| `Esc` | Dismiss until the meeting is over |

Keystrokes are ignored for the first three-quarters of a second, so whatever
you happened to be typing when the alert appeared cannot act on it by
accident.

Meeting links are recognised from the location, the description, the `URL`
property, and Google's conference field, covering Meet, Zoom, Teams, Webex,
Whereby, Jitsi, Around, Gather, and Slack huddles. Anything else falls back to
the first link in the event.

## Checking a setup

The agenda reader is a plain command you can run yourself:

```bash
cd ~/.config/omarchy/plugins/io.github.dedeanth.mokuzen
python3 bin/mokuzen-agenda doctor        # what is configured, reachable, parseable
python3 bin/mokuzen-agenda list --days 7 # what it thinks is coming
python3 bin/mokuzen-agenda check         # what it would alert on right now
python3 bin/mokuzen-agenda refresh       # refetch remote calendars now
```

Everything prints JSON. To watch the plugin itself:

```bash
qs log -p "$OMARCHY_PATH/shell" --tail 100
```

To see the overlay without waiting for a meeting:

```bash
omarchy-shell shell summon io.github.dedeanth.mokuzen '{"summary":"Test","start":'"$(( $(date +%s) + 60 ))"',"end":'"$(( $(date +%s) + 1860 ))"',"occurrenceId":"test","link":""}'
```

## How it works

Two entry points of one plugin, and no daemon of their own:

- `Service.qml` runs inside the long-lived `omarchy-shell` process. Every
  `pollSeconds` it runs `bin/mokuzen-agenda check` and, when something is
  about to start, summons the overlay.
- `Overlay.qml` is a layer-shell surface on the overlay layer, holding
  keyboard focus while it is up.

The shell hands the service instance to the overlay, so the two share state in
memory. Nothing about your calendar is written to disk beyond the `.ics` cache,
and nothing leaves your machine except the requests that fetch the calendars
you configured.

## Requirements

- Omarchy 4 with its Quickshell shell
- Python 3.9 or newer — standard library only, nothing to install
- `xdg-open`, to open meeting links in your browser

## License

[MIT](LICENSE) © dedeanth
