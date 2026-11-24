{
  imports = [
    ./base.nix
    ./rpi-boot.nix
    ./ab-image.nix
    ./ota.nix
    ./node-config.nix
    ./tailscale.nix
    ./meshtastic.nix
    ./cross-fixes.nix
  ];
}
