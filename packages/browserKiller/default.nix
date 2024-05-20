{
  pkgs,
  lib,
  stdenv,
  pkg-config,
}:
stdenv.mkDerivation rec {
  pname = "browserKiller";
  version = "v0.1";

  src = ./src;
  nativeBuildInputs = [pkg-config];

  buildPhase = ''
    ${pkgs.gcc}/bin/gcc browserKiller.c -o browserKiller
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp ./browserKiller $out/bin
    cp ./*.yaml $out/bin
  '';
}
