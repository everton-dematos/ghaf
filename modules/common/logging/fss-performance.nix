# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging.fss;
  inherit (config.ghaf.logging) recovery;
  clockReady = recovery.enable && recovery.clockReady.enable;
  units = [
    "systemd-journald"
    "journal-fss-setup"
    "journal-fss-verify"
  ]
  ++ lib.optional (config.ghaf.type == "host") "journal-fss-prepare-persistent-journal"
  ++ lib.optionals clockReady [
    "ghaf-clock-ready"
    "ghaf-clock-sync"
  ];
  node =
    if config.ghaf.type == "host" || config.ghaf.storagevm.name == "" then
      config.networking.hostName
    else
      config.ghaf.storagevm.name;
in
{
  options.ghaf.logging.fss.performance.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Collect journald and FSS helper service resources every ten seconds for the first thirty minutes of boot; disable for production.";
  };
  config = lib.mkIf (cfg.enable && cfg.performance.enable) {
    systemd.services =
      lib.genAttrs units (_: {
        serviceConfig = {
          CPUAccounting = true;
          MemoryAccounting = true;
        };
      })
      // {
        fss-performance = {
          description = "Measure FSS services during the first thirty minutes of boot";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          # Early journald/flush/clock-ready ordering must not depend on this normal service.
          before = [
            "journal-fss-setup.service"
            "journal-fss-verify.service"
          ];
          serviceConfig = {
            Type = "exec";
            ExecStart = lib.escapeShellArgs (
              [
                "${pkgs.python3}/bin/python3"
                "${./fss-performance.py}"
                "--systemctl"
                "${pkgs.systemd}/bin/systemctl"
                "--node"
                node
              ]
              ++ map (unit: "${unit}.service") units
            );
            MemoryMax = "64M";
            MemorySwapMax = 0;
            TasksMax = 8;
            Nice = 10;
            UMask = "0077";
            User = "root";
            CapabilityBoundingSet = [
              "CAP_SYS_PTRACE"
              "CAP_DAC_READ_SEARCH"
            ];
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            PrivateDevices = true;
            PrivateNetwork = true;
            PrivateTmp = false;
            ReadWritePaths = [ "/tmp" ];
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictNamespaces = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
          };
        };
      };
  };
}
