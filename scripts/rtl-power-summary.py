#!/usr/bin/env python3
"""Summarise an rtl_power CSV: noise floor and the strongest peaks.

rtl_power writes one row per (frequency range, time step):
    date, time, low_hz, high_hz, step_hz, samples, dbm, dbm, ...

Usage: rtl-power-summary CSV [--at FREQ_HZ]
"""
import csv
import sys


def read_points(path):
    """[(freq_hz, dB)] flattened from every row and bin."""
    points = []
    try:
        with open(path, newline="") as handle:
            for row in csv.reader(handle):
                if len(row) < 7:
                    continue
                try:
                    low = float(row[2])
                    step = float(row[4])
                except ValueError:
                    continue
                for index, value in enumerate(row[6:]):
                    try:
                        points.append((low + index * step, float(value)))
                    except ValueError:
                        continue
    except FileNotFoundError:
        return []
    return points


def median(values):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def summarise(points, at_hz=None, peaks=6, min_spacing_hz=3e5):
    floor = median([db for _, db in points])
    lines = ["noise floor (median): %.1f dB" % floor]

    if at_hz is not None:
        nearby = [db for hz, db in points if abs(hz - at_hz) < min_spacing_hz]
        if nearby:
            best = max(nearby)
            lines.append("power at %.1f MHz: %.1f dB (%+.1f over floor)"
                         % (at_hz / 1e6, best, best - floor))

    lines.append("strongest peaks:")
    chosen = []
    for hz, db in sorted(points, key=lambda p: -p[1]):
        if any(abs(hz - seen) < min_spacing_hz for seen in chosen):
            continue
        chosen.append(hz)
        lines.append("  %8.2f MHz  %6.1f dB  (%+.1f over floor)"
                     % (hz / 1e6, db, db - floor))
        if len(chosen) >= peaks:
            break
    return lines


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    at_hz = None
    if "--at" in args:
        try:
            at_hz = float(args[args.index("--at") + 1])
        except (IndexError, ValueError):
            print("--at needs a frequency in Hz, e.g. --at 1090e6")
            return 2

    points = read_points(path)
    if not points:
        print("No usable data in %s" % path)
        print("Did rtl_power run? Is the dongle free?")
        return 1
    for line in summarise(points, at_hz):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
