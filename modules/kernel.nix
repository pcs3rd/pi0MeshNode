# Raspberry Pi vendor kernel (built with nixos-hardware's raspberry-pi/common/kernel.nix) with
# its config trimmed down to what a headless mesh node uses.
#
# nixpkgs removed linux_rpi*; nixos-hardware builds the pinned raspberrypi/linux tag with the
# vendor defconfig. It is in no binary cache, so every board builds it locally - which is why
# trimming pays: fewer drivers to compile, and a much smaller module tree in the store slot.
#
# How the trim works: nixpkgs' kernel configurePhase symlinks the generated config to .config,
# runs `make oldconfig`, then postConfigure - where nixos-hardware already edits .config. After
# that edit we switch whole subsystems off with the kernel's scripts/config, re-resolve with
# `make olddefconfig`, and fail the build if any option the image relies on was lost.
# (boot.kernelPatches can't be used: that builder replaces kernelPatches with its own list.)
{ config, lib, pkgs, nixos-hardware, ... }:
let
  cfg = config.meshnode.rpi;
  trim = cfg.kernelTrim;

  # Whole subsystems / driver families this image never uses. Unknown symbols are harmless:
  # olddefconfig drops them.
  disable = [
    # graphics & display (HDMI is off; console needs only the firmware framebuffer)
    "DRM" "FB_TFT"
    # sound
    "SOUND"
    # cameras, video, codecs, DVB/TV, IR remotes
    "MEDIA_SUPPORT" "RC_CORE" "LIRC"
    # vendor staging drivers (vc04_services audio/camera/codec/ISP, fbtft, ...)
    "STAGING"
    # radios and buses not used
    "BT" "CAN" "NFC" "HAMRADIO" "IEEE802154" "ATM" "ISDN" "INFINIBAND"
    # sensors: meshtasticd reads I2C sensors itself, from userspace
    "IIO"
    # input devices beyond keyboards/mice
    "INPUT_JOYSTICK" "INPUT_TOUCHSCREEN" "INPUT_TABLET"
    # USB serial (the CH341 radios go through libusb, the GPS through the header UART)
    "USB_SERIAL"
    # Wi-Fi: keep onboard brcmfmac and ath9k_htc (AR9271 USB), drop every other vendor/chip
    "WLAN_VENDOR_ADMTEK" "WLAN_VENDOR_ATMEL" "WLAN_VENDOR_CISCO" "WLAN_VENDOR_INTEL"
    "WLAN_VENDOR_INTERSIL" "WLAN_VENDOR_MARVELL" "WLAN_VENDOR_MEDIATEK" "WLAN_VENDOR_MICROCHIP"
    "WLAN_VENDOR_PURELIFI" "WLAN_VENDOR_QUANTENNA" "WLAN_VENDOR_RALINK" "WLAN_VENDOR_REALTEK"
    "WLAN_VENDOR_RSI" "WLAN_VENDOR_SILABS" "WLAN_VENDOR_ST" "WLAN_VENDOR_TI" "WLAN_VENDOR_ZYDAS"
    "ATH5K" "ATH9K" "ATH10K" "ATH11K" "ATH12K" "ATH6KL" "CARL9170" "AR5523" "WCN36XX" "WIL6210"
    "B43" "B43LEGACY" "BRCMSMAC" "MAC80211_HWSIM" "USB_NET_RNDIS_WLAN"
    # USB network adapters other than r8152 (Waveshare HAT), smsc95xx / lan78xx (Pi 3 / 3B+
    # Ethernet) and the generic CDC classes
    "USB_CATC" "USB_KAWETH" "USB_PEGASUS" "USB_RTL8150" "USB_NET_AX8817X" "USB_NET_AX88179_178A"
    "USB_NET_DM9601" "USB_NET_SR9700" "USB_NET_SR9800" "USB_NET_SMSC75XX" "USB_NET_GL620A"
    "USB_NET_NET1080" "USB_NET_PLUSB" "USB_NET_MCS7830" "USB_NET_CDC_SUBSET" "USB_NET_ZAURUS"
    "USB_NET_CX82310_ETH" "USB_NET_KALMIA" "USB_NET_QMI_WWAN" "USB_NET_INT51X1" "USB_IPHETH"
    "USB_SIERRA_NET" "USB_VL600" "USB_NET_CH9200" "USB_NET_AQC111" "USB_HSO" "USB_NET_HUAWEI_CDC_NCM"
    # filesystems beyond ext4 / vfat / erofs / overlay / tmpfs (+ fuse)
    "BTRFS_FS" "XFS_FS" "JFS_FS" "REISERFS_FS" "GFS2_FS" "OCFS2_FS" "NILFS2_FS" "F2FS_FS"
    "NTFS_FS" "NTFS3_FS" "EXFAT_FS" "HFS_FS" "HFSPLUS_FS" "UDF_FS" "ISO9660_FS" "SQUASHFS"
    "CIFS" "SMB_SERVER" "NFS_FS" "NFSD" "CEPH_FS" "9P_FS" "ROOT_NFS"
    # software RAID (device-mapper itself stays)
    "BLK_DEV_MD"
    # USB gadget mode (also stops the Waveshare PoE HAT's hub from enumerating), USB/IP
    "USB_GADGET" "USBIP_CORE"
    # 1-Wire sensors, TPM, raw flash, powerline, 6LoWPAN, Open vSwitch
    "W1" "TCG_TPM" "MTD" "QCA7000" "6LOWPAN" "OPENVSWITCH"
  ] ++ trim.extraDisable;

  # Options the image needs. The build fails if the trim turns off one of these that the
  # vendor config had on (options a board's config never had are not checked).
  keep = [
    "MMC_BLOCK" "USB" "USB_USBNET" "USB_RTL8152" "USB_NET_SMSC95XX" "USB_LAN78XX"
    "USB_NET_CDCETHER" "BRCMFMAC" "ATH9K_HTC" "CFG80211" "MAC80211"
    "I2C_BCM2835" "I2C_CHARDEV" "SPI_BCM2835" "SPI_SPIDEV" "PPS" "BCM2835_WDT"
    "TUN" "NF_TABLES" "ZRAM" "EROFS_FS" "EXT4_FS" "VFAT_FS" "OVERLAY_FS" "TMPFS" "FUSE_FS"
    "BLK_DEV_DM" "DEVTMPFS" "CGROUPS" "AUTOFS_FS" "FB_SIMPLE" "HWMON" "THERMAL"
  ] ++ trim.extraKeep;

  vendorKernel = pkgs.callPackage "${nixos-hardware}/raspberry-pi/common/kernel.nix" { inherit (cfg) rpiVersion; };

  trimmedKernel = vendorKernel.overrideAttrs (old: {
    postConfigure = (old.postConfigure or "") + ''
      echo "meshnode: trimming kernel config"
      cfgfile="$buildRoot/.config"
      # .config starts as a symlink into the store; nixos-hardware's sed -i may already have
      # made it a regular file.
      if [ -L "$cfgfile" ]; then cp --remove-destination "$(readlink -f "$cfgfile")" "$cfgfile"; fi
      chmod u+w "$cfgfile"
      cp "$cfgfile" "$NIX_BUILD_TOP/config.before-trim"

      for sym in ${lib.concatStringsSep " " disable}; do
        bash ./scripts/config --file "$cfgfile" --disable "$sym"
      done
      make "''${makeFlags[@]}" olddefconfig

      lost=""
      for sym in ${lib.concatStringsSep " " keep}; do
        if grep -qE "^CONFIG_$sym=(y|m)$" "$NIX_BUILD_TOP/config.before-trim" \
           && ! grep -qE "^CONFIG_$sym=(y|m)$" "$cfgfile"; then
          lost="$lost $sym"
        fi
      done
      if [ -n "$lost" ]; then
        echo "meshnode: kernel trim turned off options the image needs:$lost" >&2
        echo "meshnode: add them to meshnode.rpi.kernelTrim.extraKeep or narrow the disable list" >&2
        exit 1
      fi
      echo "meshnode: kernel trimmed: modules $(grep -c '=m$' "$NIX_BUILD_TOP/config.before-trim") -> $(grep -c '=m$' "$cfgfile"), built-in $(grep -c '=y$' "$NIX_BUILD_TOP/config.before-trim") -> $(grep -c '=y$' "$cfgfile")"
    '';
  });
in
{
  options.meshnode.rpi = {
    rpiVersion = lib.mkOption {
      type = lib.types.enum [ 1 2 3 4 5 ];
      description = ''
        Raspberry Pi SoC generation for the vendor kernel build (nixos-hardware's
        raspberry-pi/common/kernel.nix): 1 = BCM2835 (Pi 1, Zero), 3 = BCM2837 (Pi 3,
        Zero 2), 4 = BCM2711. It picks the vendor defconfig.
      '';
    };
    kernelTrim = {
      enable = lib.mkEnableOption "trimming the vendor kernel config to what a headless mesh node needs" // { default = true; };
      extraDisable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "VIRTUALIZATION" ];
        description = "More kernel config symbols (without CONFIG_) to switch off.";
      };
      extraKeep = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "USB_SERIAL_CP210X" ];
        description = ''
          More symbols the build must not lose: the build fails if the trim turns one of them off.
          It only guards; it doesn't re-enable anything. To bring back something the trim removes,
          edit the disable list in modules/kernel.nix (or set kernelTrim.enable = false).
        '';
      };
    };
  };

  config.boot.kernelPackages = lib.mkDefault
    (pkgs.linuxPackagesFor (if trim.enable then trimmedKernel else vendorKernel));
}
