# Shared site-configuration resolution.
#
# Concatenated into the runnable scripts by the flake, so it is not executable
# on its own. `set -euo pipefail` is supplied by writeShellApplication.
#
# Personal settings (coordinates especially) are NOT committed. Searched in
# order, first hit wins:
#   1. ./site.env                            (per-checkout)
#   2. $XDG_CONFIG_HOME/adsb-1090/site.env   (per-machine)
# Precedence: environment variable > site.env > built-in default.

load_site_config() {
  # Capture the environment before sourcing, so env vars keep precedence.
  local envGAIN envLAT envLON envPREAMBLE envPORT config_home candidate cores
  envGAIN="${GAIN:-}"
  envLAT="${LAT:-}"
  envLON="${LON:-}"
  envPREAMBLE="${PREAMBLE:-}"
  envPORT="${PORT:-}"

  config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  SITE_ENV=""
  for candidate in "$PWD/site.env" "$config_home/adsb-1090/site.env"; do
    if [ -f "$candidate" ]; then SITE_ENV="$candidate"; break; fi
  done
  if [ -n "$SITE_ENV" ]; then
    echo "config: $SITE_ENV"
    # shellcheck disable=SC1090,SC1091
    . "$SITE_ENV"
  else
    echo "config: none found (using defaults)"
  fi

  # readsb autogain rewrites the R820T gain register mid-stream and stalls the
  # USB control endpoint (LIBUSB_ERROR_PIPE / -9), leaving gain unset. Pin it.
  GAIN="${envGAIN:-${GAIN:-49.6}}"
  # Receiver position - the ANTENNA, not the house. With it readsb places an
  # aircraft from a SINGLE position message (local CPR); without it, global CPR
  # needs a matched odd/even pair within ~10s, which a sparse signal rarely
  # delivers, so aircraft are heard but never plotted.
  LAT="${envLAT:-${LAT:-}}"
  LON="${envLON:-${LON:-}}"
  PORT="${envPORT:-${PORT:-8080}}"

  # Demodulator sensitivity: 40-400, LOWER = more sensitive, more CPU. readsb
  # ships 58 (75 for a Pi Zero). The demodulator is effectively single-threaded,
  # so core count is only a proxy for "how beefy is this box" - it keeps a weak
  # host from being pegged while a desktop buys sensitivity for free.
  if [ -z "${PREAMBLE:-}" ]; then
    cores="$(nproc 2>/dev/null || echo 4)"
    if   [ "$cores" -ge 8 ]; then PREAMBLE=40
    elif [ "$cores" -ge 4 ]; then PREAMBLE=48
    else                          PREAMBLE=75
    fi
    AUTO_PREAMBLE=" (auto, $cores cores)"
  else
    AUTO_PREAMBLE=""
  fi
  PREAMBLE="${envPREAMBLE:-$PREAMBLE}"
}

# Populate POS_ARGS with readsb's --lat/--lon flags, or leave it empty.
set_position_args() {
  POS_ARGS=()
  if [ -n "${LAT:-}" ] && [ -n "${LON:-}" ]; then
    POS_ARGS=(--lat "$LAT" --lon "$LON")
  fi
}
