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
      after = [ "network.target" ];
      serviceConfig = {
        ExecStartPre = ''
          mkdir -p /tmp/tetragon
          mount -t bpf none /tmp/tetragon
          mkdir -p /tmp/tetragon/tetragon
          mount --bind /tmp/tetragon/tetragon /sys/fs/bpf/tetragon
          chmod 700 /tmp/tetragon/tetragon
          chown root:root /tmp/tetragon/tetragon
        '';
        ExecStart = "${pkgs.tetragon}/bin/tetragon --config=/etc/tetragon/config.yaml --bpf-lib=/tmp/tetragon";
        Restart = "always";
        RestartSec = 5;

        ProtectSystem = "false";
        ProtectHome = "false";
        CapabilityBoundingSet = "CAP_SYS_ADMIN CAP_BPF CAP_NET_ADMIN CAP_NET_RAW";
        AmbientCapabilities = "CAP_BPF CAP_SYS_ADMIN CAP_NET_ADMIN";
        SystemCallFilter = [ "@ebpf" "@privileged" ];
        SystemCallErrorNumber = "EPERM";

        MountAPIVFS = true;  
        ProtectKernelModules = false;
        ProtectKernelLogs = false;
        ProtectControlGroups = false;
        ProtectKernelTunables = false;
        ProtectProc = "noaccess";

        MountFlags = "shared";
        ReadWritePaths = [ "/sys/fs/bpf" "/sys/kernel/btf" ];
        DeviceAllow = [ "/dev/bpf rw" ];

        RestrictNamespaces = false;
        NoNewPrivileges = false;
      };
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

    # Security Policies
    environment.etc."tetragon/policies/ssh-monitoring.yaml".text = ''
      apiVersion: cilium.io/v1alpha1
      kind: TracingPolicy
      metadata:
        name: ssh-monitoring
      spec:
        kprobes:
        - call: "execve"
          syscall: true
          args:
          - index: 0
            type: "string"
          selectors:
          - matchBinaries:
            - operator: "In"
              values:
              - "/usr/sbin/sshd"
          action: "log"
    '';

    environment.etc."tetragon/policies/block-netcat.yaml".text = ''
      apiVersion: cilium.io/v1alpha1
      kind: TracingPolicy
      metadata:
        name: block-netcat
      spec:
          kprobes:
          - call: "execve"
            syscall: true
            args:
            - index: 0
              type: "string"
            selectors:
            - matchBinaries:
              - operator: "In"
                values:
                - "/usr/bin/nc"
                - "/bin/netcat"
            action: "deny"
    '';
  };
}
