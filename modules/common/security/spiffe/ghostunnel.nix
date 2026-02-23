# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  spiffeCfg = config.ghaf.security.spiffe;
  cfg = spiffeCfg.ghostunnel;

  extraCommandArgs = lib.optionals cfg.useWorkloadApi [ "--use-workload-api" ] ++ cfg.extraArgs;
  extraArgsText = lib.concatStringsSep " " (map lib.escapeShellArg extraCommandArgs);

  startApp = pkgs.writeShellApplication {
    name = "ghostunnel";
    runtimeInputs = [ cfg.package ];
    text = ''
      exec ghostunnel \
        ${lib.escapeShellArg cfg.mode} \
        --listen ${lib.escapeShellArg cfg.listen} \
        --target ${lib.escapeShellArg cfg.target}${
          lib.optionalString (extraArgsText != "") " \\\n  ${extraArgsText}"
        }
    '';
  };

  ghostunnelPerfLogger = pkgs.writeShellApplication {
    name = "ghostunnel-perf-log";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.gawk
      pkgs.systemd
    ];
    text = ''
      unit="ghostunnel.service"
      duration="${toString cfg.perf.durationSec}"
      interval="${toString cfg.perf.intervalSec}"
      out="${cfg.perf.outPath}"

      bytes_to_mib() {
        v="''${1:-0}"
        case "$v" in
          (""|*[!0-9]*) v=0 ;;
        esac
        awk "BEGIN {printf \"%.2f\", ''${v}/1024/1024}"
      }

      mkdir -p "$(dirname "$out")" || true

      for _ in $(seq 1 120); do
        if systemctl is-active --quiet "$unit"; then
          pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
          pid="''${pid:-0}"
          case "$pid" in
            (""|*[!0-9]*) pid=0 ;;
          esac
          if [ "$pid" != "0" ]; then
            break
          fi
        fi
        sleep 1
      done

      echo "timestamp_epoch,iso_time,service,main_pid,cpu_percent,proc_rss_bytes,proc_rss_mib,cgroup_mem_current_bytes,cgroup_mem_current_mib,cgroup_mem_peak_bytes,cgroup_mem_peak_mib" > "$out"

      end=$(( $(date +%s) + duration ))

      while [ "$(date +%s)" -lt "$end" ]; do
        ts="$(date +%s)"
        iso="$(date -Is)"

        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        pid="''${pid:-0}"
        case "$pid" in
          (""|*[!0-9]*) pid=0 ;;
        esac

        cpu="0"
        if [ "$pid" != "0" ] && [ -r "/proc/$pid/stat" ]; then
          cpu="$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)"
          cpu="''${cpu:-0}"
          case "$cpu" in
            (""|*[!0-9.]*) cpu=0 ;;
          esac
        fi

        rss_bytes=0
        if [ "$pid" != "0" ] && [ -r "/proc/$pid/status" ]; then
          rss_kib="$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
          rss_kib="''${rss_kib:-0}"
          case "$rss_kib" in
            (""|*[!0-9]*) rss_kib=0 ;;
          esac
          rss_bytes=$(( rss_kib * 1024 ))
        fi
        rss_mib="$(bytes_to_mib "$rss_bytes")"

        cg_cur="$(systemctl show "$unit" -p MemoryCurrent --value 2>/dev/null || true)"
        cg_peak="$(systemctl show "$unit" -p MemoryPeak --value 2>/dev/null || true)"

        cg_cur="''${cg_cur:-0}"
        cg_peak="''${cg_peak:-0}"

        case "$cg_cur" in
          (""|*[!0-9]*) cg_cur=0 ;;
        esac
        case "$cg_peak" in
          (""|*[!0-9]*) cg_peak=0 ;;
        esac

        cg_cur_mib="$(bytes_to_mib "$cg_cur")"
        cg_peak_mib="$(bytes_to_mib "$cg_peak")"

        echo "$ts,$iso,ghostunnel,$pid,$cpu,$rss_bytes,$rss_mib,$cg_cur,$cg_cur_mib,$cg_peak,$cg_peak_mib" >> "$out"

        sleep "$interval"
      done
    '';
  };
in
{
  _file = ./ghostunnel.nix;

  options.ghaf.security.spiffe.ghostunnel = {
    enable = lib.mkEnableOption "Ghostunnel services integrated with the SPIRE agent Workload API";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ghostunnel;
      defaultText = lib.literalExpression "pkgs.ghostunnel";
      description = "Ghostunnel package to use.";
    };

    workloadApiAddress = lib.mkOption {
      type = lib.types.str;
      default = "unix://${spiffeCfg.agent.socketPath}";
      description = "SPIFFE Workload API address exported to Ghostunnel (SPIFFE_ENDPOINT_SOCKET).";
    };

    workloadApiGroup = lib.mkOption {
      type = lib.types.str;
      default = spiffeCfg.agent.workloadApiGroup;
      description = "Supplementary group added to Ghostunnel services to access the SPIRE agent socket.";
    };

    description = lib.mkOption {
      type = lib.types.str;
      default = "Ghostunnel";
      description = "Systemd service description.";
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "client"
        "server"
      ];
      default = "client";
      description = "Ghostunnel mode.";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9443";
      description = "Ghostunnel listen address, e.g. 127.0.0.1:9443.";
    };

    target = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8443";
      description = "Upstream target address, e.g. 127.0.0.1:8080.";
    };

    useWorkloadApi = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add --use-workload-api so Ghostunnel obtains identities from SPIRE.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--verify-uri"
        "spiffe://ghaf.internal/workload/backend"
      ];
      description = "Additional Ghostunnel CLI arguments.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the Ghostunnel service.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "ghaf";
      description = "User account used by the Ghostunnel service.";
    };

    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional primary group for the Ghostunnel service.";
    };

    requireSpireAgent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Require and order after the SPIRE agent service.";
    };

    networkOnline = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Order after network-online.target.";
    };

    after = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional systemd units to order after.";
    };

    wantedBy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "multi-user.target" ];
      description = "Systemd targets that should start this service.";
    };

    readWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional writable paths for systemd sandboxing.";
    };

    perf = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Ghostunnel perf logging since boot (testing only).";
      };

      durationSec = lib.mkOption {
        type = lib.types.int;
        default = 1800;
        description = "How long to log (seconds).";
      };

      intervalSec = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Sampling interval (seconds).";
      };

      outPath = lib.mkOption {
        type = lib.types.str;
        default = "/tmp/ghostunnel-perf.csv";
        description = "CSV output path for Ghostunnel perf logging.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = spiffeCfg.agent.enable;
        message = "ghaf.security.spiffe.ghostunnel.enable requires ghaf.security.spiffe.agent.enable = true";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    systemd.services.ghostunnel = {
      inherit (cfg) description;
      inherit (cfg) wantedBy;
      requires = lib.optionals cfg.requireSpireAgent [ "spire-agent.service" ];
      after =
        cfg.after
        ++ lib.optionals cfg.requireSpireAgent [ "spire-agent.service" ]
        ++ lib.optionals cfg.networkOnline [ "network-online.target" ];
      wants = lib.optionals cfg.networkOnline [ "network-online.target" ];

      environment = {
        SPIFFE_ENDPOINT_SOCKET = cfg.workloadApiAddress;
      }
      // cfg.environment;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        ExecStart = lib.getExe startApp;
        Restart = "on-failure";
        RestartSec = "2s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        SupplementaryGroups = [ cfg.workloadApiGroup ];
      }
      // lib.optionalAttrs (cfg.group != null) {
        Group = cfg.group;
      }
      // lib.optionalAttrs (cfg.readWritePaths != [ ]) {
        ReadWritePaths = cfg.readWritePaths;
      };
    };

    systemd.services.ghostunnel-perf = lib.mkIf cfg.perf.enable {
      description = "Ghostunnel perf logger (testing only)";
      wantedBy = [ "multi-user.target" ];

      after = [ "ghostunnel.service" ];
      wants = [ "ghostunnel.service" ];
      requires = [ "ghostunnel.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        PrivateTmp = false;
        ExecStart = lib.getExe ghostunnelPerfLogger;
      };
    };
  };
}
