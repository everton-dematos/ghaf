# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  srtaSrc = pkgs.fetchFromGitHub {
    owner = "everton-dematos";
    repo = "srta-ldpi";
    rev = "master";  
    sha256 = "4WYXKjmxAtaEg/4G6CB3lUnb6zI8OzuU79DoRp2V+WM=";  
  };

  srtaPythonEnv = pkgs.python3.withPackages (ps: [
    ps.numpy
    ps.pandas
    ps.scipy
    ps.scikit-learn
    ps.torch
    ps.matplotlib
    ps.dpkt
    ps.tqdm
    ps.cycler
    ps.netifaces
    # Custom pypcap
    (import ./my_pypcap.nix {
      inherit (pkgs) lib fetchFromGitHub libpcap;
      inherit (pkgs.python3Packages) buildPythonPackage dpkt pytestCheckHook;
    })
  ]);

in
{
  options.ghaf.srta.ldpi.tools = {
    enable = lib.mkEnableOption "Secure Runtime Assurance LDPI";
  };

  config = lib.mkIf config.ghaf.srta.ldpi.tools.enable {
    environment.systemPackages = with pkgs; [
      srtaPythonEnv
      tcpdump
      hey

      # Adding the wrapper script to systemPackages
      (pkgs.writeScriptBin "srta-ldpi" ''
        #! ${pkgs.stdenv.shell}
        ${srtaPythonEnv}/bin/python ${srtaSrc}/main.py
      '')
    ];
  };
}