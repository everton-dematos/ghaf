# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging.server;
  startup = cfg.startupLogImport;
  directory = "/var/lib/ghaf-startup-log-import";
  settings = pkgs.writeText "startup-log-import.json" (
    builtins.toJSON {
      host = config.networking.hostName;
      sources = lib.remove config.networking.hostName (builtins.attrNames config.ghaf.networking.hosts);
      remote_journal =
        if config.ghaf.logging.journalServer.enable then "/var/log/ghaf-journal/shared" else null;
      max_bytes = startup.maxExportBytes;
      retention_seconds = startup.retentionDays * 24 * 60 * 60;
    }
  );
in
{
  _file = ./startup-log-import.nix;

  options.ghaf.logging.server.startupLogImport = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.hostPlatform.isAarch64;
      defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isAarch64";
      description = "Import startup journal records already older than Alloy's 15-minute limit at clock synchronization.";
    };
    maxExportBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128 * 1024 * 1024;
      description = "Maximum total size of exported startup logs. A full budget postpones further exports until older copies expire.";
    };
    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Retention of exported startup logs. File reading does not confirm Loki delivery.";
    };
  };

  config = lib.mkIf (cfg.enable && startup.enable) {
    assertions = [
      {
        assertion = config.ghaf.time.enable && config.ghaf.time.requireSync;
        message = "Startup log import requires the Ghaf clock gate in the logging VM.";
      }
    ];

    users.users.ghaf-startup-log-import = {
      isSystemUser = true;
      group = "systemd-journal";
    };

    systemd.services.ghaf-startup-log-import = {
      description = "Import old startup logs through Alloy";
      requires = [ "ghaf-clock-synced.target" ];
      after = [
        "ghaf-clock-synced.target"
        "systemd-journald.service"
        "systemd-tmpfiles-setup.service"
      ];
      path = [ pkgs.systemd ];
      unitConfig.RequiresMountsFor = [
        directory
      ]
      ++ lib.optional config.ghaf.logging.journalServer.enable "/var/log/ghaf-journal/shared";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${./startup-log-import.py} --config ${settings}";
        User = "ghaf-startup-log-import";
        Group = "systemd-journal";
        StateDirectory = "ghaf-startup-log-import";
        StateDirectoryMode = "0750";
        UMask = "0027";
        TimeoutStartSec = "infinity";
        MemoryMax = "192M";
        CPUQuota = "25%";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        PrivateTmp = true;
        PrivateDevices = true;
      };
    };

    systemd.timers.ghaf-startup-log-import = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1s";
        OnUnitInactiveSec = "30s";
        AccuracySec = "5s";
      };
    };

    systemd.services.alloy = {
      after = [ "ghaf-clock-synced.target" ];
      requires = [ "ghaf-clock-synced.target" ];
      unitConfig.RequiresMountsFor = [ directory ];
    };

    ghaf.storagevm = lib.optionalAttrs (options ? ghaf.storagevm.directories) {
      directories = lib.mkIf config.ghaf.storagevm.enable [ directory ];
    };
  };
}
