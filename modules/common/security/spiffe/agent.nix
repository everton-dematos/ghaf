# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.security.spiffe.agent;

  # Perf logger (process RSS + systemd cgroup memory + CPU%) for 15min window
  spireAgentPerfLogger = pkgs.writeShellApplication {
    name = "spire-agent-perf-log";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.gawk
      pkgs.systemd
    ];
    text = ''
      unit="spire-agent.service"
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

      # Wait until spire-agent is up (best-effort, bounded)
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

        # CPU% (instantaneous)
        cpu="0"
        if [ "$pid" != "0" ] && [ -r "/proc/$pid/stat" ]; then
          cpu="$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)"
          cpu="''${cpu:-0}"
          case "$cpu" in
            (""|*[!0-9.]* ) cpu=0 ;;
          esac
        fi

        # Process RSS (VmRSS)
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

        # Cgroup memory (systemd) - may return "[not set]" or empty
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

        echo "$ts,$iso,spire-agent,$pid,$cpu,$rss_bytes,$rss_mib,$cg_cur,$cg_cur_mib,$cg_peak,$cg_peak_mib" >> "$out"

        sleep "$interval"
      done
    '';
  };

  # Load generator: burst fetch x509/jwt every minute for 30min (testing only)
  spireAgentLoadGen = pkgs.writeShellApplication {
    name = "spire-agent-loadgen";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.spire-agent # provides `spire-agent` binary (matches your ExecStart usage)
    ];
    text = ''
      unit="spire-agent.service"
      socket="${cfg.socketPath}"
      audience="${cfg.loadgen.audience}"
      duration="${toString cfg.loadgen.durationSec}"
      period="${toString cfg.loadgen.periodSec}"
      burst="${toString cfg.loadgen.burstCount}"
      out="${cfg.loadgen.outPath}"

      mkdir -p "$(dirname "$out")" || true

      # Wait until spire-agent is up (best-effort, bounded)
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

      echo "[$(date -Is)] spire-agent-loadgen: starting (duration=''${duration}s, period=''${period}s, burst=''${burst})" >> "$out"

      end=$(( $(date +%s) + duration ))

      while [ "$(date +%s)" -lt "$end" ]; do
        start_ts="$(date +%s)"
        iso="$(date -Is)"

        # Burst: run both commands `burst` times
        j=1
        while [ "$j" -le "$burst" ]; do
          (
            spire-agent api fetch x509 -socketPath "$socket" >/dev/null 2>&1 || true
            spire-agent api fetch jwt  -socketPath "$socket" -audience "$audience" >/dev/null 2>&1 || true
          ) &
          j=$(( j + 1 ))
        done
        wait

        echo "[$iso] burst_done burst=''${burst}" >> "$out"

        # Sleep until next minute boundary (best-effort)
        now="$(date +%s)"
        elapsed=$(( now - start_ts ))
        if [ "$elapsed" -lt "$period" ]; then
          sleep $(( period - elapsed ))
        fi
      done

      echo "[$(date -Is)] spire-agent-loadgen: done" >> "$out"
    '';
  };
in
{
  _file = ./agent.nix;

  options.ghaf.security.spiffe.agent = {
    enable = lib.mkEnableOption "SPIRE agent";

    trustDomain = lib.mkOption {
      type = lib.types.str;
      default = "ghaf.internal";
      description = "SPIFFE trust domain expected from the server";
    };

    serverAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "SPIRE server address reachable from this VM";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "SPIRE server port";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/spire/agent";
      description = "SPIRE agent state directory";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "INFO";
      description = "SPIRE agent log level";
    };

    # Trust bundle path (bootstrap trust anchor)
    trustBundlePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/common/spire/bundle.pem";
      description = "Path to the SPIRE trust bundle PEM file (used to verify the server during bootstrap)";
    };

    # Token file generated by server and made available in this VM (virtiofs /etc/common)
    joinTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/common/spire/tokens/agent.token";
      description = "Path to a file containing a join token generated by the SPIRE server";
    };

    # This is the agent API socket path (used by spire-agent CLI and also where workloads connect)
    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/spire/agent.sock";
      description = "SPIRE Agent API socket path";
    };

    workloadApiGroup = lib.mkOption {
      type = lib.types.str;
      default = "spiffe";
      description = "Group allowed to access the SPIRE Agent API unix socket.";
    };

    workloadApiUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ghaf" ];
      description = "Users added to workloadApiGroup so they can use the SPIRE Workload API without sudo.";
    };

    # --- PERF (testing only) ---
    perf = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable SPIRE agent perf logging since boot (testing only).";
      };

      durationSec = lib.mkOption {
        type = lib.types.int;
        default = 1800; # 30 min
        description = "How long to log (seconds).";
      };

      intervalSec = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Sampling interval (seconds).";
      };

      outPath = lib.mkOption {
        type = lib.types.str;
        default = "/tmp/spire-agent-perf.csv";
        description = "CSV output path for perf logging.";
      };
    };

    loadgen = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable periodic SPIRE Workload API fetch bursts (testing only).";
      };

      durationSec = lib.mkOption {
        type = lib.types.int;
        default = 1800; # 30 min
        description = "How long to run load generation (seconds).";
      };

      periodSec = lib.mkOption {
        type = lib.types.int;
        default = 60; # every minute
        description = "Period between bursts (seconds).";
      };

      burstCount = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "How many times per period to run the x509+jwt fetch pair.";
      };

      audience = lib.mkOption {
        type = lib.types.str;
        default = "example-service";
        description = "JWT audience used for spire-agent api fetch jwt.";
      };

      outPath = lib.mkOption {
        type = lib.types.str;
        default = "/tmp/spire-agent-loadgen.log";
        description = "Output log path for load generation progress.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.spire-agent ];

    users.groups = {
      spire = { };
      "${cfg.workloadApiGroup}" = { };
    };

    users.users = {
      spire = {
        isSystemUser = true;
        group = "spire";
      };
    }
    // (lib.genAttrs cfg.workloadApiUsers (_: {
      extraGroups = lib.mkAfter [ cfg.workloadApiGroup ];
    }));

    environment.etc."spire/agent.conf".text = ''
      agent {
        data_dir = "${cfg.dataDir}"
        log_level = "${cfg.logLevel}"
        server_address = "${cfg.serverAddress}"
        server_port = ${toString cfg.serverPort}
        trust_domain = "${cfg.trustDomain}"
        trust_bundle_path = "${cfg.trustBundlePath}"
        socket_path = "${cfg.socketPath}"
        join_token_file = "${cfg.joinTokenFile}"
      }

      plugins {
        NodeAttestor "join_token" {
          plugin_data {}
        }

        WorkloadAttestor "unix" {
          plugin_data {}
        }

        KeyManager "disk" {
          plugin_data {
            directory = "${cfg.dataDir}/keys"
          }
        }
      }
    '';

    # Own /run/spire via tmpfiles (NOT RuntimeDirectory), with group access for spiffe users.
    systemd.tmpfiles.rules = [
      "d /run/spire 2750 spire ${cfg.workloadApiGroup} - -"
    ];

    systemd.services.spire-agent = {
      description = "SPIRE Agent";
      wantedBy = [ "multi-user.target" ];

      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        RequiresMountsFor = [ "/etc/common" ];
      };

      serviceConfig = {
        PermissionsStartOnly = true;

        User = "spire";
        Group = "spire";

        # ensure socket not world-accessible by default
        UMask = "007";

        # allow agent process to create files with group spiffe when directory has SGID
        SupplementaryGroups = [ cfg.workloadApiGroup ];

        ExecStart = "${pkgs.spire}/bin/spire-agent run -config /etc/spire/agent.conf";

        StateDirectory = "spire/agent";
        StateDirectoryMode = "0750";

        Restart = "on-failure";
        RestartSec = "2s";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          cfg.dataDir
          "/run/spire"
        ];
      };
    };

    # --- PERF LOGGER SERVICE (runs once since boot, after spire-agent is up) ---
    systemd.services.spire-agent-perf = lib.mkIf cfg.perf.enable {
      description = "SPIRE Agent perf logger (testing only)";
      wantedBy = [ "multi-user.target" ];

      after = [ "spire-agent.service" ];
      wants = [ "spire-agent.service" ];
      requires = [ "spire-agent.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";

        # IMPORTANT: don't use PrivateTmp here, otherwise /tmp becomes private to the unit
        PrivateTmp = false;

        ExecStart = lib.getExe spireAgentPerfLogger;
      };
    };

    systemd.services.spire-agent-loadgen = lib.mkIf cfg.loadgen.enable {
      description = "SPIRE Agent load generator (testing only)";
      wantedBy = [ "multi-user.target" ];

      after = [ "spire-agent.service" ];
      wants = [ "spire-agent.service" ];
      requires = [ "spire-agent.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";

        # avoid private /tmp if you want logs in /tmp visible outside
        PrivateTmp = false;

        ExecStart = lib.getExe spireAgentLoadGen;
      };
    };
  };
}
