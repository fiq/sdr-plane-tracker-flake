#!/usr/bin/env python3
"""Tests for the ADS-B helper scripts.

No hardware required - everything runs against fixtures in tests/fixtures.
Run directly, or via `nix flake check`.
"""
import io
import os
import sys
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts"))

import importlib.util


def load_module(name, filename):
    path = os.path.join(os.path.dirname(HERE), "scripts", filename)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


status = load_module("adsb_status", "adsb-status.py")
power = load_module("rtl_power_summary", "rtl-power-summary.py")


class GreatCircleTests(unittest.TestCase):
    def test_zero_distance(self):
        self.assertAlmostEqual(
            status.great_circle_km(-35.98, 174.29, -35.98, 174.29), 0.0, places=6)

    def test_known_distance_auckland_wellington(self):
        # ~494 km; generous tolerance, we only care the maths is not nonsense.
        km = status.great_circle_km(-36.8485, 174.7633, -41.2865, 174.7762)
        self.assertTrue(490 < km < 500, "got %.1f km" % km)

    def test_symmetric(self):
        a = status.great_circle_km(-35.0, 174.0, -36.0, 175.0)
        b = status.great_circle_km(-36.0, 175.0, -35.0, 174.0)
        self.assertAlmostEqual(a, b, places=9)


class SiteEnvTests(unittest.TestCase):
    def setUp(self):
        self.cwd = os.getcwd()
        self.saved = {k: os.environ.get(k) for k in ("LAT", "LON", "XDG_CONFIG_HOME")}
        for key in self.saved:
            os.environ.pop(key, None)

    def tearDown(self):
        os.chdir(self.cwd)
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def write_site_env(self, tmpdir, body):
        with open(os.path.join(tmpdir, "site.env"), "w") as handle:
            handle.write(body)
        os.chdir(tmpdir)

    def test_reads_coordinates(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.write_site_env(tmp, "LAT=-35.9812251\nLON=174.2956254\n")
            self.assertEqual(status.receiver_position(), (-35.9812251, 174.2956254))

    def test_ignores_comments_and_inline_comments(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.write_site_env(
                tmp, "# a comment\nLAT=-35.0   # trailing\nLON=174.0\nGAIN=49.6\n")
            self.assertEqual(status.receiver_position(), (-35.0, 174.0))

    def test_strips_quotes(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.write_site_env(tmp, 'LAT="-35.5"\nLON=\'174.5\'\n')
            self.assertEqual(status.receiver_position(), (-35.5, 174.5))

    def test_environment_wins_over_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.write_site_env(tmp, "LAT=-1.0\nLON=1.0\n")
            os.environ["LAT"] = "-35.0"
            os.environ["LON"] = "174.0"
            self.assertEqual(status.receiver_position(), (-35.0, 174.0))

    def test_missing_config_is_not_fatal(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            os.chdir(tmp)
            os.environ["XDG_CONFIG_HOME"] = os.path.join(tmp, "empty")
            self.assertEqual(status.receiver_position(), (None, None))


class StatusReportTests(unittest.TestCase):
    def test_collect_counts(self):
        metrics = status.collect(FIXTURES)
        self.assertEqual(metrics["messages"], 4071)
        self.assertEqual(metrics["aircraft"], 3)
        self.assertEqual(metrics["positions"], 2)  # ZKDDE has no lat/lon
        self.assertEqual(metrics["accepted"], 4070)  # 3043 + 1027
        self.assertEqual(metrics["strong"], 628)

    def test_collect_missing_dir(self):
        self.assertIsNone(status.collect(os.path.join(FIXTURES, "nope")))

    def test_metrics_output_is_key_value(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = status.print_metrics(FIXTURES)
        self.assertEqual(code, 0)
        parsed = dict(
            line.split("=", 1) for line in buffer.getvalue().splitlines() if line)
        self.assertEqual(parsed["accepted"], "4070")
        self.assertEqual(parsed["positions"], "2")

    def test_report_runs_and_mentions_aircraft(self):
        os.environ["LAT"], os.environ["LON"] = "-35.9812251", "174.2956254"
        try:
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = status.main_with_dir(FIXTURES)
            out = buffer.getvalue()
            self.assertEqual(code, 0)
            self.assertIn("QFA153", out)
            self.assertIn("no position yet", out)  # ZKDDE
            self.assertIn("furthest contact", out)
        finally:
            os.environ.pop("LAT", None)
            os.environ.pop("LON", None)

    def test_missing_data_dir_reports_cleanly(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = status.main_with_dir(os.path.join(FIXTURES, "nope"))
        self.assertEqual(code, 1)
        self.assertIn("Is the stack running?", buffer.getvalue())


class RtlPowerTests(unittest.TestCase):
    def test_reads_points(self):
        points = power.read_points(os.path.join(FIXTURES, "power.csv"))
        self.assertEqual(len(points), 200)

    def test_missing_file_is_empty(self):
        self.assertEqual(power.read_points("/nonexistent.csv"), [])

    def test_median_floor_and_peak(self):
        points = power.read_points(os.path.join(FIXTURES, "power.csv"))
        lines = power.summarise(points, at_hz=91.6e6)
        joined = "\n".join(lines)
        self.assertIn("-20.0 dB", joined)          # flat floor
        self.assertIn("91.60 MHz", joined)         # the planted peak
        self.assertIn("+17.0 over floor", joined)  # -3 against -20

    def test_median_even_and_odd(self):
        self.assertEqual(power.median([1.0, 3.0]), 2.0)
        self.assertEqual(power.median([1.0, 2.0, 3.0]), 2.0)
        self.assertEqual(power.median([]), 0.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
