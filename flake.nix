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
          version = "unstable-2026-01-17";

          src = pkgs.fetchFromGitHub {
            owner = "wiedehopf";
            repo  = "tar1090";
            # IMPORTANT: pin this to a commit (not "master") for determinism
            # Update these two together if you ever want a newer tar1090.
            rev    = "f0a6b7dbf6d4f0a7a8a1b1b1e9d7b3c4f2a1c0de";
            sha256 = "sha256-QfCBNUIciawIAoRqafim1UiEjnFSeasV59+AR6Bypb4=";
          };

          dontBuild = true;

          installPhase = ''
            mkdir -p $out/share/tar1090
            cp -r html/* $out/share/tar1090/
          '';
        };

        # --- one-command runner: readsb writes into tar1090's /data/ ---
        adsbRun = pkgs.writeShellApplication {
          name = "adsb-run";

          runtimeInputs = [
            pkgs.readsb
            pkgs.python3
            pkgs.lsof
            pkgs.nettools
            pkgs.usbutils
          ];

          text = ''
            set -euo pipefail

            ROOT="$(pwd)"
            RUN_DIR="$ROOT/run"
            WEBROOT="$RUN_DIR/webroot"
            DATA_DIR="$WEBROOT/data"

            mkdir -p "$RUN_DIR"

            # Deterministic webroot each run
            rm -rf "$WEBROOT"
            mkdir -p "$DATA_DIR"

            # Copy tar1090 UI into webroot
            cp -r ${tar1090}/share/tar1090/* "$WEBROOT/"

            echo "Webroot:  $WEBROOT"
            echo "Data dir: $DATA_DIR"
            echo

            # Helpful "busy dongle" check
            if lsof /dev/bus/usb/*/* 2>/dev/null | grep -qiE 'rtl|2832|rtlsdr'; then
              echo "ERROR: RTL-SDR device looks busy (another app has it open)."
              echo "Close gqrx / sdrpp / other readsb instances and try again."
              exit 1
            fi

            # Port check (8080 already in use?)
            if netstat -tln 2>/dev/null | grep -q ':8080 '; then
              echo "ERROR: Port 8080 is already in use."
              echo "Stop whatever is using it, or change the port in this script."
              exit 1
            fi

            echo "Starting readsb (RTL-SDR → JSON)"
            echo "invoked by: readsb --device-type rtlsdr --net --write-json \"$DATA_DIR\" --write-json-every 1 --write-json-globe-index --quiet"
            echo

            readsb \
              --device-type rtlsdr \
              --net \
              --write-json "$DATA_DIR" \
              --write-json-every 1 \
              --write-json-globe-index \
              --quiet &

            READSB_PID=$!
            trap 'kill "$READSB_PID"' EXIT

            echo
            echo "Starting tar1090 UI on: http://localhost:8080"
            echo "Press Ctrl+C to stop"
            echo

            cd "$WEBROOT"
            python3 -m http.server 8080
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
