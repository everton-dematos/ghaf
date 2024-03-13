# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
{
  generation,
  rev,
}: let
  hwDefinition = import (./. + "/x1-${generation}.nix") {inherit rev;};
in {
  inherit (hwDefinition) mouse;
  inherit (hwDefinition) touchpad;
  inherit (hwDefinition) usb;
  inherit (hwDefinition) network;
  inherit (hwDefinition) gpu;

  udevRules = ''
    # Laptop keyboard
    SUBSYSTEM=="input", ATTRS{name}=="AT Translated Set 2 keyboard", GROUP="kvm"
    # Laptop TrackPoint
    SUBSYSTEM=="input", ATTRS{name}=="TPPS/2 Elan TrackPoint", GROUP="kvm"
    # Lenovo X1 integrated webcam
    SUBSYSTEM=="usb", ATTR{idVendor}=="${hwDefinition.usb.camera.vendorId}", ATTR{idProduct}=="${hwDefinition.usb.camera.productId}", GROUP="kvm"
    # Laptop touchpad
    SUBSYSTEM=="input", ATTRS{name}=="${hwDefinition.mouse}", KERNEL=="event*", GROUP="kvm", SYMLINK+="mouse"
    SUBSYSTEM=="input", ATTRS{name}=="${hwDefinition.touchpad}", KERNEL=="event*", GROUP="kvm", SYMLINK+="touchpad"
  '';

  virtioInputHostEvdevs = [
    # Lenovo X1 touchpad and keyboard
    "/dev/input/by-path/platform-i8042-serio-0-event-kbd"
    "/dev/mouse"
    "/dev/touchpad"
    # Lenovo X1 trackpoint (red button/joystick)
    "/dev/input/by-path/platform-i8042-serio-1-event-mouse"
  ];
}
