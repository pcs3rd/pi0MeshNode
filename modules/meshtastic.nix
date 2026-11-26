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

  # Official prebuilt web client release. nixpkgs' meshtastic-web (2.6.7) is older than
  # meshtasticd 2.8.1, and its LoRa settings page saves a config with use_preset = false and
  # zeroed bandwidth / spread factor / coding rate, which the SX1262 rejects (RadioLib -706)
  # and meshtasticd then crashes recovering from. The release tarball also needs no JS build.
  webVersion = "2.7.2";
  webTarball = pkgs.buildPackages.fetchurl {
    url = "https://github.com/meshtastic/web/releases/download/v${webVersion}/build.tar";
    hash = "sha256-YmV7hbTCSvTUTaKTK2QUOr2/bmWnn8tR/QgB2VQGFuI=";
  };
  webRoot = pkgs.buildPackages.runCommand "meshtastic-web-${webVersion}" { } ''
    mkdir $out
    tar -xf ${webTarball} -C $out --no-same-owner
    chmod -R u+w $out
    # The release ships only pre-gzipped files; meshtasticd serves plain files.
    find $out -name '*.gz' -exec ${pkgs.buildPackages.gzip}/bin/gunzip -f {} +
  '';
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
      default = 120;
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
        default = "/dev/serial0";
        description = ''
          Serial device for the GPS. /dev/serial0 (a udev link set up in rpi-boot.nix) always
          points at the UART on pins 8/10, whichever one the firmware put there: the full
          PL011 (ttyAMA*) with disableBluetooth or on boards without Bluetooth, otherwise the
          mini UART (ttyS0), which is fine for NMEA at 9600-115200 baud.
        '';
      };
      disableBluetooth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add dtoverlay=disable-bt so the full PL011 UART, not the mini UART, is on the header (/dev/serial0). Wi-Fi is unaffected.";
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
            # meshtasticd only reads drop-in YAML files when ConfigDirectory is set (upstream's
            # config-dist.yaml sets it; the NixOS module's generated config doesn't). Point it
            # at STATE so on-node overrides work without a rebuild *and* survive reboots/OTAs.
            ConfigDirectory = lib.mkDefault "/boot/state/meshtasticd/config.d/";
          };
        };
      };
      services.udev.packages = [ svc.package ];
      systemd.tmpfiles.rules = [ "d /boot/state/meshtasticd/config.d 0755 root root -" ];

      # At boot meshtasticd raced udev: the USB radio's node wasn't yet group-writable
      # ("libusb ... errno=13", two failed starts) and the I2C bus came up empty ("No I2C
      # devices found"). Wait for the coldplug queue to drain first (capped, never fatal).
      systemd.services.meshtasticd = {
        after = [ "systemd-udev-trigger.service" ];
        serviceConfig.ExecStartPre = [ "-${config.systemd.package}/bin/udevadm settle --timeout=20" ];
      };

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
      # The in-kernel CH341 SPI driver would claim 1a86:5512 first; meshtasticd's libpinedio
      # then has to detach it on every start ("ignoring udev action unbind"). Nothing here
      # uses it, so keep it from binding at all.
      boot.blacklistedKernelModules = [ "spi_ch341" ];
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
          # Sleeps up to ledsOffAfterBoot seconds; don't rely on oneshot's default (no) timeout.
          TimeoutStartSec = ledTimeout + 60;
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
        # Official web client release, decompressed (see webRoot above).
        RootPath = lib.mkDefault "${webRoot}";
        # Self-signed cert on STATE (meshtasticd's dataDir is persisted), not the tmpfs /etc.
        SSLKey = lib.mkDefault "${svc.dataDir}/ssl/private_key.pem";
        SSLCert = lib.mkDefault "${svc.dataDir}/ssl/certificate.pem";
      };
      # Upstream's config says the cert is "generated if not present", but meshtasticd 2.8.1
      # just logs "SSL Certificate File can't be loaded or missing" and serves nothing. Make it
      # once, before meshtasticd starts (RSA for the widest TLS-library compatibility).
      systemd.services.meshtasticd-web-cert = {
        description = "Generate meshtasticd's self-signed web certificate";
        wantedBy = [ "meshtasticd.service" ];
        before = [ "meshtasticd.service" ];
        unitConfig = {
          ConditionPathExists = "!${svc.dataDir}/ssl/certificate.pem";
          RequiresMountsFor = [ svc.dataDir ];
        };
        path = [ pkgs.openssl pkgs.coreutils ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 -o ${svc.user} -g ${svc.group} ${svc.dataDir}/ssl
          openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=$(cat /proc/sys/kernel/hostname)" \
            -keyout ${svc.dataDir}/ssl/private_key.pem -out ${svc.dataDir}/ssl/certificate.pem
          chown ${svc.user}:${svc.group} ${svc.dataDir}/ssl/private_key.pem ${svc.dataDir}/ssl/certificate.pem
          chmod 0600 ${svc.dataDir}/ssl/private_key.pem
        '';
      };
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
      users.users.${svc.user}.extraGroups = [ "dialout" ]; # header UARTs are root:dialout 0660 (rpi-boot.nix udev rule)
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
