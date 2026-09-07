"""Verify memory units, window weighting, missing data and process attribution."""

import json
from pathlib import Path
import tempfile
import unittest

from summarize_memory import summarize_memory, window_stats


FIELDS = ["start", "process", "responsible-process", "duration", "pid",
          "memory-physical-footprint", "memory-real", "memory-compressed"]


def fixture():
    schema = "<schema>" + "".join(f"<col><mnemonic>{f}</mnemonic></col>" for f in FIELDS) + "</schema>"
    app = '<process id="app" fmt="Sekai (42)"><pid id="app-pid">42</pid></process>'
    web = '<process id="web" fmt="com.apple.WebKit.WebContent (43)"><pid>43</pid></process>'

    def row(start, duration, value, process='<process ref="app"/>', pid=42, responsible='<process ref="app"/>'):
        footprint = '<sentinel/>' if value is None else f'<size-in-bytes>{value * 1048576}</size-in-bytes>'
        return (f'<row><start-time>{start * 1000000000}</start-time>{process}{responsible}'
                f'<duration>{duration * 1000000000}</duration><pid>{pid}</pid>{footprint}'
                '<size-in-bytes>999999999</size-in-bytes><size-in-bytes>0</size-in-bytes></row>')
    first = row(0, 2, 10, app, responsible='<sentinel/>')
    second = row(2, 3, 20)
    missing = row(5, 1, None)
    last = row(6, 2, 30)
    related = row(2, 3, 100, web, pid=43)
    unknown = row(2, 3, 50, '<process id="other" fmt="com.apple.WebKit.WebContent (44)"><pid>44</pid></process>',
                  pid=44, responsible='<process fmt="Safari (99)"><pid>99</pid></process>')
    unrelated = row(0, 8, 999, '<process fmt="OtherApp (99)"><pid>99</pid></process>', pid=99)
    return f'<trace-query-result><node>{schema}{first}{second}{missing}</node><node>{last}{last}{related}{unknown}{unrelated}</node></trace-query-result>'


class MemorySummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        (self.output / "memory.xml").write_text(fixture())
        (self.output / "metadata.json").write_text(json.dumps({"app_pid": 42}))

    def test_real_format_references_weighting_dedup_and_attribution(self):
        result = summarize_memory(self.output, steady_start=1, steady_end=7)
        self.assertEqual(len(result["processes"]), 3)
        app, web, unknown = result["processes"]
        self.assertEqual(app["full"]["sample_count"], 3)
        self.assertEqual(app["missing_footprint_samples"], 1)
        self.assertEqual(app["full"]["peak_mib"], 30)
        self.assertEqual(app["steady_window"]["time_weighted_mean_mib"], 20)
        self.assertAlmostEqual(app["steady_window"]["coverage_fraction"], 5 / 6)
        self.assertEqual(web["attributions"], ["responsible_pid_matches_app"])
        self.assertEqual(unknown["attributions"], ["unverified"])
        self.assertEqual(len((self.output / "memory.csv").read_text().splitlines()), 7)
        self.assertIn("unverified ownership", " ".join(result["warnings"]))
        self.assertIn("Steady window: [1.000, 7.000)", (self.output / "memory-report.md").read_text())

    def test_short_capture_has_no_invented_steady_state(self):
        result = summarize_memory(self.output)
        self.assertIsNone(result["processes"][0]["steady_window"])
        self.assertIn("steady usage is unavailable", " ".join(result["warnings"]))

    def test_missing_footprint_never_falls_back_to_real_memory(self):
        xml = fixture().replace("<size-in-bytes>10485760</size-in-bytes>", "<sentinel/>")
        xml = xml.replace("<size-in-bytes>20971520</size-in-bytes>", "<sentinel/>")
        xml = xml.replace("<size-in-bytes>31457280</size-in-bytes>", "<sentinel/>")
        (self.output / "memory.xml").write_text(xml)
        with self.assertRaisesRegex(ValueError, "No valid app"):
            summarize_memory(self.output)

    def test_wrong_pid_and_missing_schema_fail(self):
        with self.assertRaisesRegex(ValueError, "No valid app"):
            summarize_memory(self.output, host_pid=123)
        (self.output / "memory.xml").write_text(fixture().replace("memory-physical-footprint", "unknown"))
        with self.assertRaisesRegex(ValueError, "Unsupported memory schema"):
            summarize_memory(self.output)

    def test_nonfinite_window_rejected(self):
        for start, end in [(float("nan"), None), (0, float("inf")), (5, 4), (-1, None)]:
            with self.subTest(start=start, end=end), self.assertRaisesRegex(ValueError, "Invalid memory steady"):
                summarize_memory(self.output, start, end)

    def test_weighted_trend_and_overlap_rejection(self):
        samples = [dict(start_s=i, duration_s=1, footprint_bytes=(i + 1) * 1048576) for i in range(3)]
        result = window_stats(samples, 0, 3)
        self.assertEqual(result["trend_mib_per_minute"], 60)
        self.assertEqual(result["delta_mib"], 2)
        self.assertIsNone(window_stats(samples[:1], 0, 1)["trend_mib_per_minute"])
        with self.assertRaisesRegex(ValueError, "Overlapping"):
            window_stats(samples + samples, 0, 3)


if __name__ == "__main__":
    unittest.main()
