# Tailscale with one-shot enrollment from an auth key injected at image-personalize time.
# Pi Zero (ARMv6) quirks, per https://gist.github.com/StrixROX/5b1b035351a00e5498ad6099e961c64d :
#   * pinned upstream static 1.62.0 binary (newer static builds segfaulted on the Zero W)
#   * --tun=userspace-networking
{ config, lib, pkgs, ... }:
let
  cfg = config.meshnode.tailscale;
  isPi0 = config.meshnode.board == "pi0";
  keyFile = "/boot/state/meshnode/node/tailscale-authkey";
  ts = config.services.tailscale.package;
in
{
  options.meshnode.tailscale = {
    enable = lib.mkEnableOption "Tailscale with first-boot enrollment" // { default = true; };
    ssh = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Tailscale SSH (--ssh).";
    };
    pi0StaticBinary = lib.mkOption {
      type = lib.types.bool;
      default = isPi0;
      description = "Use the pinned upstream static ARM binary instead of building tailscale from nixpkgs.";
    };
    userspaceNetworking = lib.mkOption {
      type = lib.types.bool;
      default = isPi0;
      description = "Run tailscaled without a TUN device (--tun=userspace-networking).";
    };
    extraUpFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--advertise-tags=tag:meshnode" ];
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      package = lib.mkIf cfg.pi0StaticBinary (pkgs.callPackage ../pkgs/tailscale-static-arm.nix { });
      interfaceName = lib.mkIf cfg.userspaceNetworking "userspace-networking";
      # nixpkgs' tailscaled-autoconnect runs `tailscale up --auth-key=file:...` while the
      # node still needs login. Tags/expiry/pre-approval are properties of the key itself.
      authKeyFile = keyFile;
      extraUpFlags = lib.optional cfg.ssh "--ssh" ++ cfg.extraUpFlags;
    };

    meshnode.state.directories = [ "/var/lib/tailscale" ];
    meshnode.ota.healthUnits = [ "tailscaled.service" ];

    systemd.services.tailscaled-autoconnect.unitConfig.ConditionPathExists = keyFile;

    # Once enrolled, the key has done its job - remove it from disk.
    systemd.services.meshnode-tailscale-key-cleanup = {
      description = "Remove the Tailscale auth key once the node is enrolled";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscaled-autoconnect.service" ];
      unitConfig.ConditionPathExists = keyFile;
      path = [ ts pkgs.jq pkgs.coreutils ];
      serviceConfig.Type = "exec"; # don't hold up multi-user.target while waiting
      script = ''
        state=""
        for _ in $(seq 1 60); do
          state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
          if [ "$state" = "Running" ]; then
            shred -u ${keyFile} 2>/dev/null || rm -f ${keyFile}
            echo "enrolled; auth key removed"
            exit 0
          fi
          sleep 5
        done
        echo "not enrolled yet (state: ''${state:-unknown}); keeping the key for the next boot"
      '';
    };
  };
}
