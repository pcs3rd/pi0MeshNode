# meshtasticd (Linux-native Meshtastic) from nixpkgs' services.meshtasticd.
#
# Defaults: Elecrow MeshStick (CH341 USB-to-SPI + SX1262) as the radio, and the Pi's
# I2C bus (/dev/i2c-1 on the 40-pin header) for sensors, which meshtasticd auto-detects.
# A Heltec T114 running the t114-ch341 firmware (github.com/pcs3rd/t114-ch341) is the
# "t114-ch341" preset. A serial GPS on the header UART (pins 8/10) is on by default too, read
# directly by meshtasticd or through gpsd (which can also discipline the clock via chrony).
# Every value is mkDefault, so hosts/default.nix can override any of them.
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
    web = {
      enable = lib.mkEnableOption "the Meshtastic web client served by meshtasticd (HTTPS)" // { default = true; };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9443;
        description = ''
          HTTPS port of the web client. Like the 4403 API it is reachable only over Tailscale:
          the firewall trusts tailscale0 (and loopback, which the Pi 0's userspace tailscaled
          uses) and doesn't open either port on Ethernet/Wi-Fi.
        '';
      };
    };
    gps = {
      enable = lib.mkEnableOption "a serial GPS on the header UART (GPIO14 TXD / GPIO15 RXD)" // { default = true; };
      mode = lib.mkOption {
        type = lib.types.enum [ "serial" "gpsd" ];
        default = "serial";
        description = ''
          "serial": meshtasticd reads the GPS itself (GPS.SerialPath) - least RAM and closure.
          "gpsd": gpsd owns the GPS, meshtasticd reads it from gpsd (GPS.GpsdHost), and chrony
          uses it to set the clock. Worth it on off-grid nodes: the Pi has no RTC.
        '';
      };
      device = lib.mkOption {
        type = lib.types.str;
        default = "/dev/ttyAMA0";
        description = ''
          Serial device for the GPS. With disableBluetooth (default) the full UART is on pins
          8/10 on every board, so it is /dev/ttyAMA0 everywhere. Without it, boards with
          Bluetooth (Zero W, Zero 2 W, 3, 4) have the mini UART there: /dev/ttyS0.
        '';
      };
      disableBluetooth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add dtoverlay=disable-bt so the full PL011 UART (ttyAMA0) is on the header. Wi-Fi is unaffected.";
      };
      ppsGpio = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        example = 18;
        description = ''
          gpsd mode only: BCM GPIO number wired to the GPS module's PPS output. Adds
          dtoverlay=pps-gpio and has chrony lock to it for sub-millisecond time.
        '';
      };
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

    (lib.mkIf cfg.web.enable {
      services.meshtasticd.settings.Webserver = {
        Port = lib.mkDefault cfg.web.port;
        # Static files, architecture-independent: take the build machine's copy so the Pi 0
        # cross build doesn't have to cross-build a pnpm/vite project.
        RootPath = lib.mkDefault "${pkgs.buildPackages.meshtastic-web}";
        # meshtasticd generates a self-signed cert if these don't exist. Keep it on STATE (its
        # dataDir is persisted) instead of the tmpfs /etc, so it survives reboots and OTAs.
        SSLKey = lib.mkDefault "${svc.dataDir}/ssl/private_key.pem";
        SSLCert = lib.mkDefault "${svc.dataDir}/ssl/certificate.pem";
      };
      systemd.tmpfiles.rules = [ "d ${svc.dataDir}/ssl 0700 ${svc.user} ${svc.group} -" ];
      # No firewall opening on purpose: tailnet-only (see the web.port description).
    })

    (lib.mkIf cfg.gps.enable {
      # The GPS uses the header UART, so the kernel console and serial getty move off it.
      meshnode.rpi.serialConsole = lib.mkDefault false;
      meshnode.rpi.extraConfig = lib.mkIf cfg.gps.disableBluetooth ''
        dtoverlay=disable-bt
      '';
    })

    (lib.mkIf (cfg.gps.enable && cfg.gps.mode == "serial") {
      services.meshtasticd.settings.GPS.SerialPath = lib.mkDefault cfg.gps.device;
      users.users.${svc.user}.extraGroups = [ "dialout" ]; # /dev/ttyAMA0 is root:dialout 0660
    })

    (lib.mkIf (cfg.gps.enable && cfg.gps.mode == "gpsd") {
      services.gpsd = {
        enable = true;
        devices = [ cfg.gps.device ];
        nowait = true;   # keep reading (and feeding chrony) with no clients connected
        readonly = true; # never reconfigure the module
      };
      services.meshtasticd.settings.GPS = {
        GpsdHost = lib.mkDefault "localhost";
        GpsdPort = lib.mkDefault config.services.gpsd.port;
      };
      systemd.services.meshtasticd = {
        wants = [ "gpsd.service" ];
        after = [ "gpsd.service" ];
      };

      # gpsd publishes GPS time in NTP shared memory segment 0; chrony reads it. Network NTP
      # servers stay as a fallback for nodes that are online.
      services.chrony = {
        enable = true;
        extraConfig = ''
          # The Pi has no RTC: step the clock whenever it is far off, not just at startup.
          makestep 1 -1
          refclock SHM 0 refid GPS precision 1e-1 offset 0.0 delay 0.2${lib.optionalString (cfg.gps.ppsGpio != null) " noselect"}
          ${lib.optionalString (cfg.gps.ppsGpio != null) "refclock PPS /dev/pps0 lock GPS refid PPS precision 1e-7"}
        '';
      };
      meshnode.state.directories = [ "/var/lib/chrony" ];
      meshnode.rpi.extraConfig = lib.mkIf (cfg.gps.ppsGpio != null) ''
        dtoverlay=pps-gpio,gpiopin=${toString cfg.gps.ppsGpio}
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
