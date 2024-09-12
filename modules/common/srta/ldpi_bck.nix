# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.srta.ldpi.tools;
in
  with lib; {
    options.ghaf.srta.ldpi.tools = {
      enable = mkEnableOption "Secure Runtime Assurance LDPI";
    };

    config = mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
          # Python 3
          libpcap
          (python311.withPackages (ps:
            with ps; [
              numpy
              pandas
              scipy
              scikit-learn
              tqdm
              dpkt
              matplotlib
              cycler
              libpcap
              (import ./custom_pypcap.nix {
                inherit (pkgs) lib fetchFromGitHub libpcap;
                inherit (pkgs.python311Packages) buildPythonPackage dpkt pytestCheckHook;
              })
              torch
              netifaces
              systemd
            ]))

          # Git
          git

          # Network Analyzer
          tcpdump
          hey

          # Load Generator
          stress-ng
      ];
    };
  }
