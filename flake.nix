{
  description = "ADS-B one-command stack (readsb + tar1090) for NixOS (deterministic, nix run)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # --- tar1090 static UI (pinned commit for determinism) ---
        tar1090 = pkgs.stdenvNoCC.mkDerivation rec {
          pname = "tar1090";
          version = "unstable-2026-01-18";

          src = pkgs.fetchFromGitHub {
            owner = "wiedehopf";
            repo  = "tar1090";
            # IMPORTANT: pin this to a commit (not "master") for determinism
            # Update these two together if you ever want a newer tar1090.
            rev    = "0ce055e0dfb8a82d8128bf6bb44a71ed2ab63888";
            sha256 = "sha256-QfCBNUIciawIAoRqafim1UiEjnFSeasV59+AR6Bypb4=";
          };

          dontBuild = true;

          installPhase = ''
            mkdir -p $out/share/tar1090
            cp -r html/* $out/share/tar1090/
            chmod -R u+w $out/share/tar1090/
          '';
        };

        # --- one-command runner: readsb writes into tar1090's /data/ ---
        adsbRun = pkgs.writeShellApplication {
          name = "adsb-run";

          runtimeInputs = [
            pkgs.readsb
            pkgs.python3
            pkgs.lsof
            pkgs.coreutils
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.usbutils
          ];

          text = ''
            set -euo pipefail

            ROOT="$(pwd)"

            # --- site configuration -------------------------------------------
            # Personal settings (coordinates especially) are NOT committed.
            # Searched in order; first hit wins:
            #   1. ./site.env                       (per-checkout)
            #   2. $XDG_CONFIG_HOME/adsb-1090/site.env  (per-machine)
            # See site.env.example for the template.
            # Precedence: environment variable > site.env > default below.
            envGAIN="''${GAIN:-}"
            envLAT="''${LAT:-}"
            envLON="''${LON:-}"
            envPREAMBLE="''${PREAMBLE:-}"
            envPORT="''${PORT:-}"

            CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}"
            SITE_ENV=""
            for candidate in "$ROOT/site.env" "$CONFIG_HOME/adsb-1090/site.env"; do
              if [ -f "$candidate" ]; then SITE_ENV="$candidate"; break; fi
            done
            if [ -n "$SITE_ENV" ]; then
              echo "config: $SITE_ENV"
              # shellcheck disable=SC1090,SC1091
              . "$SITE_ENV"
            else
              echo "config: none found (using defaults)"
            fi

            # RTL-SDR autogain re-writes the R820T gain register mid-stream and
            # stalls the USB control endpoint (LIBUSB_ERROR_PIPE / -9), leaving
            # gain unset. Pin it instead.
            GAIN="''${envGAIN:-''${GAIN:-49.6}}"
            # Receiver position - the ANTENNA, not the house. With it, readsb
            # places an aircraft from a SINGLE position message (local CPR).
            # Without it, it needs a matched odd/even pair within ~10s (global
            # CPR), which a weak, sparse signal often never delivers.
            LAT="''${envLAT:-''${LAT:-}}"
            LON="''${envLON:-''${LON:-}}"
            # Demodulator sensitivity: 40-400, LOWER = more sensitive, more CPU.
            # readsb ships 58 (and suggests 75 for a Pi Zero). The demodulator
            # is effectively single-threaded, so core count is only a proxy for
            # "how beefy is this box" - it keeps a weak host from being pegged
            # while letting a desktop buy extra sensitivity for free.
            if [ -z "''${PREAMBLE:-}" ]; then
              cores="$(nproc 2>/dev/null || echo 4)"
              if   [ "$cores" -ge 8 ]; then PREAMBLE=40
              elif [ "$cores" -ge 4 ]; then PREAMBLE=48
              else                          PREAMBLE=75
              fi
              autoPreamble=" (auto, $cores cores)"
            else
              autoPreamble=""
            fi
            PREAMBLE="''${envPREAMBLE:-$PREAMBLE}"
            PORT="''${envPORT:-''${PORT:-8080}}"
            RUN_DIR="$ROOT/run"
            WEBROOT="$RUN_DIR/webroot"
            DATA_DIR="$WEBROOT/data"

            mkdir -p "$RUN_DIR"

            # Deterministic webroot each run
            rm -rf "$WEBROOT"
            mkdir -p "$DATA_DIR"

            # Copy tar1090 UI into webroot
            cp -r ${tar1090}/share/tar1090/* "$WEBROOT/"
            chmod -R u+w "$WEBROOT"

            echo "Webroot:  $WEBROOT"
            echo "Data dir: $DATA_DIR"
            echo

            # Helpful "busy dongle" check (Linux exposes raw USB here)
            if [ -d /dev/bus/usb ] && lsof /dev/bus/usb/*/* 2>/dev/null | grep -qiE 'rtl|2832|rtlsdr'; then
              echo "ERROR: RTL-SDR device looks busy (another app has it open)."
              echo "Close gqrx / sdrpp / other readsb instances and try again."
              exit 1
            fi

            # Port check. ss where available (Linux), else lsof (portable).
            portInUse() {
              if command -v ss >/dev/null 2>&1; then
                ss -tln 2>/dev/null | grep -q ":$PORT "
              else
                lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
              fi
            }
            if portInUse; then
              echo "ERROR: Port $PORT is already in use."
              echo "Stop whatever is using it, or set PORT=<n> (see site.env)."
              exit 1
            fi

            echo "Starting readsb (RTL-SDR → JSON)"
            echo "gain: $GAIN (fixed; autogain stalls the tuner over USB)"
            echo "preamble threshold: $PREAMBLE$autoPreamble (lower = more sensitive)"
            echo "invoked by: readsb --device-type rtlsdr --gain $GAIN --net --write-json \"$DATA_DIR\" --write-json-every 1 --write-json-globe-index --quiet"
            echo

            POS_ARGS=()
            if [ -n "$LAT" ] && [ -n "$LON" ]; then
              POS_ARGS=(--lat "$LAT" --lon "$LON")
              echo "receiver position: $LAT, $LON (local CPR enabled)"
              # Point the tar1090 map at the receiver too.
              {
                echo ""
                echo "SiteShow = true;"
                echo "SiteLat = DefaultCenterLat = $LAT;"
                echo "SiteLon = DefaultCenterLon = $LON;"
                echo "SiteCircles = true;"
                echo "siteCirclesDistances = new Array(50,100,150,200,250);"
              } >> "$WEBROOT/config.js"
            else
              echo "WARNING: LAT/LON unset - aircraft need an odd/even message"
              echo "         pair to plot. Set them: LAT=-41.2 LON=174.9 nix run ."
            fi

            readsb \
              --device-type rtlsdr \
              --gain "$GAIN" \
              "''${POS_ARGS[@]}" \
              --preamble-threshold "$PREAMBLE" \
              --net \
              --write-json "$DATA_DIR" \
              --write-json-every 1 \
              --write-json-globe-index \
              --quiet &

            READSB_PID=$!
            trap 'kill "$READSB_PID"' EXIT

            echo
            echo "Starting tar1090 UI on: http://localhost:$PORT"
            echo "Press Ctrl+C to stop"
            echo

            cd "$WEBROOT"
            python3 -m http.server "$PORT"
          '';
        };

      in
      {
        packages = {
          tar1090 = tar1090;
          adsb-run = adsbRun;
          default = adsbRun;
        };

        apps = {
          default = {
            type = "app";
            program = "${adsbRun}/bin/adsb-run";
          };
        };
      }
    );
}
