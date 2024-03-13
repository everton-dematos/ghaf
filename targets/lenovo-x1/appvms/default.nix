# Copyright 2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
{config, pkgs, ...}: let
  chromium = import ./chromium.nix {inherit config pkgs;};
  gala = import ./gala.nix {inherit pkgs;};
  zathura = import ./zathura.nix {inherit pkgs;};
in [
  chromium
  gala
  zathura
]
