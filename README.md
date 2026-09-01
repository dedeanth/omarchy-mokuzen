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
omarchy bar put io.github.dedeanth.mokuzen --section right
```

Then hand it your calendar. In Google Calendar, open *Settings for my
calendars → Integrate calendar* and copy the **secret address in iCal format**,
then:

```bash
cd ~/.config/omarchy/plugins/io.github.dedeanth.mokuzen
python3 bin/mokuzen-agenda setup --calendar "https://calendar.google.com/calendar/ical/…/basic.ics"
```

That writes `~/.config/omarchy/mokuzen.json` for you — creating it if needed,
merging into it if it already exists — sets it owner-only, then immediately
fetches the calendar and tells you how many events it found. A typo or a
revoked address fails there and then, instead of silently at 9:59am.

Repeat `--calendar` for as many calendars as you like, and tune the rest the
same way:

```bash
python3 bin/mokuzen-agenda setup --calendar ~/.local/share/calendars/personal
python3 bin/mokuzen-agenda setup --lead 120 --snooze 300
python3 bin/mokuzen-agenda setup --show              # current settings, secret addresses masked
python3 bin/mokuzen-agenda setup --remove-calendar "https://…"
```

The shell watches the file: saved changes take effect immediately, with no
restart. Until at least one calendar is configured, Mokuzen stays asleep and
polls nothing.

`mokuzen.json.example` lists every key if you would rather write the file
yourself.

> A secret iCal address is a credential — anyone holding it can read your
> calendar. Mokuzen keeps `mokuzen.json` owner-only, and never prints an
> address back in full: `setup --show`, `doctor`, and error messages all mask
> it, so a pasted log or bug report does not hand your calendar away.

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

## In the bar

The bar entry is the everyday face of Mokuzen: a calendar glyph and how long
until the next meeting — `8h57`, `42m`, `<1m` — turning urgent as the alert
approaches, and reading `set up` while no calendar is configured.

| Interaction | Action |
| --- | --- |
| left click | open the panel |
| middle click | refetch the agenda now |

The panel shows the next three meetings, the calendars you have configured
(addresses masked), a field to paste a new one, and the alert and snooze
delays. Everything it writes goes through the same `mokuzen-agenda setup` the
command line uses, so there is one config file and one notion of a valid
setting.

It also answers on the `mokuzen` IPC target, if you would rather bind a key:

```bash
omarchy-shell mokuzen toggle    # or open / close
```

Two settings live on the bar entry itself rather than in `mokuzen.json`,
because they are about the bar and not about your calendar:

```bash
omarchy bar set io.github.dedeanth.mokuzen label time          # countdown | time | title
omarchy bar set io.github.dedeanth.mokuzen hideWhenEmpty false --json
```

> Omarchy 4 renders no settings form for third-party widgets — `settingsForm`
> takes built-in names and nothing consumes a plugin's `schema` — so the panel
> above is Mokuzen's own. The `schema` block in the manifest is declared for
> the day that changes.

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
python3 bin/mokuzen-agenda setup --show  # what is configured, secrets masked
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
