# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.security.spiffe.envoy;
  agentCfg = config.ghaf.security.spiffe.agent;

  spiffeTrustDomainId = "spiffe://${agentCfg.trustDomain}";
  defaultSpiffeId =
    # A sensible default identity for "envoy proxy in this VM".
    # You will still need to REGISTER this SPIFFE ID in SPIRE server entries
    # (selector(s) must match the Envoy process identity/attestation).
    "${spiffeTrustDomainId}/envoy";

  # If you have a Ghaf VM hostname setter, use it; otherwise fall back to networking.hostName.
  vmName = config.ghaf.identity.vmHostNameSetter.hostName or config.networking.hostName or "vm";

  # Perf logger (process RSS + systemd cgroup memory + CPU%) for Envoy (testing only)
  envoyPerfLogger = pkgs.writeShellApplication {
    name = "envoy-perf-log";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.gawk
      pkgs.systemd
    ];
    text = ''
      unit="envoy.service"
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

      # Wait until envoy is up (best-effort, bounded)
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

        echo "$ts,$iso,envoy,$pid,$cpu,$rss_bytes,$rss_mib,$cg_cur,$cg_cur_mib,$cg_peak,$cg_peak_mib" >> "$out"

        sleep "$interval"
      done
    '';
  };
in
{
  _file = ./envoy.nix;

  options.ghaf.security.spiffe.envoy = {
    enable = lib.mkEnableOption "Envoy proxy using SPIRE Agent SDS (via Workload API socket)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.envoy-bin;
      description = "Envoy package to run.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Envoy log level (trace|debug|info|warning|error|critical|off).";
    };

    # REQUIRED for SDS (Envoy error if missing)
    serviceNode = lib.mkOption {
      type = lib.types.str;
      default = vmName;
      description = "Envoy node.id (required when using SDS).";
    };

    # REQUIRED for SDS (Envoy error if missing)
    serviceCluster = lib.mkOption {
      type = lib.types.str;
      default = "ghaf";
      description = "Envoy node.cluster (required when using SDS).";
    };

    adminAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Envoy admin bind address.";
    };

    adminPort = lib.mkOption {
      type = lib.types.port;
      default = 9901;
      description = "Envoy admin port.";
    };

    listenerAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Inbound listener bind address.";
    };

    listenerPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Inbound listener port (mTLS).";
    };

    # The SPIFFE ID that Envoy requests its SVID for (via SDS secret name).
    spiffeId = lib.mkOption {
      type = lib.types.str;
      default = defaultSpiffeId;
      description = ''
        SPIFFE ID (X.509-SVID) Envoy will request from SPIRE over SDS.
        You must register this ID in SPIRE server with selectors that match Envoy.
      '';
    };

    # Optional: enforce client SPIFFE IDs at TLS layer (URI SAN exact match list).
    allowedClientSpiffeIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        If non-empty, Envoy will require the peer certificate URI SAN to match one
        of these SPIFFE IDs (exact match). If empty, Envoy only validates chain
        against the trust bundle (no peer ID restriction at TLS layer).
      '';
    };

    # --- PERF (testing only) ---
    perf = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Envoy perf logging since boot (testing only).";
      };

      durationSec = lib.mkOption {
        type = lib.types.int;
        default = 600; # 10 min
        description = "How long to log (seconds).";
      };

      intervalSec = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Sampling interval (seconds).";
      };

      outPath = lib.mkOption {
        type = lib.types.str;
        default = "/tmp/envoy-perf.csv";
        description = "CSV output path for Envoy perf logging.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = agentCfg.enable;
        message = "ghaf.security.spiffe.envoy.enable requires ghaf.security.spiffe.agent.enable = true (Envoy SDS uses the agent Workload API socket).";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    users.groups.envoy = { };
    users.users.envoy = {
      isSystemUser = true;
      group = "envoy";
      extraGroups = [ agentCfg.workloadApiGroup ];
    };

    environment.etc."envoy/envoy.yaml".text =
      let
        matchSansYaml =
          if cfg.allowedClientSpiffeIds == [ ] then
            ""
          else
            ''
              match_subject_alt_names:
            ''
            + (lib.concatStringsSep "\n" (
              map (id: ''
                - exact: "${id}"
              '') cfg.allowedClientSpiffeIds
            ));
      in
      ''
        node:
          id: "${cfg.serviceNode}"
          cluster: "${cfg.serviceCluster}"

        static_resources:
          clusters:
            - name: spire_agent
              connect_timeout: 0.25s
              http2_protocol_options: {}
              load_assignment:
                cluster_name: spire_agent
                endpoints:
                  - lb_endpoints:
                      - endpoint:
                          address:
                            pipe:
                              path: "${agentCfg.socketPath}"

          listeners:
            - name: inbound_mtls
              address:
                socket_address:
                  address: "${cfg.listenerAddress}"
                  port_value: ${toString cfg.listenerPort}

              filter_chains:
                - transport_socket:
                    name: envoy.transport_sockets.tls
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
                      common_tls_context:
                        tls_certificate_sds_secret_configs:
                          - name: "${cfg.spiffeId}"
                            sds_config:
                              api_config_source:
                                api_type: GRPC
                                grpc_services:
                                  - envoy_grpc:
                                      cluster_name: spire_agent

                        validation_context_sds_secret_config:
                          name: "${spiffeTrustDomainId}"
                          sds_config:
                            api_config_source:
                              api_type: GRPC
                              grpc_services:
                                - envoy_grpc:
                                    cluster_name: spire_agent
                      ${matchSansYaml}

                      require_client_certificate: true

                  filters:
                    - name: envoy.filters.network.http_connection_manager
                      typed_config:
                        "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                        stat_prefix: inbound_hcm
                        route_config:
                          name: local_route
                          virtual_hosts:
                            - name: local_service
                              domains: [ "*" ]
                              routes:
                                - match:
                                    prefix: "/"
                                  direct_response:
                                    status: 200
                                    body:
                                      inline_string: "envoy up (mTLS via SPIRE SDS)\n"
                        http_filters:
                          - name: envoy.filters.http.router
                            typed_config:
                              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

        admin:
          access_log_path: /var/log/envoy/admin_access.log
          address:
            socket_address:
              address: "${cfg.adminAddress}"
              port_value: ${toString cfg.adminPort}
      '';

    systemd.tmpfiles.rules = [
      "d /var/log/envoy 0750 envoy envoy - -"
    ];

    systemd.services.envoy = {
      description = "Envoy proxy (SDS via SPIRE Agent Workload API)";
      wantedBy = [ "multi-user.target" ];

      requires = [
        "spire-agent.service"
        "network-online.target"
      ];
      after = [
        "spire-agent.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        User = "envoy";
        Group = "envoy";

        ExecStart = "${cfg.package}/bin/envoy --config-path /etc/envoy/envoy.yaml --log-level ${cfg.logLevel}";

        Restart = "on-failure";
        RestartSec = "2s";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;

        ReadOnlyPaths = [
          "/etc/envoy/envoy.yaml"
        ];

        ReadWritePaths = [
          "/var/log/envoy"
          "/run/spire"
        ];
      };
    };

    # --- ENVOY PERF LOGGER SERVICE (runs once since boot, after envoy is up) ---
    systemd.services.envoy-perf = lib.mkIf cfg.perf.enable {
      description = "Envoy perf logger (testing only)";
      wantedBy = [ "multi-user.target" ];

      after = [ "envoy.service" ];
      wants = [ "envoy.service" ];
      requires = [ "envoy.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";

        # IMPORTANT: don't use PrivateTmp here, otherwise /tmp becomes private to the unit
        PrivateTmp = false;

        ExecStart = lib.getExe envoyPerfLogger;
      };
    };
  };
}
