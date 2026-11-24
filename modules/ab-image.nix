# Builds the full SD image and the OTA bundle.
#
# MBR layout (1 MiB aligned):
#   p1  FIRMWARE  vfat  firmwareSizeMiB   firmware blobs, config.txt/tryboot.txt, slot_a/, slot_b/, node/
#   p2  slot A    erofs rootSizeMiB       read-only image of the closure, mounted at /nix/store
#   p3  slot B    erofs rootSizeMiB       empty until the first OTA
# Slots are found by PARTUUID (<diskId>-02 / -03), not by filesystem label.
#   p4  STATE     ext4  stateSizeMiB      /boot/state, grown to fill the card on first boot
{ config, lib, pkgs, modulesPath, ... }:
let
  cfg = config.meshnode.image;
  inherit (config.meshnode) board version;
  bp = pkgs.buildPackages;
  toplevel = config.system.build.toplevel;
  slot = config.system.build.rpiSlot;
  fwDir = config.system.build.rpiFirmwareDir;
  zstdArgs = "-T0 -q -${toString cfg.compressionLevel}";

  # The slot is an EROFS image whose top level *is* the store (mounted at /nix/store).
  closure = pkgs.buildPackages.closureInfo { rootPaths = [ toplevel ]; };
  erofsCompression = {
    none = "";
    lz4 = "-zlz4";
    lz4hc = "-zlz4hc,12";
  }.${cfg.slotCompression};
  slotFs = bp.runCommand "meshnode-${board}-slot.erofs"
    { nativeBuildInputs = [ bp.erofs-utils ]; }
    ''
      mkdir root
      while read -r p; do cp -a "$p" root/; done < ${closure}/store-paths
      mkfs.erofs ${erofsCompression} --all-root -T0 -L MESHNODE $out root
    '';

  nodeReadme = pkgs.writeText "README.txt" ''
    Per-device settings for this meshnode (${board}).

    Drop any of these files here before first boot (scripts/personalize-image.sh does it
    for you). They are moved to /boot/state on boot and deleted from this partition.

      node.env              NODE_HOSTNAME=<name>
      tailscale-authkey     a Tailscale auth key (tskey-auth-...), used once to enroll
      wpa_supplicant.conf   network={ ssid="..." psk="..." } blocks
      authorized_keys       extra SSH keys for the `${config.meshnode.user}` user

    Factory reset: create an empty file named FACTORY_RESET in the top level of this
    partition. The next boot wipes /boot/state (Tailscale identity, meshtastic node DB,
    SSH host keys, previously injected node files). Put fresh node files here alongside
    it if the device should re-enroll.
  '';
in
{
  options.meshnode.image = {
    firmwareSizeMiB = lib.mkOption { type = lib.types.int; default = 256; };
    rootSizeMiB = lib.mkOption {
      type = lib.types.int;
      default = 2560;
      description = "Size of EACH A/B slot partition. Fixed at flash time - leave headroom for future closures.";
    };
    stateSizeMiB = lib.mkOption {
      type = lib.types.int;
      default = 256;
      description = "Initial STATE size; grown to fill the card on first boot.";
    };
    slotCompression = lib.mkOption {
      type = lib.types.enum [ "none" "lz4" "lz4hc" ];
      default = "lz4hc";
      description = ''
        EROFS compression for the store slots. lz4hc and lz4 decompress at the same speed;
        lz4hc only spends more time at build. "none" means zero decompression at boot
        (bigger slot, and the OTA download is still zstd-compressed).
      '';
    };
    diskId = lib.mkOption {
      type = lib.types.strMatching "[0-9a-f]{8}";
      default = "4d455348";
      description = "MBR disk identifier; slot partitions get PARTUUIDs <diskId>-02 and <diskId>-03.";
    };
    compressionLevel = lib.mkOption {
      type = lib.types.int;
      default = 12;
      description = "zstd level for the .img.zst and OTA payloads (download size only).";
    };
  };

  config.system.build = {
    abSlotFs = slotFs;

    abImage = bp.runCommand "meshnode-${board}-${version}-image"
      { nativeBuildInputs = with bp; [ dosfstools mtools e2fsprogs util-linux zstd ]; }
      ''
        export MTOOLS_SKIP_CHECK=1
        MiB=1048576
        fw=${toString cfg.firmwareSizeMiB}
        root=${toString cfg.rootSizeMiB}
        state=${toString cfg.stateSizeMiB}
        s1=1
        s2=$((s1 + fw))
        s3=$((s2 + root))
        s4=$((s3 + root))
        total=$((s4 + state))

        fsBytes=$(stat -c %s ${slotFs})
        if [ "$fsBytes" -gt $((root * MiB)) ]; then
          echo "slot image ($fsBytes bytes) does not fit in a $root MiB slot; raise meshnode.image.rootSizeMiB" >&2
          exit 1
        fi

        truncate -s $((total * MiB)) disk.img
        sfdisk --no-reread --no-tell-kernel disk.img <<EOF
        label: dos
        label-id: 0x${cfg.diskId}
        unit: sectors

        start=$((s1 * 2048)), size=$((fw * 2048)), type=c, bootable
        start=$((s2 * 2048)), size=$((root * 2048)), type=83
        start=$((s3 * 2048)), size=$((root * 2048)), type=83
        start=$((s4 * 2048)), size=$((state * 2048)), type=83
        EOF

        # FIRMWARE
        mkdir -p stage/slot_a stage/slot_b stage/node
        cp -r ${fwDir}/. stage/
        cp -r ${slot}/. stage/slot_a/
        chmod -R u+w stage
        printf '%s abslot=a\n' "$(cat stage/slot_a/cmdline.base)" > stage/slot_a/cmdline.txt
        cp ${nodeReadme} stage/node/README.txt
        truncate -s $((fw * MiB)) fw.img
        mkfs.vfat -F 32 -n FIRMWARE -i 4d455348 fw.img
        mcopy -s -i fw.img stage/* ::

        # Slot A: the built system. Slot B stays zeroed (the image is sparse) until the first OTA.

        # STATE
        truncate -s $((state * MiB)) state.img
        mkfs.ext4 -q -F -L STATE state.img

        dd if=fw.img of=disk.img bs=1M seek=$s1 conv=notrunc status=none
        dd if=${slotFs} of=disk.img bs=1M seek=$s2 conv=notrunc status=none
        dd if=state.img of=disk.img bs=1M seek=$s4 conv=notrunc status=none

        mkdir -p $out
        zstd ${zstdArgs} disk.img -o $out/meshnode-${board}-${version}.img.zst
        cat > $out/layout.env <<EOF
        BOARD=${board}
        VERSION=${version}
        FIRMWARE_OFFSET=$((s1 * MiB))
        EOF
      '';

    # Everything `meshnode-ota update` needs except the signature: sign it with
    # scripts/sign-ota.sh (outside Nix, so the private key never touches the store).
    otaBundle = bp.runCommand "meshnode-${board}-${version}-ota"
      { nativeBuildInputs = with bp; [ zstd gnutar jq ]; }
      ''
        mkdir -p $out
        zstd ${zstdArgs} ${slotFs} -o $out/slotfs.img.zst
        tar -C ${slot} --sort=name --owner=0 --group=0 --numeric-owner --mtime=@1 -cf - . \
          | zstd ${zstdArgs} -o $out/boot.tar.zst
        jq -n \
          --arg board ${board} \
          --arg version ${version} \
          --arg toplevel ${toplevel} \
          --arg fsSum "$(sha256sum $out/slotfs.img.zst | cut -d' ' -f1)" \
          --arg bootSum "$(sha256sum $out/boot.tar.zst | cut -d' ' -f1)" \
          --arg rawSum "$(sha256sum ${slotFs} | cut -d' ' -f1)" \
          --argjson rawSize "$(stat -c %s ${slotFs})" \
          --argjson build ${toString config.meshnode.buildNumber} \
          '{format: 3, board: $board, version: $version, build: $build, toplevel: $toplevel,
            slotfs: {file: "slotfs.img.zst", sha256: $fsSum, rawSha256: $rawSum, rawSize: $rawSize},
            boot:   {file: "boot.tar.zst",   sha256: $bootSum}}' > $out/manifest.json
      '';
  };
}
