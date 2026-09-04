"""Security and recurrence regressions for the standalone agenda reader."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import tempfile
import time
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "mokuzen-agenda"
LOADER = importlib.machinery.SourceFileLoader("mokuzen_agenda_tests", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
AGENDA = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(AGENDA)


class RecurrenceTests(unittest.TestCase):
    def expand(self, rule: str) -> list[str]:
        start = datetime(2026, 1, 1, 9, tzinfo=timezone.utc)
        event = {
            "start": start,
            "end": start + timedelta(hours=1),
            "all_day": False,
            "rrule": rule,
            "exdates": [],
        }
        found = AGENDA.expand(
            event,
            datetime(2025, 12, 31, tzinfo=timezone.utc),
            datetime(2029, 1, 1, tzinfo=timezone.utc),
        )
        return [item.date().isoformat() for item in found]

    def test_malformed_rules_fail_closed(self):
        invalid = (
            "FREQ=WEEKLY;BYDAY=1TH;COUNT=20",
            "FREQ=WEEKLY;COUNT=bogus",
            "FREQ=WEEKLY;INTERVAL=0",
            "FREQ=YEARLY;BYMONTH=bogus",
            "FREQ=DAILY;COUNT=2;UNTIL=20260101T000000Z",
            "FREQ=HOURLY;COUNT=2",
        )
        for rule in invalid:
            with self.subTest(rule=rule), self.assertRaises(ValueError):
                AGENDA.parse_rrule(rule)

    def test_weekly_byday(self):
        self.assertEqual(
            self.expand("FREQ=WEEKLY;BYDAY=TH;COUNT=4"),
            ["2026-01-01", "2026-01-08", "2026-01-15", "2026-01-22"],
        )

    def test_yearly_bymonth_keeps_seed_day(self):
        self.assertEqual(
            self.expand("FREQ=YEARLY;BYMONTH=3;COUNT=3"),
            ["2026-03-01", "2027-03-01", "2028-03-01"],
        )

    def test_yearly_ordinal_byday_is_month_relative_with_bymonth(self):
        self.assertEqual(
            self.expand("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;COUNT=3"),
            ["2026-11-26", "2027-11-25", "2028-11-23"],
        )

    def test_old_weekly_count_rule_fast_forwards(self):
        start = datetime(2010, 1, 6, 9, tzinfo=timezone.utc)
        event = {
            "start": start,
            "end": start + timedelta(hours=1),
            "all_day": False,
            "rrule": "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=3000",
            "exdates": [],
        }
        before = time.monotonic()
        found = AGENDA.expand(
            event,
            datetime(2026, 9, 1, tzinfo=timezone.utc),
            datetime(2026, 9, 8, tzinfo=timezone.utc),
        )
        elapsed = time.monotonic() - before
        self.assertEqual(
            [item.date().isoformat() for item in found],
            ["2026-09-02", "2026-09-04", "2026-09-07"],
        )
        self.assertLess(elapsed, 0.5)


class BoundaryTests(unittest.TestCase):
    def test_configuration_cardinality_is_capped(self):
        cfg = dict(AGENDA.DEFAULTS)
        cfg["calendars"] = ["x"] * (AGENDA.MAX_CALENDAR_SOURCES + 1)
        with self.assertRaises(ValueError):
            AGENDA._validate_config(cfg, Path("mokuzen.json"))

    def test_plain_http_calendar_is_rejected_by_configuration(self):
        cfg = dict(AGENDA.DEFAULTS)
        cfg["calendars"] = ["http://calendar.example/secret.ics"]
        with self.assertRaises(ValueError):
            AGENDA._validate_config(cfg, Path("mokuzen.json"))

    def test_document_cap_is_aggregate_across_a_source(self):
        document = "\n".join(
            (
                "BEGIN:VCALENDAR",
                "BEGIN:VEVENT",
                "UID:bounded",
                "DTSTART:20260904T090000Z",
                "END:VEVENT",
                "END:VCALENDAR",
            )
        )
        cfg = dict(AGENDA.DEFAULTS)
        cfg["calendars"] = ["calendar"]
        with mock.patch.object(
            AGENDA, "read_source", return_value=([document, document, document], [])
        ), mock.patch.object(AGENDA, "MAX_TOTAL_DOCUMENTS", 2):
            events, warnings = AGENDA.collect(cfg)
        self.assertEqual(len(events), 2)
        self.assertTrue(any("2 calendar documents" in item for item in warnings))

    def test_occurrence_cache_cardinality_is_validated(self):
        payload = {
            "events": [{}] * (AGENDA.MAX_OCCURRENCES + 1),
            "warnings": [],
        }
        with self.assertRaises(ValueError):
            AGENDA._validated_cached_occurrences(payload)

    def test_remote_mask_never_retains_secret_path(self):
        masked = AGENDA.mask(
            "https://user:password@calendar.example/very-secret-token"
        )
        self.assertEqual(masked, "https://calendar.example/<redacted>")
        self.assertNotIn("very-secret-token", masked)
        self.assertNotIn("password", masked)

    def test_private_network_destinations_are_rejected(self):
        self.assertEqual(AGENDA._public_addresses("127.0.0.1", 443), [])
        self.assertEqual(AGENDA._public_addresses("169.254.169.254", 443), [])

    def test_redirects_cannot_downgrade_or_target_private_networks(self):
        handler = AGENDA._HttpsOnlyRedirectHandler()
        for destination in (
            "http://calendar.example/feed.ics",
            "https://127.0.0.1/feed.ics",
            "https://169.254.169.254/latest/meta-data/",
        ):
            with self.subTest(destination=destination), self.assertRaises(
                AGENDA.urllib.error.URLError
            ):
                handler.redirect_request(None, None, 302, "Found", {}, destination)

    def test_fetch_deadline_kills_worker(self):
        worker = mock.Mock()
        worker.communicate.side_effect = [
            AGENDA.subprocess.TimeoutExpired("worker", 0.1),
            (b"", b""),
        ]
        with mock.patch.object(AGENDA.subprocess, "Popen", return_value=worker):
            with self.assertRaises(AGENDA._FetchTimedOut):
                AGENDA._fetch_in_subprocess(
                    "https://calendar.example/secret", time.monotonic() + 1
                )
        worker.kill.assert_called_once_with()

    @unittest.skipUnless(
        hasattr(AGENDA.signal, "setitimer"), "requires POSIX interval timers"
    )
    def test_hostile_ignore_pattern_has_a_deadline(self):
        before = time.monotonic()
        hostile_title = "a" * (AGENDA.MAX_REGEX_INPUT_CHARS - 1) + "!"
        self.assertFalse(AGENDA._safe_regex_search("(a+)+$", hostile_title))
        self.assertLess(time.monotonic() - before, 0.5)

    def test_oversized_regex_input_is_rejected_without_truncation(self):
        oversized_title = "a" * AGENDA.MAX_REGEX_INPUT_CHARS + "!"
        self.assertFalse(AGENDA._safe_regex_search("a+$", oversized_title))

    def test_regex_search_still_accepts_a_bounded_match(self):
        self.assertTrue(AGENDA._safe_regex_search("planning$", "Weekly planning"))

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "requires POSIX O_NOFOLLOW")
    def test_capped_read_does_not_follow_leaf_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.ics"
            link = root / "link.ics"
            target.write_text("BEGIN:VCALENDAR\nEND:VCALENDAR\n", encoding="utf-8")
            link.symlink_to(target)
            with self.assertRaises(OSError):
                AGENDA._read_capped_no_follow(link, 1024)


if __name__ == "__main__":
    unittest.main()
