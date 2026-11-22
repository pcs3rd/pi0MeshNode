# meshtasticd (Linux-native Meshtastic) from nixpkgs' services.meshtasticd.
# Per-hardware radio settings belong in hosts/default.nix (services.meshtasticd.settings).
{ config, lib, ... }:
let
  cfg = config.meshnode.meshtastic;
in
{
  options.meshnode.meshtastic.enable = lib.mkEnableOption "meshtasticd" // { default = true; };

  config = lib.mkIf cfg.enable {
    services.meshtasticd = {
      enable = true;
      settings = {
        Lora.Module = lib.mkDefault "auto";
        Logging.LogLevel = lib.mkDefault "info";
        General = {
          MaxNodes = lib.mkDefault 200;
          MaxMessageQueue = lib.mkDefault 100;
        };
      };
    };
    services.udev.packages = [ config.services.meshtasticd.package ];

    meshnode.state.directories = [ config.services.meshtasticd.dataDir ];
    meshnode.ota.healthUnits = [ "meshtasticd.service" ];
  };
}
