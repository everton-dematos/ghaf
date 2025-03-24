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
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /etc/tetragon/policies";
        ExecStart = "${pkgs.tetragon}/bin/tetragon \
          --config-dir=/etc/tetragon \
          --bpf-lib ${pkgs.tetragon}/lib/tetragon/bpf \
          --tracing-policy-dir=/etc/tetragon/policies \
          --server-address 0.0.0.0:3333";
        StartLimitBurst = 10;
        StartLimitIntervalSec = 120;
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
    '';

    # environment.etc."tetragon/policies/test-ls.yaml".text = ''
    #   apiVersion: cilium.io/v1alpha1
    #   kind: TracingPolicy
    #   metadata:
    #     name: log-ls-exec
    #   spec:
    #     kprobes:
    #     - call: "execve"
    #       syscall: true
    #       args:
    #       - index: 0
    #         type: "string"
    #       selectors:
    #       - matchBinaries:
    #           operator: "In"
    #           values:
    #             - "/usr/bin/ls"
    #             - "/bin/ls"
    #       action: "log"
    # '';
  };
}
