# Copyright 2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.security.tetragon.enable = lib.mkEnableOption "Enable Tetragon eBPF security";

  config = lib.mkIf config.security.tetragon.enable {
    environment.systemPackages = [ pkgs.tetragon ];

    # Ensure /tmp/log/tetragon.log exists with correct permissions
    systemd.tmpfiles.rules = [
      "d /tmp/log 0755 root root -"
      "f /tmp/log/tetragon.log 0644 root root -"
    ];

    # Systemd service for Tetragon
    systemd.services.tetragon = {
      description = "Tetragon - eBPF Security Observability";
      wantedBy = [ "multi-user.target" ];
      after = ["network.target" "local-fs.target"];
      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        Environment = "PATH=${pkgs.tetragon}/lib/tetragon/:${pkgs.tetragon}/lib:${pkgs.tetragon}/bin";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /etc/tetragon/tetragon.tp.d";
        ExecStart = "${pkgs.tetragon}/bin/tetragon \
          --config-dir=/etc/tetragon \
          --bpf-lib ${pkgs.tetragon}/lib/tetragon/bpf \
          --tracing-policy-dir=/etc/tetragon/tetragon.tp.d \
          --server-address 0.0.0.0:3333";
        StartLimitBurst = 10;
        StartLimitIntervalSec = 120;
        ReadWritePaths = "/tmp/log/tetragon.log";
      };
    };

    networking = {
      firewall.allowedTCPPorts = [3333 2112 5555];
    };

    # Default Tetragon Configuration
    environment.etc."tetragon/config.yaml".text = ''
      log_level: info
      enable_process_events: true
      enable_syscall_events: true
      enable_file_events: true
      enable_network_events: true
      enforcement: true
      export-filename: /tmp/log/tetragon.log
      export-file-max-size-mb: 1
      export-file-rotation-interval: 10s
    '';

    # Tracing policy for logging 'ls' executions
    environment.etc."tetragon/tetragon.tp.d/test-ls.yaml" = {
      mode = "0444";
      text = ''
        apiVersion: cilium.io/v1alpha1
        kind: TracingPolicy
        metadata:
          name: log-ls-exec
        spec:
          tracepoints:
            - subsystem: "syscalls"
              event: "sys_enter_execve"
              args:
                - index: 0
                  type: "string"
              selectors:
                - matchBinaries:
                    - operator: In
                      values:
                        - "/run/current-system/sw/bin/ls"
                        - "/usr/bin/ls"
                        - "/nix/store/*/bin/ls"
                  matchActions:
                    - action: Post
      '';
    };
  };
}