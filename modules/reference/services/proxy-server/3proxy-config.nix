# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ghaf.reference.services.proxy-server;
  inherit (lib) mkEnableOption mkIf;
  proxyUserName = "proxy-user";
  proxyGroupName = "proxy-admin";
  url-fetcher = pkgs.callPackage ./url_fetcher.nix { };

  msUrls = "https://endpoints.office.com/endpoints/worldwide?clientrequestid=b10c5ed1-bad1-445f-b386-b919946339a7";
  ghafUrls = "https://api.github.com/repos/tiiuae/ghaf-rt-config/contents/network/proxy/urls?ref=main";

  msAllowFilePath = "3proxy/ms_whitelist.txt";
  ghafAllowFilePath = "3proxy/ghaf_whitelist.txt";

  allowListPaths = [
    msAllowFilePath
    ghafAllowFilePath
  ];

  config_file_content = ''
    # log to stdout
    log

    nscache 65535
    nscache6 65535

    auth iponly
    #private addresses
    deny * * 0.0.0.0/8,127.0.0.0/8,10.0.0.0/8,100.64.0.0/10,172.16.0.0/12,192.168.0.0/16,::,::1,fc00::/7

    # Catch a second update if its signal arrives during a reload.
    monitor "/etc/${msAllowFilePath}"
    monitor "/etc/${ghafAllowFilePath}"
    include "/etc/${msAllowFilePath}"
    include "/etc/${ghafAllowFilePath}"

    deny * * * *
    maxconn 200

    proxy -i${cfg.internalAddress} -p${toString cfg.bindPort}

    flush

  '';
in
{
  _file = ./3proxy-config.nix;

  options.ghaf.reference.services.proxy-server = {
    enable = mkEnableOption "the proxy server module";
    internalAddress = lib.mkOption {
      type = lib.types.str;
      default = config.ghaf.networking.hosts."net-vm".ipv4;
      description = "Internal address for proxy server";
    };
    bindPort = lib.mkOption {
      type = lib.types.int;
      default = 3128;
      description = "Bind port for proxy server";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
    ];
    # Define a new group for proxy management
    users.groups.${proxyGroupName} = { }; # Create a group named proxy-admin

    # Define a new user with a specific username
    users.users.${proxyUserName} = {
      isSystemUser = true;
      description = "Proxy User for managing allowlist and services";
      # extraGroups = [ "${proxyGroupName}" ]; # Adding to 'proxy-admin' for specific access
      group = "${proxyGroupName}";
    };

    environment.systemPackages = [ url-fetcher ];
    #Firewall Settings
    ghaf.firewall.extra.input.filter = [
      # Allow incoming connections to 3proxy on port ${toString cfg.bindPort} from the client's IP
      "-p tcp -s 192.168.100.0/24 --dport ${toString cfg.bindPort} -j ${config.ghaf.firewall.chainNamePrefix}conncheck-accept"
      "-p udp -s 192.168.100.0/24 --dport ${toString cfg.bindPort} -j ${config.ghaf.firewall.chainNamePrefix}conncheck-accept"
    ];

    # Apply the allowListConfig generated from the list
    systemd = {
      tmpfiles.rules = [
        "d /etc/3proxy 2770 root ${proxyGroupName} - -"
      ]
      ++ map (path: "f /etc/${path} 0660 ${proxyUserName} ${proxyGroupName} - -") allowListPaths;

      paths."3proxy-reload" = {
        wantedBy = [ "3proxy.service" ];
        before = [ "3proxy.service" ];
        partOf = [ "3proxy.service" ];
        pathConfig.PathChanged = map (path: "/etc/${path}") allowListPaths;
      };

      services."3proxy-reload" = {
        after = [ "3proxy.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.systemd.package}/bin/systemctl reload 3proxy.service";
        };
      };

      # systemd service for fetching the file
      services.msFetchUrl = {
        description = "Fetch microsoft URLs periodically with retries if internet is available";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          ExecStart = "${url-fetcher}/bin/url-fetcher -u ${msUrls} -p /etc/${msAllowFilePath}";
          Type = "oneshot";
          # Restart policy on failure
          Restart = "on-failure"; # Restart the service if it fails
          RestartSec = "10s"; # Wait 10 seconds before restarting
          User = "${proxyUserName}";
          Group = "${proxyGroupName}";

        };
      };

      timers.msFetchUrl = {
        description = "Run msFetchUrl periodically";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          Persistent = true; # Ensures the timer runs after a system reboot
          OnCalendar = "hourly"; # Set to your desired schedule
          OnBootSec = "0";
          AccuracySec = "1us";
        };
      };
    };

    # systemd service for fetching the file
    systemd.services.ghafFetchUrl = {
      description = "Fetch ghaf related URLs periodically with retries if internet is available";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = "${url-fetcher}/bin/url-fetcher -f ${ghafUrls} -p /etc/${ghafAllowFilePath}";
        Type = "oneshot";
        # Restart policy on failure
        Restart = "on-failure"; # Restart the service if it fails
        RestartSec = "15s"; # Wait 15 seconds before restarting
        User = "${proxyUserName}";
        Group = "${proxyGroupName}";

      };
    };

    systemd.timers.ghafFetchUrl = {
      description = "Run ghafFetchUrl periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # See msFetchUrl above: [Timer] accepts no User=/Group=.
        Persistent = true; # Ensures the timer runs after a system reboot
        OnCalendar = "hourly"; # Set to your desired schedule
        OnBootSec = "0";
        AccuracySec = "1us";
      };
    };

    systemd.services."3proxy".serviceConfig = {
      # 3proxy installs its reload handler after reading the initial config.
      ExecReload = "${lib.getExe' pkgs.util-linux "kill"} --require-handler --signal USR1 $MAINPID";
      RestartSec = "5s";
      User = "${proxyUserName}";
      Group = "${proxyGroupName}";
    };

    services._3proxy = {
      enable = true;
      # Prepend the 'include' directive before the rest of the configuration
      confFile = pkgs.writeText "3proxy.conf" ''
        ${config_file_content}
      '';
    };

  };
}
