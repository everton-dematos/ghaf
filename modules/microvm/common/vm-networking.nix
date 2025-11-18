# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.virtualization.microvm.vm-networking;
  inherit (lib)
    mapAttrsToList
    mkEnableOption
    mkDefault
    mkIf
    mkOption
    types
    ;
  inherit (config.ghaf.networking) hosts;
  inherit (config.ghaf.common.extraNetworking) enableStaticArp;

  isIdsvmEnabled = lib.hasAttr "ids-vm" hosts;
  netVmAddress = hosts."net-vm".ipv4;
  idsVmAddress = hosts."ids-vm".ipv4;
  gateway = if isIdsvmEnabled && (cfg.vmName != "ids-vm") then [ idsVmAddress ] else [ netVmAddress ];
in
{
  options.ghaf.virtualization.microvm.vm-networking = {
    enable = mkEnableOption "vm networking configuration";
    isGateway = mkEnableOption "gateway configuration";
    vmName = mkOption {
      description = "Name of the VM";
      type = types.nullOr types.str;
    };
  };

  config = mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.vmName != null;
        message = "Missing VM name, try setting the option";
      }
    ];

    networking = {
      hostName = cfg.vmName;
      enableIPv6 = false;
      useNetworkd = true;
      nat = {
        enable = cfg.isGateway;
        internalInterfaces = [ hosts.${cfg.vmName}.interfaceName ];
      };
      firewall.enable = mkDefault false;
    };

    boot.kernel.sysctl = {
      # ip forwarding functionality is needed for iptables
      "net.ipv4.ip_forward" = cfg.isGateway;
      # reply only if the target IP address is local address configured on the incoming interface
      "net.ipv4.conf.all.arp_ignore" = 1;
    };

    # One-shot service to set ARP sysctls on the VM interface once it exists
    systemd.services."ghaf-arp-${hosts.${cfg.vmName}.interfaceName}" = lib.mkIf enableStaticArp {
      description = "Set ARP hardening sysctls for ${hosts.${cfg.vmName}.interfaceName} in ${cfg.vmName}";
      wantedBy = [ "multi-user.target" ];

      # Run only after the VM's net device exists
      after = [ "sys-subsystem-net-devices-${hosts.${cfg.vmName}.interfaceName}.device" ];
      requires = [ "sys-subsystem-net-devices-${hosts.${cfg.vmName}.interfaceName}.device" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          (pkgs.writeShellScript "ghaf-arp-${hosts.${cfg.vmName}.interfaceName}" ''
            set -eu
            ${pkgs.procps}/sbin/sysctl -q -w \
              net.ipv4.conf.${hosts.${cfg.vmName}.interfaceName}.arp_filter=1 \
              net.ipv4.conf.${hosts.${cfg.vmName}.interfaceName}.arp_accept=0 \
              net.ipv4.conf.${hosts.${cfg.vmName}.interfaceName}.arp_announce=2 \
              net.ipv4.conf.${hosts.${cfg.vmName}.interfaceName}.arp_ignore=8
          '')
        ];
      };
    };

    ghaf.firewall = {
      allowedTCPPorts = [ 22 ]; # TODO move this to an ssh module when it is created
      allowedUDPPorts = [ 67 ];
    };

    microvm.interfaces = [
      {
        type = "tap";
        # The interface names must have maximum length of 15 characters
        id = "tap-${cfg.vmName}";
        inherit (hosts.${cfg.vmName}) mac;
      }
    ];

    systemd.network = {
      enable = true;
      links."10-${hosts.${cfg.vmName}.interfaceName}" = {
        matchConfig.PermanentMACAddress = hosts.${cfg.vmName}.mac;
        linkConfig.Name = hosts.${cfg.vmName}.interfaceName;
      };
      networks."10-${hosts.${cfg.vmName}.interfaceName}" = {
        matchConfig.MACAddress = hosts.${cfg.vmName}.mac;
        addresses = [
          { Address = "${hosts.${cfg.vmName}.ipv4}/${toString hosts.${cfg.vmName}.ipv4SubnetPrefixLength}"; }
        ];
        linkConfig = {
          RequiredForOnline = "routable";
          ActivationPolicy = "always-up";
        };
        extraConfig = lib.concatStringsSep "\n" (
          mapAttrsToList (_: entry: ''
            [Neighbor]
            Address=${entry.ipv4}
            LinkLayerAddress=${entry.mac}
          '') hosts
        );
      }
      // lib.optionalAttrs ((!cfg.isGateway) || (cfg.vmName == "ids-vm")) { inherit gateway; };
    };
  };
}
