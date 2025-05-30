# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  coreutils,
  util-linux,
  writeShellApplication,
  zstd,
}:
writeShellApplication {
  name = "flash-script";
  runtimeInputs = [
    coreutils
    util-linux
    zstd
  ];
  text = builtins.readFile ./flash.sh;
  meta = {
    description = "Flashingscript for the Ghaf project";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
