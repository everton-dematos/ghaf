# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.srta.caldera.tools;
in
  with lib; {
    options.ghaf.srta.caldera.tools = {
      enable = mkEnableOption "Caldera Tools";
    };

    config = mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
          # Caldera Tools
          nmap
          inetutils
          netcat
          tshark
          gcc
      ];
    };
  }
