# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  lib,
  pkgs,
  ...
}:
let
  certs = pkgs.runCommand "logseald-test-certificates" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out/admin" "$out/producer"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout ca-key.pem -out "$out/ca-cert.pem" -days 30 \
      -subj "/CN=logseald-test-ca"

    make_certificate() {
      name="$1"
      usage="$2"
      openssl req -newkey rsa:2048 -nodes \
        -keyout "$out/$name/key.pem" -out "$name.csr" -subj "/CN=$name"
      {
        echo "basicConstraints=CA:FALSE"
        echo "keyUsage=digitalSignature,keyEncipherment"
        echo "extendedKeyUsage=$usage"
        echo "subjectAltName=DNS:$name"
      } > "$name.ext"
      openssl x509 -req -in "$name.csr" -CA "$out/ca-cert.pem" \
        -CAkey ca-key.pem -CAcreateserial -out "$out/$name/cert.pem" \
        -days 30 -extfile "$name.ext"
      cp "$out/ca-cert.pem" "$out/$name/ca-cert.pem"
    }

    make_certificate admin "serverAuth,clientAuth"
    make_certificate producer "clientAuth"
  '';

  ghafOptionStubs =
    { lib, ... }:
    {
      options.ghaf = {
        type = lib.mkOption {
          type = lib.types.str;
          default = "system-vm";
        };

        givc = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          enableTls = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          host.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        };

        security.audit = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          extraRules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      };
    };

  commonNode = certificateName: {
    imports = [
      ../../modules/common/logging
      ../../modules/common/storage-persistence.nix
      ghafOptionStubs
    ];
    ghaf = {
      type = "system-vm";
      logging = {
        enable = true;
        fss.enable = false;
        recovery.enable = false;
        listener.address = "admin";
        logseald = {
          endpoint = {
            address = "admin";
            serverName = "admin";
          };
          tls = {
            caFile = "${certs}/${certificateName}/ca-cert.pem";
            certFile = "${certs}/${certificateName}/cert.pem";
            keyFile = "${certs}/${certificateName}/key.pem";
            timePolicy = "static-cert";
          };
        };
      };
      storagevm.enable = false;
    };
    networking.firewall.enable = false;
    systemd.services.givc-key-setup.enable = lib.mkForce false;
  };
in
pkgs.testers.nixosTest {
  name = "logging-logseald";

  nodes = {
    admin =
      _:
      lib.recursiveUpdate (commonNode "admin") {
        networking.hostName = "admin";
        ghaf.logging.logseald.sealer.enable = true;
      };

    producer =
      _:
      lib.recursiveUpdate (commonNode "producer") {
        networking.hostName = "producer";
        ghaf.logging.logseald.producer = {
          enable = true;
          blockRecords = 16;
          blockIntervalSeconds = 1;
          retryIntervalSeconds = 1;
          maxPendingBlocks = 64;
        };
      };
  };

  testScript = ''
    start_all()
    admin.wait_for_unit("logseald-sealer.service")
    producer.wait_for_unit("logseald-producer.service")
    admin.wait_for_open_port(59631)
    admin.succeed("runuser -u logseald-producer -- test ! -r /var/lib/logseald/sealer/sealer.key")

    producer.succeed("systemd-cat --identifier=logseald-test echo ONLINE_MARKER")
    producer.wait_until_succeeds("test -n \"$(find /var/lib/logseald/producer/sealed -name '*.json' -print -quit)\"")
    producer.succeed("logseald verify-producer --state-dir /var/lib/logseald/producer --cert ${certs}/producer/cert.pem --source producer")
    admin.succeed("logseald verify-sealer --state-dir /var/lib/logseald/sealer")

    admin.succeed("systemctl stop logseald-sealer.service")
    producer.succeed("systemd-cat --identifier=logseald-test echo OFFLINE_MARKER")
    producer.wait_until_succeeds("test -n \"$(find /var/lib/logseald/producer/queue -name '*.json' -print -quit)\"")
    producer.succeed("systemctl is-active systemd-journald.service")

    admin.succeed("systemctl start logseald-sealer.service")
    admin.wait_for_open_port(59631)
    producer.wait_until_succeeds("test -z \"$(find /var/lib/logseald/producer/queue -name '*.json' -print -quit)\"")
    producer.succeed("logseald verify-producer --state-dir /var/lib/logseald/producer --cert ${certs}/producer/cert.pem --source producer")
    admin.succeed("logseald verify-sealer --state-dir /var/lib/logseald/sealer")
  '';
}
