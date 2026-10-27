"""Regressions found by checking Mokuzen against a real Google calendar."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "mokuzen-agenda"
LOADER = importlib.machinery.SourceFileLoader("mokuzen_agenda_reading", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
AGENDA = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(AGENDA)

NOW = datetime(2026, 11, 2, 8, 0, tzinfo=timezone.utc)


def events_from(ics: str) -> list[dict]:
    lines, _ = AGENDA.split_events(ics)
    return [AGENDA.parse_event(event, "test") for event in lines]


def occurrences_of(ics: str, cfg: dict | None = None, days: int = 30) -> list[dict]:
    events = [event for event in events_from(ics) if event]
    config = dict(AGENDA.DEFAULTS, **(cfg or {}))
    with mock.patch.object(AGENDA, "collect", return_value=(events, [])):
        items, _ = AGENDA.occurrences(config, NOW, timedelta(days=days))
    return items


def vevent(body: str) -> str:
    return "BEGIN:VCALENDAR\nBEGIN:VEVENT\n" + body.strip() + "\nEND:VEVENT\nEND:VCALENDAR\n"


class CalendarReadingTests(unittest.TestCase):
    def test_wkst_no_longer_drops_the_series(self):
        items = occurrences_of(vevent("""
UID:weekly
SUMMARY:Bilan Qualité
DTSTART;TZID=Europe/Brussels:20260209T110000
DTEND;TZID=Europe/Brussels:20260209T115000
RRULE:FREQ=WEEKLY;WKST=MO;UNTIL=20261229T135000Z;BYDAY=MO
"""), days=14)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0]["start"], int(datetime(2026, 11, 2, 10, tzinfo=timezone.utc).timestamp()))

    def test_wkst_sets_which_weeks_a_biweekly_rule_keeps(self):
        # RFC 5545's own example: every other week on TU,SU from Tuesday
        # 1997-08-05; the week start decides whether that Sunday is in.
        rule_mo = AGENDA.parse_rrule("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=MO")
        rule_su = AGENDA.parse_rrule("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU")
        seed = datetime(1997, 8, 5).date()
        sunday = datetime(1997, 8, 10).date()
        self.assertTrue(AGENDA.day_matches(sunday, rule_mo, seed))
        self.assertFalse(AGENDA.day_matches(sunday, rule_su, seed))

    def test_alarm_properties_do_not_replace_the_event_s(self):
        [event] = events_from(vevent("""
UID:alarm
SUMMARY:Lunettes : prendre RDV ophtalmo
DESCRIPTION:Join https://teams.microsoft.com/l/meetup-join/abc
DTSTART:20261102T090000Z
DTEND:20261102T093000Z
BEGIN:VALARM
ACTION:EMAIL
SUMMARY:Alarm notification
DESCRIPTION:This is an event reminder
TRIGGER:-PT10M
END:VALARM
"""))
        self.assertEqual(event["summary"], "Lunettes : prendre RDV ophtalmo")
        self.assertEqual(AGENDA.find_link(event), "https://teams.microsoft.com/l/meetup-join/abc")

    def test_a_reminder_with_no_duration_still_alerts(self):
        items = occurrences_of(vevent("""
UID:reminder
SUMMARY:Vitamine D
DTSTART;TZID=Europe/Brussels:20261104T120000
DTEND;TZID=Europe/Brussels:20261104T120000
"""))
        self.assertEqual([item["summary"] for item in items], ["Vitamine D"])
        self.assertEqual(items[0]["start"], items[0]["end"])

    def test_override_written_in_utc_replaces_the_series_instance(self):
        ics = """BEGIN:VCALENDAR
BEGIN:VEVENT
UID:series
SUMMARY:Weekly
DTSTART;TZID=Europe/Brussels:20261026T100000
DTEND;TZID=Europe/Brussels:20261026T110000
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
BEGIN:VEVENT
UID:series
RECURRENCE-ID:20261102T090000Z
SUMMARY:Weekly (moved)
DTSTART;TZID=Europe/Brussels:20261102T140000
DTEND;TZID=Europe/Brussels:20261102T150000
END:VEVENT
END:VCALENDAR
"""
        summaries = [item["summary"] for item in occurrences_of(ics, days=6)]
        self.assertEqual(summaries, ["Weekly (moved)"])

    def test_join_ignores_a_signature_website(self):
        [event] = events_from(vevent("""
UID:signature
SUMMARY:RE: Rencontre echange
DESCRIPTION:Cordialement\\nhttps://dati-securite.fr/
DTSTART:20261117T134500Z
"""))
        self.assertEqual(AGENDA.find_link(event), "")

    def test_long_events_are_not_meetings(self):
        ics = vevent("""
UID:holiday
SUMMARY:Vacances scolaires
DTSTART:20261102T090000Z
DTEND:20261115T090000Z
""")
        self.assertEqual(occurrences_of(ics), [])
        self.assertEqual(len(occurrences_of(ics, {"maxMeetingHours": 0})), 1)

    def test_calendar_name_comes_from_the_document(self):
        self.assertEqual(
            AGENDA.calendar_name("BEGIN:VCALENDAR\r\nX-WR-CALNAME:Calendrier\r\n", "remote"),
            "Calendrier",
        )
        self.assertEqual(AGENDA.calendar_name("BEGIN:VCALENDAR\n", "remote"), "remote")

    def test_google_address_identifies_its_owner(self):
        cfg = dict(AGENDA.DEFAULTS, calendars=[
            "https://calendar.google.com/calendar/ical/me%40example.com/private-x/basic.ics",
        ])
        self.assertEqual(AGENDA.self_addresses(cfg), {"me@example.com"})
        declined = vevent("""
UID:declined
SUMMARY:Declined
DTSTART:20261102T090000Z
ATTENDEE;PARTSTAT=DECLINED:mailto:me@example.com
""")
        self.assertEqual(occurrences_of(declined, {"calendars": cfg["calendars"]}), [])

    def test_windows_zone_names_resolve(self):
        self.assertEqual(str(AGENDA.zone_for("Romance Standard Time")), "Europe/Paris")

    def test_check_lists_every_meeting_due_at_once(self):
        start = int(NOW.timestamp()) + 30
        items = [
            {"occurrenceId": "a", "start": start, "end": start + 3600},
            {"occurrenceId": "b", "start": start, "end": start + 3600},
            {"occurrenceId": "old", "start": start - 4000, "end": start - 3000},
        ]
        cfg = dict(AGENDA.DEFAULTS, calendars=["x.ics"])
        out = io.StringIO()
        with mock.patch.object(AGENDA, "load_config", return_value=cfg), \
             mock.patch.object(AGENDA, "cached_occurrences", return_value=(items, [], True)), \
             mock.patch.object(AGENDA, "datetime", wraps=datetime) as clock, \
             redirect_stdout(out):
            clock.now.return_value = NOW
            AGENDA.cmd_check(SimpleNamespace(config=None, window=None))
        payload = json.loads(out.getvalue())
        self.assertEqual([c["occurrenceId"] for c in payload["candidates"]], ["a", "b"])
        self.assertEqual(payload["event"]["occurrenceId"], "a")


if __name__ == "__main__":
    unittest.main()
