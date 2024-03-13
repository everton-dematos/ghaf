# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
{rev ? "uae"}: let
  option = x: y:
    if (rev == "uae")
    then x
    else y;
in {
  name = "Lenovo X1 Carbon Gen 11 (${rev})";

  mouse = option "ELAN067C:00 04F3:31F9 Mouse" "SYNA8016:00 06CB:CEB3 Mouse";
  touchpad = option "ELAN067C:00 04F3:31F9 Touchpad" "SYNA8016:00 06CB:CEB3 Touchpad";

  usb = {
    camera = {
      name = "Internal USB camera";
      vendorId = option "30c9" "04f2";
      productId = option "0052" "b751";
    };
  };

  network.pciDevices = [
    {
      # Passthrough Intel WiFi card
      path = "0000:00:14.3";
      vendorId = "8086";
      productId = "51f1";
      name = "wlp0s5f0";
    }
  ];

  gpu.pciDevices = [
    {
      # Passthrough Intel Iris GPU
      path = "0000:00:02.0";
      vendorId = "8086";
      productId = "a7a1";
    }
  ];
}
