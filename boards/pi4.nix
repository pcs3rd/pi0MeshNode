# Raspberry Pi 4 B / 400 / CM4 (BCM2711), 64-bit.
# The Pi 4 EEPROM bootloader also supports partition-level A/B via autoboot.txt
# (tryboot_a_b=1, boot_partition=N). This repo uses the os_prefix + tryboot.txt scheme
# instead so every board shares one update path.
{ pkgs, ... }:
{
  meshnode.board = "pi4";
  meshnode.rpi.arm64 = true;
  boot.kernelPackages = pkgs.linuxPackages_rpi4;
  meshnode.rpi.extraConfig = ''
    [pi4]
    arm_boost=1
  '';
}
