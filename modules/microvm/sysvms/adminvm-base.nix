# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Admin VM Base Module
#
# This module contains the full Admin VM configuration and can be composed using extendModules.
# It takes globalConfig and hostConfig via specialArgs for configuration.
#
# Usage in profiles:
#   lib.nixosSystem {
#     modules = [ inputs.self.nixosModules.adminvm-base ];
#     specialArgs = { inherit globalConfig hostConfig; };
#   }
#
# Then extend with:
#   base.extendModules { modules = [ ... ]; }
#
{
  config,
  lib,
  inputs,
  pkgs,
  globalConfig,
  hostConfig,
  ...
}:
let
  vmName = "admin-vm";
  timezoneEnabled = lib.ghaf.features.isEnabledFor globalConfig "timezone" vmName;

  upstreamAgent = config.ghaf.security.spire.agents.upstream;
  upstreamBootstrapService = "spire-agent-upstream-bootstrap";
  upstreamCredentialDir = "/etc/common/spire/upstream";
  upstreamBootstrapTokenPath = "${upstreamCredentialDir}/bootstrap-token";
  upstreamBundlePath = "${upstreamCredentialDir}/bundle.crt";
  upstreamKeyPath = "${upstreamCredentialDir}/agent.key";
  upstreamCertificatePath = "${upstreamCredentialDir}/agent.crt";
  upstreamSvidPathPrefix = "/spire-exchange/k8s/example-cluster/";
  upstreamBootstrapRuntimeDir = "/run/${upstreamBootstrapService}";
  spirePackage = config.ghaf.common.spire.package;

  upstreamBootstrapConfig = pkgs.writeText "spire-agent-upstream-bootstrap.conf" ''
    agent {
      data_dir = "$BOOTSTRAP_DATA_DIR"
      log_level = "${upstreamAgent.logLevel}"
      server_address = "${upstreamAgent.serverAddress}"
      server_port = ${toString upstreamAgent.serverPort}
      trust_domain = "${upstreamAgent.trustDomain}"
      trust_bundle_path = "${upstreamBundlePath}"
      socket_path = "$BOOTSTRAP_SOCKET"
      join_token_file = "$BOOTSTRAP_TOKEN_FILE"
      rebootstrap_mode = "never"
    }

    plugins {
      NodeAttestor "join_token" {
        plugin_data {}
      }
      WorkloadAttestor "unix" {
        plugin_data {}
      }
      KeyManager "memory" {
        plugin_data {}
      }
    }
  '';

  upstreamBootstrapApp = pkgs.writeShellApplication {
    name = "spire-agent-upstream-bootstrap";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.openssl
      spirePackage
    ];
    text = ''
      credential_dir=${lib.escapeShellArg upstreamCredentialDir}
      bootstrap_token=${lib.escapeShellArg upstreamBootstrapTokenPath}
      trust_bundle=${lib.escapeShellArg upstreamBundlePath}
      agent_key=${lib.escapeShellArg upstreamKeyPath}
      agent_certificate=${lib.escapeShellArg upstreamCertificatePath}
      runtime_dir=${lib.escapeShellArg upstreamBootstrapRuntimeDir}
      server_address=${lib.escapeShellArg upstreamAgent.serverAddress}
      server_port=${lib.escapeShellArg (toString upstreamAgent.serverPort)}
      expected_svid_prefix=${lib.escapeShellArg "spiffe://${upstreamAgent.trustDomain}${upstreamSvidPathPrefix}"}
      bootstrap_config=${lib.escapeShellArg upstreamBootstrapConfig}
      bootstrap_pid=""

      stop_bootstrap_agent() {
        if [ -n "$bootstrap_pid" ] && kill -0 "$bootstrap_pid" 2>/dev/null; then
          kill "$bootstrap_pid" 2>/dev/null || true
          wait "$bootstrap_pid" 2>/dev/null || true
        fi
        bootstrap_pid=""
      }

      identity_is_usable() {
        local key_path="$1"
        local certificate_path="$2"
        local bundle_path="$3"
        local check_prefix="$4"

        [ -s "$key_path" ] || return 1
        [ -s "$certificate_path" ] || return 1
        [ -s "$bundle_path" ] || return 1
        grep -q "BEGIN CERTIFICATE" "$bundle_path" || return 1
        openssl pkey -in "$key_path" -noout -check >/dev/null 2>&1 || return 1
        openssl x509 -in "$certificate_path" -noout -checkend 300 >/dev/null 2>&1 || return 1
        openssl x509 -in "$certificate_path" -noout -ext subjectAltName 2>/dev/null \
          | grep -Fq "URI:$expected_svid_prefix" || return 1
        openssl pkey -in "$key_path" -pubout -out "$check_prefix.key.pub" >/dev/null 2>&1 || return 1
        openssl x509 -in "$certificate_path" -pubkey -noout 2>/dev/null \
          | openssl pkey -pubin -out "$check_prefix.cert.pub" >/dev/null 2>&1 || return 1
        cmp -s "$check_prefix.key.pub" "$check_prefix.cert.pub"
      }

      trap stop_bootstrap_agent EXIT
      install -d -m 0750 -o root -g spire-agent-upstream "$credential_dir"

      if identity_is_usable \
        "$agent_key" "$agent_certificate" "$trust_bundle" "$runtime_dir/existing"; then
        echo "Existing upstream x509pop identity is usable; bootstrap is not required"
        exit 0
      fi

      while [ "$(cat /run/ghaf-clock-synced 2>/dev/null || true)" != "synchronised" ]; do
        echo "Waiting for the trusted clock barrier before consuming a bootstrap token"
        sleep 30
      done

      until [ -s "$trust_bundle" ] && grep -q "BEGIN CERTIFICATE" "$trust_bundle"; do
        echo "Waiting for the administrator-provided SPIRE bundle at $trust_bundle"
        sleep 30
      done

      until timeout 2 bash -c "exec 3<>\"/dev/tcp/\$1/\$2\"" _ "$server_address" "$server_port"; do
        echo "Waiting for SPIRE server connectivity at $server_address:$server_port"
        sleep 10
      done

      enrollment_attempt=0
      while ! identity_is_usable \
        "$agent_key" "$agent_certificate" "$trust_bundle" "$runtime_dir/current"; do
        until [ -s "$bootstrap_token" ]; do
          echo "Ready for enrollment; waiting for a one-time token at $bootstrap_token"
          sleep 30
        done

        enrollment_attempt=$((enrollment_attempt + 1))
        attempt_dir="$runtime_dir/attempt-$enrollment_attempt"
        install -d -m 0700 "$attempt_dir/data" "$attempt_dir/output"
        install -m 0600 "$bootstrap_token" "$attempt_dir/join-token"

        # The token is single-use. Remove the shared copy before attempting
        # attestation so a failed enrollment cannot silently reuse it.
        rm -f "$bootstrap_token"

        export BOOTSTRAP_DATA_DIR="$attempt_dir/data"
        export BOOTSTRAP_SOCKET="$attempt_dir/api.sock"
        export BOOTSTRAP_TOKEN_FILE="$attempt_dir/join-token"

        echo "Starting temporary join-token agent for x509pop enrollment"
        spire-agent run -expandEnv -config "$bootstrap_config" \
          >"$attempt_dir/agent.log" 2>&1 &
        bootstrap_pid=$!
        result_key=""
        result_certificate=""
        result_bundle=""

        for fetch_attempt in $(seq 1 60); do
          if ! kill -0 "$bootstrap_pid" 2>/dev/null; then
            echo "Temporary SPIRE agent exited during enrollment" >&2
            tail -n 100 "$attempt_dir/agent.log" >&2
            break
          fi

          output_dir="$attempt_dir/output/$fetch_attempt"
          install -d -m 0700 "$output_dir"
          if spire-agent api fetch x509 \
            -socketPath "$BOOTSTRAP_SOCKET" \
            -timeout 5s \
            -write "$output_dir" \
            >"$attempt_dir/fetch.log" 2>&1; then
            for candidate_certificate in "$output_dir"/svid.*.pem; do
              [ -e "$candidate_certificate" ] || continue
              candidate_index="''${candidate_certificate##*/svid.}"
              candidate_index="''${candidate_index%.pem}"
              candidate_key="$output_dir/svid.$candidate_index.key"
              candidate_bundle="$output_dir/bundle.$candidate_index.pem"

              if identity_is_usable \
                "$candidate_key" \
                "$candidate_certificate" \
                "$candidate_bundle" \
                "$attempt_dir/candidate-$fetch_attempt-$candidate_index"; then
                result_key="$candidate_key"
                result_certificate="$candidate_certificate"
                result_bundle="$candidate_bundle"
                break
              fi
            done

            if [ -n "$result_certificate" ]; then
              break
            fi
          fi
          sleep 1
        done

        stop_bootstrap_agent
        rm -f "$attempt_dir/join-token"

        if [ -z "$result_certificate" ]; then
          echo "Enrollment failed; ask the administrator for a new one-time token" >&2
          continue
        fi

        if ! identity_is_usable \
          "$result_key" \
          "$result_certificate" \
          "$result_bundle" \
          "$attempt_dir/fetched"; then
          echo "SPIRE returned an unusable x509pop identity; request a new token" >&2
          continue
        fi

        install -m 0600 "$result_key" "$credential_dir/.agent.key.new"
        install -m 0644 "$result_certificate" "$credential_dir/.agent.crt.new"
        install -m 0644 "$result_bundle" "$credential_dir/.bundle.crt.new"
        mv -f "$credential_dir/.agent.key.new" "$agent_key"
        mv -f "$credential_dir/.agent.crt.new" "$agent_certificate"
        mv -f "$credential_dir/.bundle.crt.new" "$trust_bundle"
      done

      echo "Installed upstream x509pop identity; permanent SPIRE agent may start"
    '';
  };
in
{
  _file = ./adminvm-base.nix;

  imports = [
    inputs.preservation.nixosModules.preservation
    inputs.self.nixosModules.givc
    inputs.self.nixosModules.hardware-x86_64-guest-kernel
    inputs.self.nixosModules.vm-modules
    inputs.self.nixosModules.profiles
  ];

  ghaf = {
    # Profiles - from globalConfig
    profiles.debug.enable = lib.mkDefault (globalConfig.debug.enable or false);

    development = {
      # NOTE: SSH port also becomes accessible on the network interface
      #       that has been passed through to VM
      ssh.daemon.enable = lib.mkDefault (globalConfig.development.ssh.daemon.enable or false);
      debug.tools.enable = lib.mkDefault (globalConfig.development.debug.tools.enable or false);
      nix-setup.enable = lib.mkDefault (globalConfig.development.nix-setup.enable or false);
    };

    # Networking hosts - from hostConfig
    # Required for vm-networking.nix to look up this VM's MAC/IP
    networking.hosts = hostConfig.networking.hosts or { };

    # Common namespace - from hostConfig
    common = hostConfig.common or { };

    # User configuration - from hostConfig
    users = {
      profile = hostConfig.users.profile or { };
      admin = hostConfig.users.admin or { };
      managed = hostConfig.users.managed or { };
    };

    # System
    type = "admin-vm";

    systemd = {
      enable = true;
      withName = "adminvm-systemd";
      withLocaled = true;
      withNss = true;
      withResolved = true;
      withPolkit = true;
      withTimesyncd = true;
      withDebug = globalConfig.debug.enable or false;
      withHardenedConfigs = true;
    };

    givc = {
      adminvm.enable = true;
      policyAdmin = {
        enable = true;
        updater.perPolicy.enable = true;
      };
    };

    # Enable dynamic hostname export for VMs
    identity.vmHostNameExport.enable = true;

    # Storage - from globalConfig
    storagevm = {
      enable = true;
      name = vmName;
      maximumSize = 20 * 1024;
      files = [
        "/etc/locale-givc.conf"
        "/etc/timezone.conf"
      ];
      directories = lib.mkIf (globalConfig.storage.encryption.enable or false) [
        "/var/lib/swtpm"
      ];
      encryption.enable = globalConfig.storage.encryption.enable or false;
    };

    # Networking
    virtualization.microvm = {
      swap.enable = true;

      vm-networking = {
        enable = true;
        inherit vmName;
      };

      tpm.passthrough = {
        # TPM passthrough is only supported on x86_64
        enable =
          (globalConfig.storage.encryption.enable or false)
          && ((globalConfig.platform.hostSystem or "") == "x86_64-linux");
        rootNVIndex = "0x81701000"; # TPM2 NV index for admin-vm LUKS key
      };

      tpm.emulated = {
        # Use emulated TPM for non-x86_64 systems when encryption is enabled
        enable =
          (globalConfig.storage.encryption.enable or false)
          && ((globalConfig.platform.hostSystem or "") != "x86_64-linux");
        name = vmName;
      };
    };

    # Logging - from globalConfig
    logging = {
      inherit (globalConfig.logging) enable listener;
      journalServer = {
        inherit (globalConfig.logging) enable;
      };

      server = {
        inherit (globalConfig.logging) enable;
        endpoint = globalConfig.logging.server.endpoint or "";

        tls = {
          serverName = "loki.ghaflogs.vedenemo.dev";
        };
      };

      recovery.enable = true;
    };

    # GIVC configuration - from globalConfig
    givc = {
      inherit (globalConfig.givc) enable;
      inherit (globalConfig.givc) debug;
    };

    # Security
    security = {
      fail2ban.enable = globalConfig.development.ssh.daemon.enable or false;
      audit.enable = lib.mkDefault (globalConfig.security.audit.enable or false);

      spire = {
        server = {
          enable = globalConfig.spire.enable or false;
          logLevel = if globalConfig.spire.debug then "DEBUG" else "INFO";
        };
        agents.downstream = {
          enable = globalConfig.spire.enable or false;
          logLevel = if globalConfig.spire.debug then "DEBUG" else "INFO";
        };

        # External SPIRE backend exposed through the Kubernetes NodePort.
        agents.upstream = {
          enable = lib.mkDefault true;

          serverAddress = "0.0.0.0";
          serverPort = 123;
          trustDomain = "test";
          logLevel = if globalConfig.spire.debug then "DEBUG" else "INFO";

          trustBundlePath = upstreamBundlePath;

          nodeAttestationMode = "x509pop";
          settings.x509pop.privateKeyPath = upstreamKeyPath;
          settings.x509pop.certificatePath = upstreamCertificatePath;
        };
      };
    };

    services.timezone.enable = lib.mkDefault (
      timezoneEnabled && globalConfig.platform.timeZone == null
    );

    # Make sure admin-vm is the last to shutdown
    # This is done to allow servicing GIVC requests until the very end
    shutdownLast = true;
  };

  time.timeZone = lib.mkIf (!timezoneEnabled) (lib.mkDefault globalConfig.platform.timeZone);

  systemd.tmpfiles.rules = lib.optionals upstreamAgent.enable [
    "d /etc/common/spire 0755 root root - -"
    "d ${upstreamCredentialDir} 0750 root spire-agent-upstream - -"
  ];

  systemd.services = lib.mkIf upstreamAgent.enable {
    ${upstreamBootstrapService} = {
      description = "Bootstrap the upstream SPIRE x509pop identity";
      before = [ "spire-agent-upstream.service" ];
      after = [
        "network.target"
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
      ];
      requires = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = [ upstreamCredentialDir ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe upstreamBootstrapApp;
        RuntimeDirectory = upstreamBootstrapService;
        RuntimeDirectoryMode = "0700";
        TimeoutStartSec = "infinity";
        UMask = "0077";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ upstreamCredentialDir ];
      };
    };

    spire-agent-upstream = {
      requires = [ "${upstreamBootstrapService}.service" ];
      after = [ "${upstreamBootstrapService}.service" ];
    };
  };

  system.stateVersion = lib.trivial.release;

  nixpkgs = {
    buildPlatform.system = globalConfig.platform.buildSystem or "x86_64-linux";
    hostPlatform.system = globalConfig.platform.hostSystem or "x86_64-linux";
  };

  microvm = {
    optimize.enable = false;
    # Sensible defaults - can be overridden via vmConfig
    vcpu = lib.mkDefault 2;
    mem = lib.mkDefault 1024;
    #TODO: Add back support cloud-hypervisor
    #the system fails to switch root to the stage2 with cloud-hypervisor
    hypervisor = "qemu";
    qemu = {
      extraArgs = [
        "-device"
        "vhost-vsock-pci,guest-cid=${toString (hostConfig.networking.thisVm.cid or 10)}"
      ];
    };

    shares = [
      {
        tag = "ghaf-common";
        source = "/persist/common";
        mountPoint = "/etc/common";
        proto = "virtiofs";
      }
    ]
    # Shared store (when not using storeOnDisk)
    ++ lib.optionals (!(globalConfig.storage.storeOnDisk.enable or false)) [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
      }
    ];

    writableStoreOverlay = lib.mkIf (
      !(globalConfig.storage.storeOnDisk.enable or false)
    ) "/nix/.rw-store";
  }
  // lib.optionalAttrs (globalConfig.storage.storeOnDisk.enable or false) (
    let
      compLevelSuffix = lib.optionalString (
        globalConfig.storage.storeOnDisk.compression.level != null
      ) ",${toString globalConfig.storage.storeOnDisk.compression.level}";
    in
    {
      storeOnDisk = true;
      storeDiskType = "erofs";
      # Defaults: -zlz4hc (all kernels), -Eztailpacking (5.16+), -Efragments (6.1+)
      # -zzstd requires Linux 6.15+ due to -E48bit (extended addressing, needed for zstd)
      # Setting storeDiskErofsFlags overrides the entire list; include defaults explicitly if needed.
      storeDiskErofsFlags = [
        "-Eztailpacking"
        "-Efragments"
        # no need to hammer all available cores
        "--workers=$(( (NIX_BUILD_CORES < 1 || NIX_BUILD_CORES > 4) ? 4 : NIX_BUILD_CORES ))"
      ]
      ++ {
        lz4hc = [ "-zlz4hc${compLevelSuffix}" ];
        zstd = [
          "-zzstd${compLevelSuffix}"
          "-E48bit"
        ];
      }
      .${globalConfig.storage.storeOnDisk.compression.algorithm};
    }
  );
}
