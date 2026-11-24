# Small libusb tool for the Heltec T114 CH341 bridge's status LEDs (github.com/pcs3rd/t114-ch341).
# C rather than the repo's Python t114ctl.py, so the image doesn't gain a Python runtime.
{ stdenv, lib, libusb1 }:
stdenv.mkDerivation {
  pname = "t114ctl";
  version = "0.1.0";
  src = ./t114ctl;
  buildInputs = [ libusb1 ];
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o t114ctl t114ctl.c -lusb-1.0
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 t114ctl $out/bin/t114ctl
    runHook postInstall
  '';
  meta = {
    description = "Set the status LED brightness on Heltec T114 CH341 LoRa bridges";
    license = lib.licenses.mit;
    mainProgram = "t114ctl";
    platforms = lib.platforms.linux;
  };
}
