
# adsb-survey - RF sanity sweeps, to tell "bad antenna" from "empty sky".
#
# 1. FM broadcast band. Always present and enormously strong, so clear peaks
#    prove antenna, coax, tuner and ADC all work end to end.
# 2. The 1090 MHz band, for the noise floor and any nearby interference.
#
# IMPORTANT: rtl_power CANNOT see ADS-B. Squitters are ~120us bursts at a very
# low duty cycle, and rtl_power averages power across its integration window,
# so the bursts are smeared into the noise floor. A flat trace at 1090 MHz is
# the EXPECTED result even on a perfectly working receiver - it is not evidence
# of a bad antenna. Judge 1090 MHz by decoded messages (nix run .#status).
#
# The dongle can only be held by one process, so stop the running stack first.

INTEGRATION="${INTEGRATION:-8}"
SURVEY_GAIN="${SURVEY_GAIN:-49.6}"

require_free_dongle

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "=== FM broadcast band (88-108 MHz) ==="
echo "strong peaks here prove the RF chain works"
echo
rtl_power -f 88M:108M:100k -g 30 -i "$INTEGRATION" -1 "$workdir/fm.csv" \
  >/dev/null 2>&1 || true
rtl-power-summary "$workdir/fm.csv"

echo
echo "=== 1090 MHz band (1080-1100 MHz) ==="
echo "expect a FLAT trace - see the note in this script; ADS-B is invisible"
echo "to an averaging power sweep"
echo
rtl_power -f 1080M:1100M:100k -g "$SURVEY_GAIN" -i "$((INTEGRATION * 2))" -1 \
  "$workdir/adsb.csv" >/dev/null 2>&1 || true
rtl-power-summary "$workdir/adsb.csv" --at 1090e6

echo
echo "Interpreting this:"
echo "  FM peaks strong, 1090 flat  -> normal. Judge 1090 by decoded messages."
echo "  FM flat too                 -> antenna, coax or connector fault."
echo "  A strong spike near 1090    -> local interference; consider a filter."
