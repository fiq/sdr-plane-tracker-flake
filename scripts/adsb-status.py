#!/usr/bin/env python3
"""Report the state of a running readsb instance.

Reads the JSON readsb writes into the webroot. Receiver position is taken
from site.env (same search order as the runner) so distances can be shown.

Usage: adsb-status [DATA_DIR]      (default: ./run/webroot/data)
"""
import json
import math
import os
import sys

DEFAULT_DATA = os.path.join("run", "webroot", "data")


def find_site_env():
    """Same search order as the runner: checkout first, then per-machine."""
    config_home = os.environ.get(
        "XDG_CONFIG_HOME", os.path.join(os.path.expanduser("~"), ".config")
    )
    for path in ("site.env", os.path.join(config_home, "adsb-1090", "site.env")):
        if os.path.isfile(path):
            return path
    return None


def receiver_position():
    """(lat, lon) from environment, else site.env, else (None, None)."""
    lat, lon = os.environ.get("LAT"), os.environ.get("LON")
    path = find_site_env()
    if path and not (lat and lon):
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.split("#")[0].strip().strip("'\"")
                if key.strip() == "LAT" and not lat:
                    lat = value
                elif key.strip() == "LON" and not lon:
                    lon = value
    try:
        return float(lat), float(lon)
    except (TypeError, ValueError):
        return None, None


def great_circle_km(lat1, lon1, lat2, lon2):
    radius = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlam / 2) ** 2
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None  # readsb rewrites these every second; a torn read is normal


def main():
    data_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DATA

    aircraft_json = load(os.path.join(data_dir, "aircraft.json"))
    if aircraft_json is None:
        print("No aircraft.json under %s" % data_dir)
        print("Is the stack running?  nix run .")
        return 1

    lat, lon = receiver_position()
    aircraft = aircraft_json.get("aircraft", [])
    positioned = [a for a in aircraft if "lat" in a]

    print("messages: %-10s aircraft: %-5s with position: %s"
          % (aircraft_json.get("messages"), len(aircraft), len(positioned)))

    if aircraft:
        print()
        print("  %-7s %-9s %-8s %-7s %s"
              % ("HEX", "FLIGHT", "ALT", "RSSI", "RANGE"))
        def altitude(entry):
            value = entry.get("alt_baro")
            return value if isinstance(value, int) else -1
        for entry in sorted(aircraft, key=altitude, reverse=True):
            rng = ""
            if "lat" in entry and lat is not None:
                rng = "%.1f km" % great_circle_km(lat, lon, entry["lat"], entry["lon"])
            elif "lat" not in entry:
                rng = "(no position yet)"
            print("  %-7s %-9s %-8s %-7s %s"
                  % (entry.get("hex", ""),
                     (entry.get("flight") or "").strip(),
                     entry.get("alt_baro", ""),
                     entry.get("rssi", ""),
                     rng))

    if positioned and lat is not None:
        furthest = max(great_circle_km(lat, lon, a["lat"], a["lon"]) for a in positioned)
        print("\nfurthest contact: %.1f km" % furthest)
    elif lat is None:
        print("\nNo receiver position - set LAT/LON in site.env for ranges.")

    stats = load(os.path.join(data_dir, "stats.json"))
    local = (stats or {}).get("total", {}).get("local")
    if local:
        accepted = local.get("accepted") or [0]
        total = sum(accepted)
        strong = local.get("strong_signals", 0)
        print("\ndecoder (since start)")
        print("  accepted:  %s  (clean, 1-bit corrected)" % accepted)
        print("  signal:    %s dBFS   noise: %s dBFS"
              % (local.get("signal"), local.get("noise")))
        if total:
            pct = 100.0 * strong / total
            print("  strong:    %d of %d (%.1f%%)" % (strong, total, pct))
            if pct > 10:
                print("             >10%% suggests clipping; try a lower GAIN")
        print("\n  Judge these on a decent sample of real traffic - a couple of")
        print("  close aircraft in an empty sky skew 'signal' badly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
