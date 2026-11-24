# meshtasticd (Linux-native Meshtastic) from nixpkgs' services.meshtasticd.
#
# Defaults: Elecrow MeshStick (CH341 USB-to-SPI + SX1262) as the radio, and the Pi's
# I2C bus (/dev/i2c-1 on the 40-pin header) for sensors, which meshtasticd auto-detects.
# A Heltec T114 running the t114-ch341 firmware (github.com/pcs3rd/t114-ch341) is the
# "t114-ch341" preset. Every value is mkDefault, so hosts/default.nix can override any of them.
{ config, lib, pkgs, ... }:
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

  # From t114-ch341's lora-usb-heltec-t114.yaml. CH341 pin indexes, mapped onto the T114's
  # SX1262 by the firmware; the T114 has a 1.8 V TCXO and uses DIO2 as its RF switch.
  t114 = {
    Module = "sx1262";
    CS = 0;
    IRQ = 6;
    Reset = 2;
    Busy = 4;
    DIO2_AS_RF_SWITCH = true;
    DIO3_TCXO_VOLTAGE = 1.8;
    spidev = "ch341";
    USB_VID = 6790;  # 0x1A86
    USB_PID = 21778; # 0x5512
    SX126X_MAX_POWER = 22;
  } // lib.optionalAttrs (cfg.usbSerial != null) { USB_Serialnum = cfg.usbSerial; };

  usbRadio = cfg.radio == "meshstick-1262" || cfg.radio == "t114-ch341";
  t114ctl = pkgs.callPackage ../pkgs/t114ctl.nix { };
  ledTimeout = cfg.t114.ledsOffAfterBoot;
in
{
  options.meshnode.meshtastic = {
    enable = lib.mkEnableOption "meshtasticd" // { default = true; };
    radio = lib.mkOption {
      type = lib.types.enum [ "meshstick-1262" "t114-ch341" "custom" ];
      default = "meshstick-1262";
      description = ''
        Radio preset. "meshstick-1262" is the Elecrow MeshStick (USB). "t114-ch341" is a Heltec
        T114 running the t114-ch341 bridge firmware (USB). "custom" sets nothing: put your Lora
        settings in services.meshtasticd.settings.Lora.
      '';
    };
    usbSerial = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Pin a specific USB radio by its CH341 USB serial number (only needed with several attached).";
    };
    t114.ledsOffAfterBoot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = 30;
      description = ''
        Turn a T114 bridge's status LEDs off once the node has been up this many seconds; a
        bridge plugged in later goes dark straight away. null leaves the LEDs on. The firmware
        doesn't save brightness, so this runs again whenever the bridge re-enumerates. Applies to
        any attached T114 (matched by its USB product string), whatever the radio preset.
      '';
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
    })

    (lib.mkIf (cfg.radio == "t114-ch341") {
      services.meshtasticd.settings.Lora = lib.mapAttrs (_: lib.mkDefault) t114;
    })

    (lib.mkIf usbRadio {
      # meshtasticd talks to the CH341 (real or emulated) through libusb, as its own user.
      services.udev.extraRules = ''
        SUBSYSTEM=="usb", ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", MODE="0660", GROUP="${svc.group}"
      '';
    })

    (lib.mkIf (ledTimeout != null) {
      environment.systemPackages = [ t114ctl ];

      # Started by udev for each T114 that appears (coldplug at boot included). Sleeps until the
      # node has been up `ledsOffAfterBoot` seconds, then darkens every attached T114. A oneshot
      # without RemainAfterExit, so a later replug starts it again.
      systemd.services.meshnode-t114-leds = {
        description = "Turn off T114 radio status LEDs after boot";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "meshnode-t114-leds" ''
            up=$(${pkgs.coreutils}/bin/cut -d. -f1 /proc/uptime)
            if [ "$up" -lt ${toString ledTimeout} ]; then
              ${pkgs.coreutils}/bin/sleep $(( ${toString ledTimeout} - up ))
            fi
            # The bridge may still be enumerating right after a plug event; retry briefly.
            for _ in 1 2 3 4 5; do
              ${t114ctl}/bin/t114ctl brightness 0 && exit 0
              ${pkgs.coreutils}/bin/sleep 1
            done
            exit 1
          '';
        };
      };
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="1a86", ATTR{idProduct}=="5512", ATTR{product}=="*T114*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="meshnode-t114-leds.service"
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
