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

        # --- runnable scripts ------------------------------------------
        # The scripts in ./scripts are the source of truth; the flake only
        # supplies dependencies and injects store paths. Concatenating the
        # library keeps shellcheck (via writeShellApplication) able to see the
        # whole program.
        # Each script pulls in only the libraries it uses - shellcheck runs
        # over the concatenated result, so unused helpers are build errors.
        mkScript = { name, runtimeInputs, script, libs ? [], preamble ? "" }:
          pkgs.writeShellApplication {
            inherit name runtimeInputs;
            text = preamble
                   + pkgs.lib.concatMapStrings builtins.readFile libs
                   + builtins.readFile script;
          };

        mkPython = { name, script }:
          pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [ pkgs.python3 ];
            text = ''exec python3 ${script} "$@"
            '';
          };

        adsbStatus = mkPython {
          name = "adsb-status";
          script = ./scripts/adsb-status.py;
        };

        rtlPowerSummary = mkPython {
          name = "rtl-power-summary";
          script = ./scripts/rtl-power-summary.py;
        };

        adsbRun = mkScript {
          name = "adsb-run";
          script = ./scripts/adsb-run.sh;
          libs = [ ./scripts/lib-site-env.sh ./scripts/lib-dongle.sh ];
          preamble = ''
            TAR1090_DIR="${tar1090}/share/tar1090"
            FA_LINKS_JS="${./scripts/tar1090-fa-links.js}"
            export TAR1090_DIR FA_LINKS_JS
          '';
          runtimeInputs = [
            pkgs.readsb
            pkgs.python3
            pkgs.lsof
            pkgs.coreutils
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.usbutils ];
        };

        adsbTune = mkScript {
          name = "adsb-tune";
          script = ./scripts/adsb-tune.sh;
          libs = [ ./scripts/lib-site-env.sh ./scripts/lib-dongle.sh ];
          runtimeInputs = [
            pkgs.readsb
            pkgs.lsof
            pkgs.coreutils
            pkgs.gawk
            adsbStatus
          ];
        };

        adsbSurvey = mkScript {
          name = "adsb-survey";
          script = ./scripts/adsb-survey.sh;
          libs = [ ./scripts/lib-dongle.sh ];
          runtimeInputs = [
            pkgs.rtl-sdr
            pkgs.lsof
            pkgs.coreutils
            rtlPowerSummary
          ];
        };

      in
      {
        packages = {
          tar1090 = tar1090;
          adsb-run = adsbRun;
          adsb-status = adsbStatus;
          adsb-tune = adsbTune;
          adsb-survey = adsbSurvey;
          rtl-power-summary = rtlPowerSummary;
          default = adsbRun;
        };

        apps = {
          default = { type = "app"; program = "${adsbRun}/bin/adsb-run"; };
          status  = { type = "app"; program = "${adsbStatus}/bin/adsb-status"; };
          tune    = { type = "app"; program = "${adsbTune}/bin/adsb-tune"; };
          survey  = { type = "app"; program = "${adsbSurvey}/bin/adsb-survey"; };
        };

        # `nix flake check` runs these. No hardware needed - the tests work
        # against fixtures in ./tests/fixtures.
        checks.tests =
          pkgs.runCommand "adsb-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            cp -r ${./tests} tests
            cp -r ${./scripts} scripts
            python3 tests/test_adsb.py
            touch $out
          '';
      }
    );
}
