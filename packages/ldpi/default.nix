# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  python311Packages,
  pkgs,
  fetchFromGitHub,
  lib,
}: 

python311Packages.buildPythonApplication rec {
  pname = "srta-ldpi";
  version = "1.0";  

  src = fetchFromGitHub {
    owner = "everton-dematos";
    repo = "srta-ldpi";
    rev = "logging_wip";
    sha256 = "sha256-87/HY5XlRN8/arn/gVBi4t3Hx6Qxfpbvtpw7F4G1blc="; 
  };

  propagatedBuildInputs = with python311Packages; [
    numpy
    pandas
    scipy
    scikit-learn
    torch
    matplotlib
    dpkt
    tqdm
    cycler
    netifaces
    systemd
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