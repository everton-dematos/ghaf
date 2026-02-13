# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config, lib, ... }:
let
  cfg = config.ghaf.security.spiffe;
in
{
  _file = ./default.nix;

  imports = [
    ./server.nix
    ./agent.nix
  ];

  options.ghaf.security.spiffe = {
    enable = lib.mkEnableOption "SPIFFE/SPIRE support (identity control plane)";

    trustDomain = lib.mkOption {
      type = lib.types.str;
      default = "ghaf.internal";
      description = "SPIFFE trust domain used by SPIRE (spiffe://<trustDomain>/...)";
    };
  };

  config = lib.mkIf cfg.enable {
    # propagate common defaults to server/agent (can still be overridden there)
    ghaf.security.spiffe.server.trustDomain = lib.mkDefault cfg.trustDomain;
    ghaf.security.spiffe.agent.trustDomain = lib.mkDefault cfg.trustDomain;
  };
}
