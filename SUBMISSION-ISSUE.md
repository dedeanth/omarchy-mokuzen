# Marketplace submission — values for the form

The marketplace does **not** take a free-form issue body. Submission goes
through an issue *form* (`submit-plugin.yml`), so these are the values to enter
in it, field by field:

> https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml

Filing a plain issue with `--body-file` bypasses the form and its required
fields; use the link above.

---

**Repository URL**

```
https://github.com/dedeanth/omarchy-mokuzen
```

**Category**

```
Productivity
```

**Tags** (one to three; more than three is rejected)

```
Bar
Quickshell
```

Two, not three. `Bar` because the widget makes it literally true, and it is the
filter someone browsing for a bar entry actually uses; `Quickshell` because
that is what this is. Not `Hyprland`: nothing here is compositor-specific — no
window rules, no workspaces, no keybindings — and taking that tag only makes it
worse at finding the plugins that are.

**Suggest a missing tag**

```
Calendar
```

The obvious gap in the list, and reusable by anything else that reads one.

**Maintainer notes**

> Mokuzen is a three-kind plugin — `service`, `overlay` and `bar-widget`. The service polls the configured calendars from inside the shell process; about a minute before a meeting it summons a fullscreen layer-shell alert with a countdown and one key to join. The bar entry shows how long until the next meeting, and its panel is where the user pastes a calendar address.
>
> No dependencies to install. `bin/mokuzen-agenda` is Python 3 standard library only — it parses iCalendar, expands recurrences (INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH), applies EXDATE and RECURRENCE-ID overrides, handles time zones, and extracts meeting links, without any third-party package. The plugin also uses `xdg-open` to open a meeting link when the user asks for it, and answers on the `mokuzen` IPC target so the panel can be bound to a key.
>
> It touches nothing outside `~/.config/omarchy/mokuzen.json`, which the user creates, and an `.ics` cache under `~/.cache/mokuzen`. Both are written owner-only, because a secret iCal address is a credential and the cache holds the calendar it fetched. The plugin never writes to the user's shell configuration; the two bar-entry settings go through `omarchy bar set` like any other widget's. It creates no background units of its own — polling happens inside the existing shell process, roughly 0.16s every 30 seconds against a 10,000-event calendar.
>
> Network access is limited to fetching exactly the calendar URLs the user configured. With no configuration, the plugin polls nothing at all.

**Submission checklist** — all five apply and can be ticked:

- [x] The repository is public and contains installation and removal instructions. — README, *Install* and *Remove*
- [x] I have documented the plugin license and any external dependencies. — MIT, *Requirements*
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent. — the user creates `mokuzen.json` by hand
- [x] I understand that approval is for listing and is not a security review.

---

## One-click, prefilled

This link opens the form with the repository, category, tags and notes already
filled in. Review it, tick the five boxes — they are attestations, they have to
be yours — and submit.

https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml&title=%5BPlugin%5D%3A%20Mokuzen&repository=https%3A//github.com/dedeanth/omarchy-mokuzen&category=Productivity&suggested-tag=Calendar&tags=Bar%2CQuickshell&notes=Mokuzen%20is%20a%20three-kind%20plugin%20%E2%80%94%20%60service%60%2C%20%60overlay%60%20and%20%60bar-widget%60.%20The%20service%20polls%20the%20configured%20calendars%20from%20inside%20the%20shell%20process%3B%20about%20a%20minute%20before%20a%20meeting%20it%20summons%20a%20fullscreen%20layer-shell%20alert%20with%20a%20countdown%20and%20one%20key%20to%20join.%20The%20bar%20entry%20shows%20how%20long%20until%20the%20next%20meeting%2C%20and%20its%20panel%20is%20where%20the%20user%20pastes%20a%20calendar%20address.%0A%0ANo%20dependencies%20to%20install.%20%60bin/mokuzen-agenda%60%20is%20Python%203%20standard%20library%20only%20%E2%80%94%20it%20parses%20iCalendar%2C%20expands%20recurrences%20%28INTERVAL%2C%20COUNT%2C%20UNTIL%2C%20BYDAY%2C%20BYMONTHDAY%2C%20BYMONTH%29%2C%20applies%20EXDATE%20and%20RECURRENCE-ID%20overrides%2C%20handles%20time%20zones%2C%20and%20extracts%20meeting%20links%2C%20without%20any%20third-party%20package.%20The%20plugin%20also%20uses%20%60xdg-open%60%20to%20open%20a%20meeting%20link%20when%20the%20user%20asks%20for%20it%2C%20and%20answers%20on%20the%20%60mokuzen%60%20IPC%20target%20so%20the%20panel%20can%20be%20bound%20to%20a%20key.%0A%0AIt%20touches%20nothing%20outside%20%60~/.config/omarchy/mokuzen.json%60%2C%20which%20the%20user%20creates%2C%20and%20an%20%60.ics%60%20cache%20under%20%60~/.cache/mokuzen%60.%20Both%20are%20written%20owner-only%2C%20because%20a%20secret%20iCal%20address%20is%20a%20credential%20and%20the%20cache%20holds%20the%20calendar%20it%20fetched.%20The%20plugin%20never%20writes%20to%20the%20user%27s%20shell%20configuration%3B%20the%20two%20bar-entry%20settings%20go%20through%20%60omarchy%20bar%20set%60%20like%20any%20other%20widget%27s.%20It%20creates%20no%20background%20units%20of%20its%20own%20%E2%80%94%20polling%20happens%20inside%20the%20existing%20shell%20process%2C%20roughly%200.16s%20every%2030%20seconds%20against%20a%2010%2C000-event%20calendar.%0A%0ANetwork%20access%20is%20limited%20to%20fetching%20exactly%20the%20calendar%20URLs%20the%20user%20configured.%20With%20no%20configuration%2C%20the%20plugin%20polls%20nothing%20at%20all.

## Before submitting

- [x] `preview.png` at the repository root
- [x] Repository pushed and public
