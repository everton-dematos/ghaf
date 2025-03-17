# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ inputs }:
{
  config,
  lib,
  ...
}:
let
  configHost = config;
  vmName = "admin-vm";

  adminvmBaseConfiguration = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      inputs.self.nixosModules.givc
      (import ../common/vm-networking.nix {
        inherit
          config
          lib
          vmName
          ;
      })
      ../common/storagevm.nix
      (
        { lib, pkgs, ... }:
        {
          ghaf = {
            # Profiles
            profiles.debug.enable = lib.mkDefault configHost.ghaf.profiles.debug.enable;
            development = {
              # NOTE: SSH port also becomes accessible on the network interface
              #       that has been passed through to VM
              ssh.daemon.enable = lib.mkDefault configHost.ghaf.development.ssh.daemon.enable;
              debug.tools.enable = lib.mkDefault configHost.ghaf.development.debug.tools.enable;
              nix-setup.enable = lib.mkDefault configHost.ghaf.development.nix-setup.enable;
            };

            policy.opa.enable = true;

            # System
            type = "system-vm";
            systemd = {
              enable = true;
              withName = "adminvm-systemd";
              withAudit = configHost.ghaf.profiles.debug.enable;
              withNss = true;
              withResolved = true;
              withPolkit = true;
              withTimesyncd = true;
              withDebug = configHost.ghaf.profiles.debug.enable;
              withHardenedConfigs = true;
            };
            givc.adminvm.enable = true;

            # Storage
            storagevm = {
              enable = true;
              name = vmName;
              files = [
                "/etc/locale-givc.conf"
                "/etc/timezone.conf"
              ];
            };

            # Services
            logging = {
              server = {
                inherit (configHost.ghaf.logging) enable;
              };
            };
          };

          system.stateVersion = lib.trivial.release;

          nixpkgs = {
            buildPlatform.system = configHost.nixpkgs.buildPlatform.system;
            hostPlatform.system = configHost.nixpkgs.hostPlatform.system;
          };

          microvm = {
            optimize.enable = false;
            #TODO: Add back support cloud-hypervisor
            #the system fails to switch root to the stage2 with cloud-hypervisor
            hypervisor = "qemu";
            shares =
              [
                {
                  tag = "ro-store";
                  source = "/nix/store";
                  mountPoint = "/nix/.ro-store";
                  proto = "virtiofs";
                }
                {
                  tag = "ghaf-common";
                  source = "/persist/common";
                  mountPoint = "/etc/common";
                  proto = "virtiofs";
                }
              ]
              ++ lib.optionals config.ghaf.logging.enable [
                {
                  # Creating a persistent log-store which is mapped on ghaf-host
                  # This is only to preserve logs state across adminvm reboots
                  tag = "log-store";
                  source = "/persist/storagevm/admin-vm/var/lib/private/alloy";
                  mountPoint = "/var/lib/private/alloy";
                  proto = "virtiofs";
                }
              ];

            writableStoreOverlay = lib.mkIf config.ghaf.development.debug.tools.enable "/nix/.rw-store";
          };
          imports = [ ../../common ];
        }
      )
    ];
  };
  cfg = config.ghaf.virtualization.microvm.adminvm;
in
{
  options.ghaf.virtualization.microvm.adminvm = {
    enable = lib.mkEnableOption "AdminVM";

    extraModules = lib.mkOption {
      description = ''
        List of additional modules to be imported and evaluated as part of
        AdminVM's NixOS configuration.
      '';
      default = [ ];
    };
  };

    config = lib.mkIf cfg.enable (
    let
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      tetragon = pkgs.tetragon;
    in {
      microvm.vms."${vmName}" = {
        autostart = true;
        inherit (inputs) nixpkgs;
        config = adminvmBaseConfiguration // {
          imports = adminvmBaseConfiguration.imports ++ cfg.extraModules;

          environment.systemPackages = [ tetragon ];
          networking = {
            firewall.allowedTCPPorts = [3333 2112 5555];
          };

          systemd.services.tetragon = {
            enable = true;
            description = "Tetragon eBPF-based Security Observability and Runtime Enforcement";
            after = [ "network.target" "local-fs.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "simple";
              User = "root";
              Group = "root";
              Environment = "PATH=${tetragon}/lib/tetragon/:${tetragon}/lib:${tetragon}/bin";
              ExecStart = lib.mkForce "${tetragon}/bin/tetragon --bpf-lib ${tetragon}/lib/tetragon/bpf --server-address 0.0.0.0:3333";
              StartLimitBurst = 10;
              StartLimitIntervalSec = 120;
            };
          };
        };
      };
    }
  );
}
