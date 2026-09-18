# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging.logseald;
  logsealdUnits =
    lib.optionals cfg.producer.enable [
      "logseald-journal-permissions"
      "logseald-producer"
    ]
    ++ lib.optionals cfg.sealer.enable [
      "logseald-sealer"
      "logseald-sealer-proxy"
    ];
  units = logsealdUnits ++ lib.optional (logsealdUnits != [ ]) "systemd-journald";
in
{
  options.ghaf.logging.logseald.performance.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Collect diagnostic CSV resource samples every ten seconds during the first ten minutes of each boot on logseald nodes.";
  };

  config = lib.mkIf (cfg.performance.enable && units != [ ]) {
    systemd.services =
      lib.genAttrs units (_: {
        serviceConfig = {
          CPUAccounting = true;
          MemoryAccounting = true;
        };
      })
      // {
        logseald-performance = {
          description = "Measure logseald resources during the first ten minutes of boot";
          wantedBy = [ "multi-user.target" ];
          after = [
            "local-fs.target"
          ];
          # Ordering before early journald would introduce boot dependency cycles.
          before = map (unit: "${unit}.service") logsealdUnits;
          serviceConfig = {
            Type = "exec";
            ExecStart = lib.escapeShellArgs (
              [
                "${pkgs.python3}/bin/python3"
                "${./logseald-performance.py}"
                "--systemctl"
                "${pkgs.systemd}/bin/systemctl"
                "--node"
                cfg.producer.sourceName
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
