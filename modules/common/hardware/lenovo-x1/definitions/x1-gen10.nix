# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
{rev ? "uae"}: let
  option = x: y:
    if (rev == "uae")
    then x
    else y;
in {
  name = "Lenovo X1 Carbon Gen 10 (${rev})";

  mouse = option "ELAN067B:00 04F3:31F8 Mouse" "SYNA8016:00 06CB:CEB3 Mouse";
  touchpad = option "ELAN067B:00 04F3:31F8 Touchpad" "SYNA8016:00 06CB:CEB3 Touchpad";

  usb = {
    camera = {
      name = "Internal USB camera";
      vendorId = "5986";
      productId = "1178";
    };
  };

  network.pciDevices = [
    {
      # Passthrough Intel WiFi card
      path = "0000:00:14.3";
      vendorId = "8086";
      productId = "51f0";
      name = "wlp0s5f0";
    }
  ];

  gpu.pciDevices = [
    {
      # Passthrough Intel Iris GPU
      path = "0000:00:02.0";
      vendorId = "8086";
      productId = "46a6";
    }
  ];
}
