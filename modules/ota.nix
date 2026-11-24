# A/B OTA: meshnode-ota CLI plus the systemd units that gate committing a trial boot.
#
#   meshnode-ota update <bundle>  -> verify signature + build number, write inactive slot,
#                                    set tryboot.txt, `reboot "0 tryboot"`
#   trial boot                    -> meshnode-ota-health must pass before boot-complete.target
#   boot-complete.target reached  -> meshnode-ota-commit rewrites config.txt to the new slot
#   no commit within trialTimeout -> plain reboot, firmware reads config.txt = old slot
#   crash / hang / power loss     -> tryboot flag is one-shot, so the old slot boots
{ config, lib, pkgs, ... }:
let
  cfg = config.meshnode.ota;

  # "ssh-ed25519 AAAA... comment" -> "ssh-ed25519 AAAA..."
  keyFields = key: lib.concatStringsSep " " (lib.take 2 (lib.filter (x: x != "") (lib.splitString " " (lib.trim key))));

  allowedSigners = pkgs.writeText "meshnode-ota-allowed-signers" (lib.concatStrings
    (lib.mapAttrsToList (name: key: ''${name} namespaces="meshnode-ota" ${keyFields key}
    '') cfg.trustedKeys));

  ota = pkgs.writeShellApplication {
    name = "meshnode-ota";
    runtimeInputs = with pkgs; [ coreutils util-linux zstd gnutar curl jq gnused systemd openssh ];
    text = builtins.replaceStrings
      [ "@BOARD@" "@ALLOWED_SIGNERS@" "@REQUIRE_SIG@" ]
      [ config.meshnode.board "${allowedSigners}" (if cfg.requireSignature then "1" else "0") ]
      (builtins.readFile ../scripts/meshnode-ota.sh);
  };
in
{
  options.meshnode.ota = {
    trustedKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { raine-tkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."; };
      description = ''
        SSH public keys allowed to sign OTA bundles, keyed by signer name. Any key type
        `ssh-keygen -Y` supports works, including hardware-backed `sk-ssh-ed25519@openssh.com`.
        hosts/default.nix fills this from keys/*.pub. To rotate, ship one signed release that
        trusts both the old and new key, then drop the old one.
      '';
    };
    requireSignature = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Signed OTA. When true (the default), nodes install only bundles signed by a key in
        trustedKeys, and the build fails if there are none. When false, OTA is disabled:
        `meshnode-ota update`/`verify` refuse every bundle and nodes can only be updated by
        reflashing. There is never an unsigned OTA path.
      '';
    };
    healthUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units that must be active before a trial slot is committed.";
    };
    healthTimeoutSec = lib.mkOption { type = lib.types.int; default = 180; };
    extraHealthCheck = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra shell run by the health check; a non-zero exit blocks the commit.";
    };
    trialTimeout = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "Reboot back to the committed slot if a trial boot has not committed by then.";
    };
  };

  config = {
    assertions = [{
      assertion = cfg.requireSignature -> cfg.trustedKeys != { };
      message = ''
        meshnode.ota.requireSignature is on but no OTA signing keys are trusted, so this image
        could never accept an update. Add your public key as keys/<name>.pub (see keys/README.md),
        `git add` it, and rebuild - or set meshnode.ota.requireSignature = false to build an image
        with OTA disabled (reflash-only).
      '';
    }];

    environment.systemPackages = [ ota ];
    meshnode.ota.healthUnits = [ "sshd.service" ];

    systemd.targets.boot-complete.description = "Boot Completion Check";

    systemd.services.meshnode-ota-health = {
      description = "A/B health check";
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      after = cfg.healthUnits;
      path = [ pkgs.systemd pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        units="${lib.concatStringsSep " " cfg.healthUnits}"
        deadline=$(( $(date +%s) + ${toString cfg.healthTimeoutSec} ))
        while :; do
          bad=""
          for u in $units; do
            systemctl is-active --quiet "$u" || bad="$bad $u"
          done
          if [ -z "$bad" ]; then break; fi
          if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "unhealthy:$bad" >&2
            exit 1
          fi
          sleep 5
        done
        ${cfg.extraHealthCheck}
        echo "healthy"
      '';
    };

    systemd.services.meshnode-ota-commit = {
      description = "Commit the running A/B slot after a healthy trial boot";
      requires = [ "boot-complete.target" ];
      after = [ "boot-complete.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ "/boot/firmware" "/boot/state" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${ota}/bin/meshnode-ota commit";
      };
    };

    systemd.timers.meshnode-ota-trial-timeout = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnBootSec = cfg.trialTimeout;
    };
    systemd.services.meshnode-ota-trial-timeout = {
      description = "Fall back to the committed slot if a trial boot never committed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${ota}/bin/meshnode-ota trial-timeout";
      };
    };
  };
}
