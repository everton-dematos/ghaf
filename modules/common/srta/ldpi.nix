# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  ldpiPythonEnv = pkgs.callPackage ../../../packages/ldpi { };
in
{
  options.ghaf.srta.ldpi.tools = {
    enable = lib.mkEnableOption "Enable Secure Runtime Assurance LDPI";
  };

   config = lib.mkIf config.ghaf.srta.ldpi.tools.enable {
    environment.systemPackages = [
      ldpiPythonEnv  
    ];

    # Configuring a systemd service for LDPI
    systemd.services.ldpi = {
      description = "Secure Runtime Assurance LDPI Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = "${ldpiPythonEnv}/bin/python main.py";
        User = "root";
        Restart = "always";
      };
    };
  };
}