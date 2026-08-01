# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  cosmic-settings,
  gobject-introspection,
  gtk4,
  lib,
  libadwaita,
  makeWrapper,
  networkmanager,
  openssl,
  python3,
  stdenvNoCC,
  wrapGAppsHook4,
}:
let
  guiPython = python3.withPackages (ps: [
    ps.dbus-next
    ps.pygobject3
  ]);
  servicePython = python3.withPackages (ps: [ ps.dbus-next ]);
in
stdenvNoCC.mkDerivation {
  pname = "ghaf-fortivpn";
  version = "0.1.0";
  outputs = [
    "out"
    "service"
  ];
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./ghaf_fortivpn_agent.py
      ./ghaf_fortivpn_gui.py
      ./ghaf_fortivpn_service.py
    ];
  };

  nativeBuildInputs = [
    gobject-introspection
    makeWrapper
    wrapGAppsHook4
  ];
  buildInputs = [
    gtk4
    libadwaita
  ];
  postPatch = ''
    substituteInPlace ghaf_fortivpn_gui.py \
      --replace-fail '@cosmic-settings@' '${lib.getExe cosmic-settings}'

    substituteInPlace ghaf_fortivpn_service.py \
      --replace-fail '@nmcli@' '${lib.getExe' networkmanager "nmcli"}' \
      --replace-fail '@openssl@' '${lib.getExe openssl}'
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 ghaf_fortivpn_gui.py \
      "$out/share/ghaf-fortivpn/ghaf_fortivpn_gui.py"
    install -Dm644 ghaf_fortivpn_agent.py \
      "$out/share/ghaf-fortivpn/ghaf_fortivpn_agent.py"

    install -Dm644 ghaf_fortivpn_service.py \
      "$service/share/ghaf-fortivpn/ghaf_fortivpn_service.py"

    makeWrapper ${lib.getExe guiPython} "$out/bin/ghaf-fortivpn" \
      --add-flags "$out/share/ghaf-fortivpn/ghaf_fortivpn_gui.py"
    makeWrapper ${lib.getExe guiPython} "$out/bin/ghaf-fortivpn-agent" \
      --add-flags "$out/share/ghaf-fortivpn/ghaf_fortivpn_agent.py"
    makeWrapper ${lib.getExe servicePython} "$service/bin/ghaf-fortivpn-service" \
      --add-flags "$service/share/ghaf-fortivpn/ghaf_fortivpn_service.py"

    runHook postInstall
  '';

  meta = {
    description = "Fortinet SSL VPN profile editor and Net VM service for Ghaf";
    license = lib.licenses.asl20;
    mainProgram = "ghaf-fortivpn";
    platforms = lib.platforms.linux;
  };
}
