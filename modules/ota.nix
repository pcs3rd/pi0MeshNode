# A/B OTA: meshnode-ota CLI plus the systemd units that gate committing a trial boot.
#
#   meshnode-ota update <bundle>  -> writes inactive slot, sets tryboot.txt, `reboot "0 tryboot"`
#   trial boot                    -> meshnode-ota-health must pass before boot-complete.target
#   boot-complete.target reached  -> meshnode-ota-commit rewrites config.txt to the new slot
#   no commit within trialTimeout -> plain reboot, firmware reads config.txt = old slot
#   crash / hang / power loss     -> tryboot flag is one-shot, so the old slot boots
{ config, lib, pkgs, ... }:
let
  cfg = config.meshnode.ota;
  ota = pkgs.writeShellApplication {
    name = "meshnode-ota";
    runtimeInputs = with pkgs; [ coreutils util-linux zstd gnutar curl jq gnused systemd ];
    text = builtins.replaceStrings [ "@BOARD@" ] [ config.meshnode.board ]
      (builtins.readFile ../scripts/meshnode-ota.sh);
  };
in
{
  options.meshnode.ota = {
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
