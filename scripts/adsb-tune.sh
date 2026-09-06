
# adsb-tune - sweep tuner gain and report which value decodes best.
#
# Gain is a real trade-off: too low and weak aircraft never reach the
# demodulator, too high and strong ones clip and fail CRC. The only honest way
# to choose is to measure against real traffic.
#
# The dongle can only be held by one process, so stop the running stack first.
# Run this during daylight - a sweep against an empty sky measures nothing.
#
#   nix run .#tune
#   DWELL=600 GAINS="49.6 44.5" nix run .#tune

DWELL="${DWELL:-300}"
GAINS="${GAINS:-49.6 44.5 40.2 36.4}"

load_site_config
set_position_args
require_free_dongle

steps=0
for _ in $GAINS; do steps=$((steps + 1)); done
total=$((steps * DWELL))
echo
echo "sweeping $steps gain values, ${DWELL}s each (~$((total / 60)) minutes)"
echo "preamble threshold: $PREAMBLE$AUTO_PREAMBLE"
if [ ${#POS_ARGS[@]} -eq 0 ]; then
  echo "WARNING: LAT/LON unset - positions will not resolve, so the aircraft"
  echo "         column will read low. Message counts are still comparable."
fi
echo

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

results="$workdir/results"
: > "$results"

printf '%-8s %-10s %-10s %-9s %s\n' GAIN MSGS/MIN ACCEPTED STRONG% SIGNAL
for gain in $GAINS; do
  outdir="$workdir/gain-$gain"
  mkdir -p "$outdir"
  timeout "$DWELL" readsb \
    --device-type rtlsdr \
    --gain "$gain" \
    "${POS_ARGS[@]}" \
    --preamble-threshold "$PREAMBLE" \
    --net \
    --write-json "$outdir" \
    --write-json-every 1 \
    --quiet >/dev/null 2>&1 || true

  accepted=0; strong=0; signal=""
  while IFS='=' read -r key value; do
    case "$key" in
      accepted) accepted="$value" ;;
      strong)   strong="$value" ;;
      signal)   signal="$value" ;;
    esac
  done < <(adsb-status --metrics "$outdir" 2>/dev/null || true)

  rate=$(awk -v a="$accepted" -v d="$DWELL" 'BEGIN{printf "%.1f", a*60/d}')
  pct=$(awk -v s="$strong" -v a="$accepted" \
        'BEGIN{if(a>0) printf "%.1f", s*100/a; else printf "0.0"}')
  printf '%-8s %-10s %-10s %-9s %s\n' "$gain" "$rate" "$accepted" "$pct" "${signal:--}"
  echo "$accepted $gain $rate" >> "$results"
done

echo
best=$(sort -rn "$results" | head -1)
bestGain=$(echo "$best" | cut -d' ' -f2)
bestRate=$(echo "$best" | cut -d' ' -f3)
bestCount=$(echo "$best" | cut -d' ' -f1)

if [ "$bestCount" -eq 0 ]; then
  echo "No messages decoded at any gain."
  echo "That points at the antenna or an empty sky, not at gain."
  echo "Sanity-check the RF chain with: nix run .#survey"
else
  echo "best: GAIN=$bestGain at $bestRate msgs/min"
  echo
  echo "Set it in site.env to keep it:"
  echo "  GAIN=$bestGain"
fi
echo
echo "Caveat: traffic varies minute to minute, so treat small differences as"
echo "noise. A clear winner needs a clear margin over a decent dwell."
