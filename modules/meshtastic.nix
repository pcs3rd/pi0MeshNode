# meshtasticd (Linux-native Meshtastic) from nixpkgs' services.meshtasticd.
#
# Defaults: Elecrow MeshStick (CH341 USB-to-SPI + SX1262) as the radio, and the Pi's
# I2C bus (/dev/i2c-1 on the 40-pin header) for sensors, which meshtasticd auto-detects.
# Every value is mkDefault, so hosts/default.nix can override any of them.
{ config, lib, ... }:
let
  cfg = config.meshnode.meshtastic;
  svc = config.services.meshtasticd;

  # Translated from meshtastic/firmware bin/config.d/lora-usb-meshstick-1262.yaml
  meshstick = {
    Module = "sx1262";
    CS = 0;
    IRQ = 6;
    Reset = 2;
    Busy = 4;
    RXen = 1;
    DIO2_AS_RF_SWITCH = true;
    DIO3_TCXO_VOLTAGE = true;
    spidev = "ch341";
    USB_VID = 6790;  # 0x1A86 (QinHeng CH341)
    USB_PID = 21778; # 0x5512
    SX126X_MAX_POWER = 22;
  } // lib.optionalAttrs (cfg.usbSerial != null) { USB_Serialnum = cfg.usbSerial; };
in
{
  options.meshnode.meshtastic = {
    enable = lib.mkEnableOption "meshtasticd" // { default = true; };
    radio = lib.mkOption {
      type = lib.types.enum [ "meshstick-1262" "custom" ];
      default = "meshstick-1262";
      description = ''
        Radio preset. "meshstick-1262" is the Elecrow MeshStick (USB). "custom" sets nothing:
        put your Lora settings in services.meshtasticd.settings.Lora.
      '';
    };
    usbSerial = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Pin a specific MeshStick by its CH341 USB serial number (only needed with several sticks attached).";
    };
    i2c = {
      enable = lib.mkEnableOption "I2C sensors (temperature, pressure, etc.) via the Pi's I2C bus" // { default = true; };
      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/i2c-1";
        description = "I2C bus meshtasticd scans for sensors. /dev/i2c-1 is GPIO2 (SDA) / GPIO3 (SCL) on the header.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.meshtasticd = {
        enable = true;
        settings = {
          Logging.LogLevel = lib.mkDefault "info";
          General = {
            MaxNodes = lib.mkDefault 200;
            MaxMessageQueue = lib.mkDefault 100;
          };
        };
      };
      services.udev.packages = [ svc.package ];

      meshnode.state.directories = [ svc.dataDir ];
      meshnode.ota.healthUnits = [ "meshtasticd.service" ];
    }

    (lib.mkIf (cfg.radio == "meshstick-1262") {
      services.meshtasticd.settings.Lora = lib.mapAttrs (_: lib.mkDefault) meshstick;
      # meshtasticd talks to the CH341 through libusb, as its own user.
      services.udev.extraRules = ''
        SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", MODE="0660", GROUP="${svc.group}"
      '';
    })

    (lib.mkIf cfg.i2c.enable {
      services.meshtasticd.settings.I2C.I2CDevice = lib.mkDefault cfg.i2c.device;
      hardware.i2c.enable = true;          # i2c-dev module + "i2c" group owning /dev/i2c-*
      boot.kernelModules = [ "i2c-dev" ];
      users.users.${svc.user}.extraGroups = [ "i2c" ];
      # dtparam=i2c_arm=on is already in common.txt (modules/rpi-boot.nix).
    })
  ]);
}
