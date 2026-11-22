# Raspberry Pi 3 B / B+ / A+ (BCM2837), 64-bit.
{ pkgs, ... }:
{
  meshnode.board = "pi3";
  meshnode.rpi.arm64 = true;
  boot.kernelPackages = pkgs.linuxPackages_rpi3;
}
