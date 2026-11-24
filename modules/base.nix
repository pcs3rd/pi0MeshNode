# Filesystem layout, users, networking and footprint trimming shared by every board.
#
#   /               tmpfs (rebuilt every boot)
#   /nix/store      active A/B slot: a read-only EROFS image of the system closure,
#                   selected by abslot= on the kernel command line. Nothing else of
#                   Nix exists on the device: no daemon, no store DB, no /nix/var.
#   /etc            overlay of a prebuilt EROFS image (system.etc.overlay), writable layer on tmpfs
#   /boot/firmware  FIRMWARE (vfat): Pi firmware, slot_a/, slot_b/, config.txt, tryboot.txt, node/
#   /boot/state     STATE (ext4): everything that must survive reboots and OTA slot switches
#
# Factory reset: create an empty file FACTORY_RESET on the FIRMWARE partition (from any PC)
# or run `meshnode-factory-reset --force`; the initrd reformats STATE on the next boot.
{ config, lib, pkgs, utils, ... }:
let
  cfg = config.meshnode;
  stateDirs = cfg.state.directories;
  stateRoot = "/boot/state";

  # MBR disk identifier set by modules/ab-image.nix, so slot partitions have fixed
  # PARTUUIDs (<diskid>-02 / -03). EROFS images carry no per-slot label, so slots are
  # matched by partition rather than filesystem label - an OTA is a plain dd.
  diskId = config.meshnode.image.diskId;
  slotUdevRules = ''
    SUBSYSTEM=="block", IMPORT{cmdline}="abslot"
    SUBSYSTEM=="block", ENV{abslot}=="a", ENV{ID_PART_ENTRY_UUID}=="${diskId}-02", SYMLINK+="disk/by-slot/active"
    SUBSYSTEM=="block", ENV{abslot}=="b", ENV{ID_PART_ENTRY_UUID}=="${diskId}-03", SYMLINK+="disk/by-slot/active"
  '';

  mountUnit = path: "${utils.escapeSystemdPath path}.mount";
  deviceUnit = path: "${utils.escapeSystemdPath path}.device";
in
{
  options.meshnode = {
    board = lib.mkOption {
      type = lib.types.enum [ "pi0" "pi02w" "pi3" "pi4" ];
      description = "Target board; selects kernel, firmware config and OTA compatibility.";
    };
    version = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0-dev";
      description = "Release string baked into /etc/meshnode-release and OTA manifests.";
    };
    buildNumber = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Monotonic build number (the flake sets the commit time). OTA refuses bundles that are not newer.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "meshtastic";
      description = ''
        Login user (wheel, passwordless sudo). Set its password with
        users.users.<name>.hashedPassword. Not the meshtasticd daemon's own user,
        which is "meshtasticd".
      '';
    };
    sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Fleet-wide SSH public keys for the login user (per-node keys can be injected too).";
    };
    rootTmpfsSize = lib.mkOption {
      type = lib.types.str;
      default = "25%";
      description = "Size limit for the tmpfs root.";
    };
    state.directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Directories bind-mounted from ${stateRoot} so they survive reboots and slot switches.";
    };
    forbidPerl = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Fail the build if perl ends up in the system closure. Turn on once the image builds,
        to catch regressions that would bring Perl activation scripts (and boot time) back.
      '';
    };
  };

  config = {
    system.stateVersion = "26.05";

    # ---------------------------------------------------------------- filesystems
    fileSystems = lib.mkMerge [
      {
        "/" = {
          device = "none";
          fsType = "tmpfs";
          options = [ "mode=0755" "size=${cfg.rootTmpfsSize}" ];
        };
        "/nix/store" = {
          device = "/dev/disk/by-slot/active";
          fsType = "erofs";
          options = [ "ro" ];
          neededForBoot = true;
        };
        "/boot/firmware" = {
          device = "/dev/disk/by-label/FIRMWARE";
          fsType = "vfat";
          options = [ "noatime" "umask=0077" ];
          neededForBoot = true; # initrd checks it for FACTORY_RESET
        };
        ${stateRoot} = {
          device = "/dev/disk/by-label/STATE";
          fsType = "ext4";
          options = [ "noatime" ];
          neededForBoot = true;
        };
      }
      (lib.genAttrs stateDirs (d: {
        device = "${stateRoot}${d}";
        fsType = "none";
        options = [ "bind" ];
        depends = [ stateRoot ];
        neededForBoot = true;
      }))
    ];

    meshnode.state.directories = [ "/var/lib/nixos" "/var/lib/systemd" ];

    boot.initrd.supportedFilesystems = { vfat = true; ext4 = true; erofs = true; };
    boot.initrd.services.udev.rules = slotUdevRules;
    services.udev.extraRules = slotUdevRules;

    boot.initrd.systemd.extraBin."mkfs.ext4" = "${pkgs.e2fsprogs}/bin/mkfs.ext4";

    # Factory reset: reformat STATE before it is mounted if the flag file exists.
    boot.initrd.systemd.services.meshnode-factory-reset = {
      description = "Factory reset (wipe STATE) if requested";
      wantedBy = [ "initrd-fs.target" ];
      requires = [ (mountUnit "/sysroot/boot/firmware") (deviceUnit "/dev/disk/by-label/STATE") ];
      after = [ (mountUnit "/sysroot/boot/firmware") (deviceUnit "/dev/disk/by-label/STATE") ];
      before = [ (mountUnit "/sysroot${stateRoot}") ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "/sysroot/boot/firmware/FACTORY_RESET";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          "/bin/mkfs.ext4 -q -F -L STATE /dev/disk/by-label/STATE"
          "/bin/rm -f /sysroot/boot/firmware/FACTORY_RESET"
          "/bin/sync"
        ];
      };
    };

    # Bind-mount sources must exist before the binds are mounted (also after a reset).
    boot.initrd.systemd.services.meshnode-state-dirs = {
      description = "Create persistent state directories";
      wantedBy = [ "initrd-fs.target" ];
      requires = [ (mountUnit "/sysroot${stateRoot}") ];
      after = [ (mountUnit "/sysroot${stateRoot}") ];
      before = [ "initrd-fs.target" ] ++ map (d: mountUnit "/sysroot${d}") stateDirs;
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          "/bin/mkdir -p ${lib.concatMapStringsSep " " (d: "/sysroot${stateRoot}${d}") (stateDirs ++ [ "/etc" "/ssh" "/meshnode/node" "/meshnode/ota" "/var/lib/nixos/userborn" ])}"
          # Stable machine-id across reboots/slots (regenerated after a factory reset).
          "/bin/bash -c '[ -s /sysroot${stateRoot}/etc/machine-id ] || /bin/tr -d - < /proc/sys/kernel/random/uuid > /sysroot${stateRoot}/etc/machine-id'"
        ];
      };
    };

    environment.etc."machine-id".source = "${stateRoot}/etc/machine-id";

    # STATE ships small; grow it to fill the card on first boot (and after a reset).
    systemd.services.meshnode-grow-state = {
      description = "Grow STATE to fill the card";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!${stateRoot}/meshnode/.grown";
      # util-linux only: cloud-utils (growpart) drags in qemu-utils, which doesn't build for armv6l.
      path = with pkgs; [ util-linux e2fsprogs coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        src=$(findmnt -no SOURCE ${stateRoot})
        disk=/dev/$(lsblk -ndo PKNAME "$src")
        # Grow partition 4 to the end of the card (a no-op when it already is), then tell the
        # kernel about the new size of that one, mounted, partition - what growpart does.
        echo ", +" | sfdisk --quiet --no-reread --no-tell-kernel -N 4 "$disk"
        partx --update --nr 4 "$disk"
        resize2fs "$src"
        touch ${stateRoot}/meshnode/.grown
      '';
    };

    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "meshnode-factory-reset";
        runtimeInputs = with pkgs; [ coreutils util-linux systemd ];
        text = builtins.readFile ../scripts/meshnode-factory-reset.sh;
      })
    ];

    # ---------------------------------------------------------------- boot speed: no Perl activation
    # With a tmpfs root, activation runs from scratch on every boot. These replace the
    # Perl activation scripts (the "perlless" profile approach):
    system.etc.overlay.enable = true;  # /etc = prebuilt EROFS image + overlayfs, not symlinks made at boot
    system.etc.overlay.mutable = true; # writable layer (on tmpfs) - node-config writes Wi-Fi config into /etc
    services.userborn = {
      enable = true;                   # compiled users/groups setup instead of update-users-groups.pl
      # Keep /etc/passwd & co on STATE so UIDs/GIDs of persisted data never shift between OTAs.
      passwordFilesLocation = "/var/lib/nixos/userborn";
    };
    system.switch.enable = false;      # no switch-to-configuration on the device; OTA is the update path
    system.disableInstallerTools = true;
    system.forbiddenDependenciesRegexes = lib.mkIf cfg.forbidPerl [ "perl" ];

    # ---------------------------------------------------------------- ship less
    nix.enable = false; # no daemon, CLI, build users, store DB; the store is a read-only image
    documentation.enable = false;
    documentation.man.enable = false;
    documentation.nixos.enable = false;
    environment.defaultPackages = [ ];
    environment.stub-ld.enable = false;
    programs.command-not-found.enable = false;
    boot.enableContainers = false;
    boot.bcache.enable = false;
    services.lvm.enable = false;
    services.udisks2.enable = false;
    fonts.fontconfig.enable = false;
    xdg.autostart.enable = false;
    xdg.icons.enable = false;
    xdg.mime.enable = false;
    xdg.sounds.enable = false;

    services.journald.settings.Journal.Storage = "volatile";
    zramSwap = {
      enable = lib.mkDefault true;
      memoryPercent = lib.mkDefault 50;
    };

    # Hardware watchdog: a hung trial slot gets reset, which drops the one-shot tryboot flag.
    systemd.settings.Manager = {
      RuntimeWatchdogSec = "15s";
      RebootWatchdogSec = "2m";
    };

    environment.etc."meshnode-release".text = "${cfg.board} ${cfg.version} build ${toString cfg.buildNumber}\n";
    environment.etc."meshnode-build".text = "${toString cfg.buildNumber}\n";

    # ---------------------------------------------------------------- networking
    networking.hostName = lib.mkDefault ""; # set at runtime from node.env (see node-config.nix)
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.nftables.enable = true; # the iptables firewall script is slow on old Pis
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
    systemd.network.networks."10-ethernet" = {
      matchConfig.Name = "eth* en*";
      networkConfig.DHCP = "yes";
    };
    systemd.network.networks."20-wifi" = {
      matchConfig.Name = "wlan*";
      networkConfig.DHCP = "yes";
    };
    systemd.network.wait-online.enable = false; # off-grid nodes must still boot fully

    networking.wireless = {
      enable = true;
      # Networks come from node/wpa_supplicant.conf injected per device.
      allowAuxiliaryImperativeNetworks = true;
    };

    # ---------------------------------------------------------------- access
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
      hostKeys = [{ path = "${stateRoot}/ssh/ssh_host_ed25519_key"; type = "ed25519"; }];
      authorizedKeysFiles = [ "${stateRoot}/meshnode/ssh/authorized_keys" ];
    };

    users.mutableUsers = false;
    # The image deliberately has no passwords, and SSH keys may arrive only at runtime: per-node
    # authorized_keys injected by scripts/personalize-image.sh, or Tailscale SSH. NixOS can't see
    # either at build time, so its lockout assertion is replaced by the warning below.
    users.allowNoPasswordLogin = true;
    warnings = lib.optional (cfg.sshKeys == [ ] && !config.meshnode.tailscale.ssh) ''
      meshnode: no fleet SSH keys (meshnode.sshKeys) and Tailscale SSH is off. The only way in
      will be keys injected per device with scripts/personalize-image.sh -s.
    '';
    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "dialout" ];
      openssh.authorizedKeys.keys = cfg.sshKeys;
    };
    security.sudo.wheelNeedsPassword = false;
  };
}
