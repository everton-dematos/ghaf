# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  browserKiller = pkgs.callPackage ../../../../packages/browserKiller {};
  cfg = config.ghaf.policy.browserKiller;
in
  with lib; {
    options.ghaf.policy.browserKiller = {
      enable = lib.mkOption {
        description = "Enable Browser Killer";
        type = lib.types.bool;
        default = true;
      };
    };

    config = lib.mkIf cfg.enable {
      /*
      systemd.services.browserKiller = {
        description = "Ghaf Browser killer";
        wantedBy = [ "default.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${browserKiller}/bin/browserKiller";
          PrivateUsers = true;
          DynamicUser = true;
        };
      };
      */

      environment.systemPackages = [browserKiller];

      networking = {
        firewall.allowedTCPPorts = [4444];
      };
    };
  }
