# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.ghaf.policy.tetragon;
  tetragon = pkgs.callPackage ../../../../packages/tetragon {};
in
  with lib; {

    options.ghaf.policy.tetragon = {

      enable = lib.mkOption {
        description = "Enable tetragon policy client.";
        type = lib.types.bool;
        default = true;
      };

    };

    config = lib.mkIf cfg.enable {

      systemd.services.tetragon = {
        description = "Tetragon eBPF-based Security Observability and Runtime Enforcement";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "local-fs.target" ];
        serviceConfig = {
          Type = "simple";
          User = "root";
          Group = "root";
          Environment="PATH=${tetragon}/lib/tetragon/:${tetragon}/lib:${tetragon}/bin";
          ExecStart = "${tetragon}/bin/tetragon --bpf-lib ${tetragon}/lib/tetragon/bpf --server-address 0.0.0.0:3333 ";
          StartLimitBurst = 10;
          StartLimitIntervalSec = 120;
        };
      };

      environment.etc = {
        tetragon.source = "${tetragon}/lib/tetragon/";
      };

      environment.systemPackages = with pkgs; [tetragon];
       networking = {
         firewall.allowedTCPPorts = [ 3333 ];
       };

    };

}
