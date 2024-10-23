# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  fetchFromGitHub,
  lib,
}:
let
  ldpiSrc = fetchFromGitHub {
    owner = "tiiuae";
    repo = "srta-ldpi";
    rev = "ghaf";
    sha256 = "sha256-Mc0liLKuflJ9lHkK2G9QHneKrWNUHZsYeB2btoHntUA="; 
  };
in

pkgs.python311Packages.buildPythonApplication rec {
  pname = "srta-ldpi";
  version = "1.0";
  src = ldpiSrc;

  propagatedBuildInputs = with pkgs.python311Packages; [
    numpy
    pandas
    scipy
    scikit-learn
    torch-bin
    matplotlib
    dpkt
    tqdm
    cycler
    netifaces
    systemd
    joblib
    threadpoolctl
    typing-extensions
    (import ./custom_pypcap.nix {
      inherit lib fetchFromGitHub libpcap;
      inherit buildPythonPackage dpkt pytestCheckHook;
    })
  ];

  doCheck = false;

  meta = with lib; {
    description = "SRTA LDPI for Ghaf";
    homepage = "https://github.com/everton-dematos/srta-ldpi";
  };
}