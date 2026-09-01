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
Quickshell
Hyprland
```

**Suggest a missing tag** — leave empty.

**Maintainer notes**

> Mokuzen is a `service` + `overlay` plugin: the service polls the configured
> calendars from inside the shell process and summons a fullscreen layer-shell
> alert about a minute before each meeting.
>
> No dependencies to install. `bin/mokuzen-agenda` is Python 3 standard library
> only — it parses iCalendar, expands recurrences, and extracts meeting links
> without any third-party package. The plugin also uses `xdg-open` to open a
> meeting link when the user asks for it.
>
> It touches nothing outside `~/.config/omarchy/mokuzen.json`, which the user
> creates, and an `.ics` cache under `~/.cache/mokuzen`. It never writes to the
> user's shell configuration, and it creates no background units of its own —
> polling happens inside the existing shell process.
>
> Network access is limited to fetching exactly the calendar URLs the user
> configured. With no configuration, the plugin polls nothing at all.

**Submission checklist** — all five apply and can be ticked:

- [x] The repository is public and contains installation and removal instructions. — README, *Install* and *Remove*
- [x] I have documented the plugin license and any external dependencies. — MIT, *Requirements*
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent. — the user creates `mokuzen.json` by hand
- [x] I understand that approval is for listing and is not a security review.

---

## Before submitting

- [ ] `preview.png` at the repository root
- [ ] Repository pushed and public
- [ ] Submit the form at the link above
