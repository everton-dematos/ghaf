# Copyright 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.logging.server;
in
{
  options.ghaf.logging.server = {
    enable = lib.mkEnableOption "Enable logs aggregator server";
    endpoint = lib.mkOption {
      description = ''
        Assign endpoint url value to the alloy.service running in
        admin-vm. This endpoint URL will include protocol, upstream
        address along with port value.
      '';
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    identifierFilePath = lib.mkOption {
      description = ''
        This configuration option used to specify the identifier file path.
        The identifier file will be text file which have unique identification
        value per machine so that when logs will be uploaded to cloud
        we can identify its origin.
      '';
      type = lib.types.nullOr lib.types.path;
      example = "/etc/common/device-id";
      default = "/etc/common/device-id";
    };
  };

  config = lib.mkIf config.ghaf.logging.server.enable {

    assertions = [
      {
        assertion = cfg.endpoint != null;
        message = "Please provide endpoint URL for logs aggregator server, or disable the module.";
      }
      {
        assertion = cfg.identifierFilePath != null;
        message = "Please provide the identifierFilePath for logs aggregator server, or disable the module.";
      }
    ];

    # Enable a local Loki server (on port 3100)
    services.loki = {
      enable = true;
      configuration = {
        server.http_listen_address = "127.0.0.1";
        server.http_listen_port = 3100;

        ingester.lifecycler.ring.kvstore.store = "inmemory";
        ingester.lifecycler.ring.replication_factor = 1;
        ingester.lifecycler.final_sleep = "0s";
        ingester.chunk_idle_period = "5m";
        ingester.chunk_retain_period = "30s";

        schema_config.configs = [{
          from = "2020-10-15";
          store = "boltdb";
          object_store = "filesystem";
          schema = "v11";
          index.prefix = "index_";
          index.period = "24h";
        }];

        storage_config.boltdb.directory = "/tmp/loki/index";
        storage_config.filesystem.directory = "/tmp/loki/chunks";

        limits_config.retention_period = "24h";
        limits_config.allow_structured_metadata = false;

        table_manager.retention_deletes_enabled = true;
        table_manager.retention_period = "24h";
      };
    };

    environment.etc."loki/pass" = {
      text = "ghaf";
    };

    environment.etc."alloy/logs-aggregator.alloy" = {
      text = ''
        local.file "macAddress" {
          // Alloy service can read file in this specific location
          filename = "${cfg.identifierFilePath}"
        }
        discovery.relabel "adminJournal" {
          targets = []
          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "nodename"
          }
        }

        loki.process "system" {
          forward_to = [
            loki.write.remote.receiver,
            loki.write.local.receiver,
            loki.write.rustreceiver.receiver,
          ]
          stage.drop {
            expression = "(GatewayAuthenticator::login|Gateway login succeeded|csd-wrapper|nmcli)"
          }
        }

        loki.source.journal "journal" {
          path          = "/var/log/journal"
          relabel_rules = discovery.relabel.adminJournal.rules
          forward_to    = [loki.write.remote.receiver, loki.write.local.receiver, loki.write.rustreceiver.receiver,]
        }

        loki.write "remote" {
          endpoint {
            url = "${cfg.endpoint}"
            // TODO: To be replaced with stronger authentication method
            basic_auth {
              username = "ghaf"
              password_file = "/etc/loki/pass"
            }
          }
          // Write Ahead Log records incoming data and stores it on the local file
          // system in order to guarantee persistence of acknowledged data.
          wal {
            enabled = true
            max_segment_age = "240h"
            drain_timeout = "4s"
          }
          external_labels = { systemdJournalLogs = local.file.macAddress.content }
        }

        loki.write "local" {
          endpoint {
            url = "http://127.0.0.1:3100/loki/api/v1/push"
            headers = {
              "X-Scope-OrgID" = "journal",
            }
          }
          wal {
            enabled = true
            max_segment_age = "24h"
            drain_timeout = "5s"
          }
          external_labels = { source = "admin-vm" }
        }

        loki.write "rustreceiver" {
          endpoint {
            url = "http://127.0.0.1:8484/logs"
          }
          external_labels = { source = "admin-vm" }
        }

        loki.source.api "listener" {
          http {
            listen_address = "${config.ghaf.logging.listener.address}"
            listen_port = ${toString config.ghaf.logging.listener.port}
          }

          forward_to = [
            loki.process.system.receiver,
          ]
        }
      '';
      # The UNIX file mode bits
      mode = "0644";
    };

    services.alloy.enable = true;
    # If there is no internet connection , shutdown/reboot will take around 100sec
    # So, to fix that problem we need to add stop timeout
    # https://github.com/grafana/loki/issues/6533
    systemd.services.alloy.serviceConfig.TimeoutStopSec = 4;

    networking.firewall.allowedTCPPorts = [
      config.ghaf.logging.listener.port
      3100  # Allow querying the local Loki server
      8484 
    ];
  };
}
