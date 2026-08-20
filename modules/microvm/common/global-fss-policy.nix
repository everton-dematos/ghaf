# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  globalConfig,
  lib,
  ...
}:
let
  globalFssEnabled = globalConfig.logging.fss.enable or true;
in
{
  _file = ./global-fss-policy.nix;

  # Component-local overrides remain available while the global policy is on,
  # for example to disable FSS on an intentionally stateless VM. The global off
  # switch is forceful so one setting cannot leave an explicitly enabled VM
  # running the implementation being replaced.
  ghaf.logging.fss.enable =
    if globalFssEnabled then lib.mkDefault config.ghaf.logging.enable else lib.mkForce false;
}
