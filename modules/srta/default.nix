# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.srta.tools;
in
  with lib; {
    options.ghaf.srta.tools = {
      enable = mkEnableOption "Secure Runtime Assurance Tools";
    };

    config = mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        # Python 3
        (python3.withPackages (ps:
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
            #pypcap
            torch
            netifaces
          ]))
        
        # Git
        git

        # Network Analyzer
        tcpdump
        #wireshark
      ];
    };
  }
