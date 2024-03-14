# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.policy.opa;
in
  with lib; {

    options.ghaf.policy.opa = {

      enable = lib.mkOption {
        description = "Enable OPA policy server.";
        type = lib.types.bool;
        default = false;
      };

    };

    config = lib.mkIf cfg.enable {

      systemd.services.open-policy-agent = {
        description = "Ghaf OPA server.";
        wantedBy = [ "default.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.open-policy-agent}/bin/opa run -s";
          PrivateUsers = true;
          DynamicUser = true;
        };
      };

      networking = {
        firewall.allowedTCPPorts = [8181];
      };

    };

}
