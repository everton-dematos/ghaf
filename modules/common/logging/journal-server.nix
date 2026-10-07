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
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    types
    ;
  cfg = config.ghaf.logging.journalServer;
  givcEnabled = config.ghaf.givc.enable;
  givcHostEnabled = config.ghaf.givc.host.enable;
  needsGivcMount = givcEnabled && !givcHostEnabled;
  producers = lib.remove config.networking.hostName (builtins.attrNames config.ghaf.networking.hosts);
  unit = "ghaf-journal-receiver";
  logDirectory = "/var/log/ghaf-journal";
  routeDirectory = "/run/ghaf-journal-sources";
  remote = lib.getExe pkgs.ghaf-journal-remote;
  budget = ''
    budget=$(numfmt --from=iec ${lib.escapeShellArg config.ghaf.logging.journalRetention.maxDiskUsage})
    budget=$((budget / ${toString (builtins.length producers)}))
  '';
  maintenance = pkgs.writeShellApplication {
    name = "maintain-journal-receivers";
    runtimeInputs = [ pkgs.coreutils ];
    text = budget + ''
      for source in ${lib.concatStringsSep " " producers}; do
        directory=${logDirectory}/"$source"
        if [[ "$1" == prepare ]]; then
          # Repair unclean journals at their real paths before following the read-only routing links.
          ${remote} --split-mode=none --max-use="$budget" --max-file-size="$((budget / 4))" \
            --output="$directory/remote.journal" /dev/null
        fi
        ${config.systemd.package}/bin/journalctl --quiet --directory="$directory" --vacuum-size="$budget"
      done
    '';
  };
  receiver = pkgs.writeShellApplication {
    name = "start-journal-receiver";
    runtimeInputs = [ pkgs.coreutils ];
    text = budget + ''
      exec ${remote} --listen-https=0.0.0.0:${toString config.ghaf.logging.listener.port} \
        --split-mode=host --output=${routeDirectory} \
        --max-use="$budget" --max-file-size="$((budget / 4))" \
        --key="$CREDENTIALS_DIRECTORY/key" --cert="$CREDENTIALS_DIRECTORY/cert" \
        --trust="$CREDENTIALS_DIRECTORY/ca"
    '';
  };
  tlsPolicy = pkgs.writeText "journal-receiver-tls.conf" ''
    [overrides]
    disabled-version = tls1.0
    disabled-version = tls1.1
    disabled-version = ssl3.0
  '';
  hardening = {
    User = unit;
    Group = "systemd-journal";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ logDirectory ];
    ProtectHome = true;
    PrivateDevices = true;
    PrivateTmp = true;
    CapabilityBoundingSet = "";
    UMask = "0027";
  };

in
{
  _file = ./journal-server.nix;

  imports = [
    (lib.mkRemovedOptionModule [
      "ghaf"
      "logging"
      "journalServer"
      "tls"
      "terminator"
      "backendPort"
    ] "Journal ingestion now uses a single authenticated TLS receiver.")
  ];

  options.ghaf.logging.journalServer = {
    enable = mkEnableOption "Logs aggregator server";

    tls = {
      caFile = mkOption {
        type = types.nullOr types.path;
        default = "/etc/givc/ca-cert.pem";
        description = "Required CA bundle for verifying journal sender certificates.";
      };
      certFile = mkOption {
        type = types.nullOr types.path;
        default = "/etc/givc/cert.pem";
        description = "Receiver certificate (PEM) used for mTLS.";
      };
      keyFile = mkOption {
        type = types.nullOr types.path;
        default = "/etc/givc/key.pem";
        description = "Receiver private key (PEM) used for mTLS.";
      };

      terminator = {
        verifyClients = mkOption {
          type = types.bool;
          default = true;
          description = "Require client certificates (mTLS).";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.tls.certFile != null) && (cfg.tls.keyFile != null);
        message = "Please set ghaf.logging.journalServer.tls.certFile and tls.keyFile.";
      }
      {
        assertion = cfg.tls.terminator.verifyClients && cfg.tls.caFile != null;
        message = "Journal ingestion requires client certificate verification and a trusted CA.";
      }
      {
        assertion =
          producers != [ ] && lib.all (name: builtins.match "[a-z0-9][a-z0-9-]{0,62}" name != null) producers;
        message = "Journal ingestion requires known producers with lowercase DNS identities.";
      }
    ];

    services.journald.remote.enable = lib.mkForce false;
    users.users.${unit} = {
      isSystemUser = true;
      group = "systemd-journal";
    };
    systemd.services.${unit} = {
      description = "Native journal receiver with authenticated VM sources";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-tmpfiles-setup.service"
      ]
      ++ lib.optionals givcHostEnabled [ "givc-key-setup.service" ];
      unitConfig.RequiresMountsFor = [ logDirectory ] ++ lib.optional needsGivcMount "/etc/givc";
      environment = {
        GNUTLS_SYSTEM_PRIORITY_FILE = tlsPolicy;
        GNUTLS_SYSTEM_PRIORITY_FAIL_ON_INVALID = "1";
      };
      serviceConfig = hardening // {
        LoadCredential = [
          "cert:${cfg.tls.certFile}"
          "key:${cfg.tls.keyFile}"
          "ca:${cfg.tls.caFile}"
        ];
        ExecStartPre = [ "${lib.getExe maintenance} prepare" ];
        ExecStart = lib.getExe receiver;
        Restart = "on-failure";
        ReadOnlyPaths = [ routeDirectory ];
      };
    };
    # The shared receiver's built-in vacuum scans the routing directory, not the per-VM directories.
    systemd.services.ghaf-journal-vacuum = {
      description = "Apply per-VM journal retention limits";
      after = [ "${unit}.service" ];
      unitConfig = {
        RequiresMountsFor = [ logDirectory ];
        StartLimitIntervalSec = 0;
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe maintenance} vacuum";
      };
    };
    systemd.paths.ghaf-journal-vacuum = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = map (name: "${logDirectory}/${name}") producers;
        TriggerLimitIntervalSec = 0;
      };
    };
    systemd.timers.ghaf-journal-vacuum = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
    systemd.tmpfiles.rules = [
      "d ${logDirectory} 0750 root systemd-journal -"
      "d ${routeDirectory} 0755 root root -"
    ]
    ++ lib.concatMap (name: [
      "d ${logDirectory}/${name} 2750 ${unit} systemd-journal -"
      "L+ ${routeDirectory}/remote-CN=${name}.journal - - - - ${logDirectory}/${name}/remote.journal"
    ]) producers;

    ghaf.storagevm = lib.optionalAttrs (options ? ghaf.storagevm.directories) {
      directories = lib.mkIf config.ghaf.storagevm.enable [ logDirectory ];
    };

    networking.firewall.allowedTCPPorts = [ config.ghaf.logging.listener.port ];

  };
}
