# Raspberry Pi Zero / Zero W (BCM2835, ARMv6, 512 MB). Always cross-compiled:
# there is no binary cache for armv6l, so the first build compiles the whole closure.
{ pkgs, ... }:
{
  meshnode.board = "pi0";
  meshnode.rpi.arm64 = false;
  boot.kernelPackages = pkgs.linuxPackages_rpi1;

  zramSwap.memoryPercent = 75;
  meshnode.rootTmpfsSize = "64M";

  # Single ARMv6 core: don't decompress the store at all. The slot is bigger, but the
  # OTA download is still zstd-compressed.
  meshnode.image.slotCompression = "none";

  # Tailscale quirks (static 1.62.0 binary + userspace networking) default on for this
  # board - see modules/tailscale.nix.
}
