# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.policy.opa-iptable-client;
in
  with lib; {

    options.ghaf.policy.opa-iptable-client = {
      enable = lib.mkOption {
        description = "Enable OPA iptables client.";
        type = lib.types.bool;
        default = false;
      };
    };

    config = lib.mkIf cfg.enable {

      systemd.services.opa-iptable-client = {
        description = "Ghaf OPA IP table client.";
        wantedBy = [ "default.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.opa-iptable-client}/bin/opa-iptables -opa-endpoint http://192.168.101.5:8181";
          Environment  = "PATH=$PATH:/run/current-system/sw/bin/";
        };
      };

      networking = {
        firewall.allowedTCPPorts = [33455];
      };
    };

}
