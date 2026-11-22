# Raspberry Pi Zero 2 W (BCM2710A1, Cortex-A53, 512 MB), 64-bit.
{ pkgs, ... }:
{
  meshnode.board = "pi02w";
  meshnode.rpi.arm64 = true;
  boot.kernelPackages = pkgs.linuxPackages_rpi3; # carries bcm2710-rpi-zero-2-w.dtb

  zramSwap.memoryPercent = 75;
  meshnode.rootTmpfsSize = "96M";
}
