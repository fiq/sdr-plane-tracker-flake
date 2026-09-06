
# adsb-run - decode ADS-B from an RTL-SDR and serve the tar1090 UI.
#
# TAR1090_DIR is injected by the flake and points at the static UI in the Nix
# store. Everything else comes from site.env (see lib-site-env.sh).

ROOT="$(pwd)"
load_site_config
set_position_args

RUN_DIR="$ROOT/run"
WEBROOT="$RUN_DIR/webroot"
DATA_DIR="$WEBROOT/data"
# Deliberately OUTSIDE the webroot, which is wiped every run. readsb reloads
# this at startup, so aircraft traces and the range outline survive a restart
# instead of starting from nothing each time.
STATE_DIR="$RUN_DIR/state"

mkdir -p "$RUN_DIR" "$STATE_DIR"

# Deterministic webroot each run.
rm -rf "$WEBROOT"
mkdir -p "$DATA_DIR"

cp -r "$TAR1090_DIR"/* "$WEBROOT/"
chmod -R u+w "$WEBROOT"

echo "Webroot:  $WEBROOT"
echo "Data dir: $DATA_DIR"
echo

require_free_dongle

# Port check. ss where available (Linux), else lsof (portable).
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":$PORT "
  else
    lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
  fi
}
if port_in_use; then
  echo "ERROR: Port $PORT is already in use."
  echo "Stop whatever is using it, or set PORT=<n> (see site.env)."
  exit 1
fi

# Callsigns link to FlightAware's live flight page. tar1090 ships the hooks
# (flightawareLinks) but defaults them off, and its callsign column uses the
# Mode-S redirect URL; fa-links.js overrides that. Injected last so it loads
# after script.js, which is what defines the helper being replaced.
cp "$FA_LINKS_JS" "$WEBROOT/fa-links.js"
sed -i 's#</body>#  <script src="fa-links.js"></script>\n</body>#' "$WEBROOT/index.html"

{
  echo ""
  echo "// --- injected by adsb-run ---"
  # SiteCirclesDistances and altitudes follow DisplayUnits, which defaults to
  # nautical. Set it explicitly so the ring numbers below mean kilometres.
  echo "DisplayUnits = \"$UNITS\";"
  # tar1090 caches the units choice in localStorage and prefers it over this
  # file (initializeUnitsSelector), so a stale browser preference would win.
  # config.js is loaded before script.js, so writing it here settles it.
  # Change UNITS in site.env rather than the UI dropdown - a dropdown change
  # is overwritten on the next page load.
  printf "try { localStorage.setItem('displayUnits', '%s'); } catch (e) {}\n" "$UNITS"
  echo "flightawareLinks = true;"
} >> "$WEBROOT/config.js"

if [ ${#POS_ARGS[@]} -gt 0 ]; then
  echo "receiver position: $LAT, $LON (local CPR enabled)"
  # Point the tar1090 map at the receiver too.
  {
    echo "SiteShow = true;"
    echo "SiteLat = DefaultCenterLat = $LAT;"
    echo "SiteLon = DefaultCenterLon = $LON;"
    echo "SiteCircles = true;"
    echo "SiteCirclesDistances = new Array($RINGS);  // $UNITS"
  } >> "$WEBROOT/config.js"
else
  echo "WARNING: LAT/LON unset - aircraft need an odd/even message pair to"
  echo "         plot. Set them in site.env (see site.env.example)."
fi

echo "Starting readsb (RTL-SDR -> JSON)"
echo "gain: $GAIN (fixed; autogain stalls the tuner over USB)"
echo "preamble threshold: $PREAMBLE$AUTO_PREAMBLE (lower = more sensitive)"
echo

readsb \
  --device-type rtlsdr \
  --gain "$GAIN" \
  "${POS_ARGS[@]}" \
  --preamble-threshold "$PREAMBLE" \
  --write-state "$STATE_DIR" \
  --net \
  --write-json "$DATA_DIR" \
  --write-json-every 1 \
  --write-json-globe-index \
  --quiet &

READSB_PID=$!
trap 'kill "$READSB_PID" 2>/dev/null || true' EXIT

echo
echo "Starting tar1090 UI on: http://localhost:$PORT"
echo "Status from another terminal: nix run .#status"
echo "Press Ctrl+C to stop"
echo

cd "$WEBROOT"
python3 -m http.server "$PORT"
