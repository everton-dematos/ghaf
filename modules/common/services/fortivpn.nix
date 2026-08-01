# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.services.fortivpn;
  isGuiVm = config.networking.hostName == "gui-vm";
  isNetVm = config.networking.hostName == "net-vm";
  stateDirectory = "/var/lib/ghaf/fortivpn";
  guiPackage = pkgs.ghaf-fortivpn;
  servicePackage = pkgs.ghaf-fortivpn.service;
  backendPackage = pkgs.networkmanager-fortisslvpn.override { withGnome = false; };
  editorPackage = pkgs.networkmanager-fortisslvpn;
  dbusSendRules = ''
    <allow send_destination="org.ghaf.FortiVpn"
           send_interface="org.ghaf.FortiVpn1"/>
    <allow send_destination="org.ghaf.FortiVpn"
           send_interface="org.freedesktop.DBus.Introspectable"/>
    <allow send_destination="org.ghaf.FortiVpn"
           send_interface="org.freedesktop.DBus.Peer"/>
    <allow send_destination="org.ghaf.FortiVpn"
           send_interface="org.freedesktop.DBus.Properties"/>
  '';
  dbusPolicy = pkgs.writeTextDir "share/dbus-1/system.d/org.ghaf.FortiVpn.conf" ''
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
      "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <policy user="root">
        <allow own="org.ghaf.FortiVpn"/>
      </policy>
      ${lib.optionalString isGuiVm ''
        <policy context="default">
          ${dbusSendRules}
        </policy>
      ''}
      ${lib.optionalString isNetVm ''
        <policy user="${config.ghaf.users.proxyUser.name}">
          ${dbusSendRules}
        </policy>
      ''}
    </busconfig>
  '';
in
{
  _file = ./fortivpn.nix;

  options.ghaf.services.fortivpn.enable =
    lib.mkEnableOption "Fortinet SSL VPN support in the GUI VM and Net VM";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = isGuiVm || isNetVm;
            message = "ghaf.services.fortivpn is supported only in gui-vm and net-vm";
          }
          {
            assertion = config.ghaf.givc.enable;
            message = "ghaf.services.fortivpn requires GIVC for the GUI VM to Net VM control path";
          }
        ];
        services.dbus.packages = [ dbusPolicy ];
      }

      (lib.mkIf isGuiVm {
        environment.etc."NetworkManager/${editorPackage.networkManagerPlugin}".source =
          "${editorPackage}/lib/NetworkManager/${editorPackage.networkManagerPlugin}";

        environment.systemPackages = [
          editorPackage
          guiPackage
          pkgs.networkmanager
        ];

        systemd.user.services.ghaf-fortivpn-secret-agent = {
          description = "Ghaf Fortinet VPN password prompt";
          partOf = [ "cosmic-session.target" ];
          wantedBy = [ "cosmic-session.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = "${guiPackage}/bin/ghaf-fortivpn-agent";
            LimitCORE = 0;
            Restart = "on-failure";
            RestartSec = "2s";
            UMask = "0077";
          };
        };

        ghaf.graphics.launchers = [
          {
            name = "org.ghaf.FortiVpn";
            desktopName = "Fortinet VPN";
            description = "Configure Fortinet SSL VPN profiles";
            categories = [
              "Network"
              "Utility"
            ];
            icon = "network-vpn-symbolic";
            exec = "${guiPackage}/bin/ghaf-fortivpn";
            startupWMClass = "org.ghaf.FortiVpn";
            vm = "net-vm";
          }
        ];
      })

      (lib.mkIf isNetVm {
        networking.networkmanager = {
          enable = true;
          plugins = [ backendPackage ];
          unmanaged = [
            config.ghaf.networking.hosts.${config.networking.hostName}.interfaceName
          ];
        };

        environment.systemPackages = [ servicePackage ];

        ghaf = {
          storagevm.directories = lib.mkIf config.ghaf.storagevm.enable (
            [ stateDirectory ]
            ++ lib.optional (!config.ghaf.services.wifi.enable) "/etc/NetworkManager/system-connections/"
          );
          security.audit.extraRules = [
            "-w ${stateDirectory}/ -p wa -k fortivpn-certificates"
            "-w /etc/NetworkManager/system-connections/ -p wa -k networkmanager-connections"
          ];
        };

        systemd = {
          tmpfiles.rules = [ "d ${stateDirectory} 0700 root root -" ];

          services = {
            ghaf-fortivpn = {
              description = "Ghaf Fortinet VPN profile and certificate service";
              after = [
                "NetworkManager.service"
                "dbus.service"
              ];
              requires = [ "NetworkManager.service" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "simple";
                ExecStart = "${servicePackage}/bin/ghaf-fortivpn-service";
                Restart = "on-failure";
                RestartSec = "2s";
                UMask = "0077";

                CapabilityBoundingSet = "";
                LockPersonality = true;
                MemoryDenyWriteExecute = true;
                NoNewPrivileges = true;
                PrivateDevices = true;
                PrivateTmp = true;
                ProtectClock = true;
                ProtectControlGroups = true;
                ProtectHome = true;
                ProtectHostname = true;
                ProtectKernelLogs = true;
                ProtectKernelModules = true;
                ProtectKernelTunables = true;
                ProtectSystem = "strict";
                ReadWritePaths = [ stateDirectory ];
                RestrictAddressFamilies = [ "AF_UNIX" ];
                RestrictNamespaces = true;
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                SystemCallArchitectures = "native";
                SystemCallFilter = [
                  "@system-service"
                  "~@privileged"
                  "~@resources"
                ];
              };
            };

            ghaf-fortivpn-gc = {
              description = "Remove certificates for deleted Fortinet VPN profiles";
              after = [ "NetworkManager.service" ];
              requires = [ "NetworkManager.service" ];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${servicePackage}/bin/ghaf-fortivpn-service --gc";
                UMask = "0077";
                NoNewPrivileges = true;
                PrivateTmp = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                ReadWritePaths = [ stateDirectory ];
              };
            };
          };

          timers.ghaf-fortivpn-gc = {
            description = "Periodically clean deleted Fortinet VPN certificates";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "5min";
              OnUnitActiveSec = "1h";
              Persistent = true;
            };
          };
        };
      })
    ]
  );
}
