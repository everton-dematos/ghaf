# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.ids.suricata.tools;
in
  with lib; {
    options.ghaf.ids.suricata.tools = {
      enable = mkEnableOption "Suricata IDS";
    };

    config = mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
          # Suricata
          suricata

          # Dependencies
          (python3.withPackages (ps:
            with ps; [
              pyyaml
          ]))
      ];
    };
  }
