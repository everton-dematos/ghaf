# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.ghaf.suricata;
in
  with lib; {
    options.ghaf.suricata = {
      enable = mkEnableOption "Whether to enable Suricata, the network IDS/IPS/NSM engine.";

      # configFile = mkOption {
      #  type = lib.types.path;
      #  default = "/etc/suricata/suricata.yaml";
      #  description = "Path to the Suricata configuration file.";
      #};
    };

    config = mkIf cfg.enable {
      environment.systemPackages = [pkgs.suricata];

      #systemd.ghaf.development.suricata = {
      #  description = "Suricata IDS/IPS/NSM";
      #  after = [ "network.target" ];
      #  wantedBy = [ "multi-user.target" ];
      #  serviceConfig = {
      #    ExecStart = "${pkgs.suricata}/bin/suricata -c ${cfg.configFile} -i eth0";
      #    Restart = "always";
      #    User = "suricata";
      #    Group = "suricata";
      #    WorkingDirectory = "/var/lib/suricata";
      #    PrivateTmp = true;
      #    NoNewPrivileges = true;
      #    CapabilityBoundingSet = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      #    AmbientCapabilities = "CAP_NET_RAW CAP_NET_ADMIN";
      #    ProtectSystem = "full";
      #    ProtectHome = "yes";
      #  };
      #};
    };
  }
