# Fleet-wide settings shared by every board image.
# Per-device bits (hostname, Tailscale auth key, Wi-Fi, extra SSH keys) are NOT set here:
# scripts/personalize-image.sh writes them onto the FIRMWARE partition after the build.
{ lib, ... }:
let
  # Every keys/<name>.pub becomes a trusted OTA signer called <name> (see keys/README.md).
  # Flakes only see git-tracked files: `git add keys/<name>.pub`.
  keyFiles = lib.filterAttrs (f: t: t == "regular" && lib.hasSuffix ".pub" f) (builtins.readDir ../keys);
in
{
  # Login user (wheel, passwordless sudo). Its password works for SSH (meshnode.ssh.passwordAuth,
  # on by default) and for the console when HDMI is enabled.
  meshnode.user = "meshtastic";
  # Replace "!" (= no password, login disabled) with a hash from:
  #   nix shell nixpkgs#mkpasswd -c mkpasswd
  # The repo is public, so this hash is published - use a long random password.
  users.users.meshtastic.hashedPassword = "$y$j9T$6/QpBaekmL2XG4NUJRdHY0$SHm/vCefXXVoz5Sfp/HUNEIELPMs8B25ocgcXeWYyk/";

  meshnode.sshKeys = [
    # "ssh-ed25519 AAAA... you@workstation"
  ];

  # TEMPORARY: signing is off, which disables OTA - these nodes refuse every bundle and can
  # only be updated by reflashing. Add a key to keys/ (see keys/README.md) and delete this
  # line to get signed OTA updates.
  meshnode.ota.requireSignature = false;

  meshnode.ota.trustedKeys = lib.mapAttrs'
    (f: _: lib.nameValuePair (lib.removeSuffix ".pub" f) (lib.fileContents (../keys + "/${f}")))
    keyFiles;

  meshnode.tailscale.ssh = true;
  # meshnode.tailscale.extraUpFlags = [ "--advertise-tags=tag:meshnode" ];

  # Radio: Elecrow MeshStick by default (modules/meshtastic.nix). Other hardware:
  #   meshnode.meshtastic.radio = "custom";
  #   services.meshtasticd.settings.Lora = { ... };  # from meshtastic/firmware bin/config.d/
  # Several sticks on one node? Pin one: meshnode.meshtastic.usbSerial = "12345678";
  # I2C sensors on /dev/i2c-1 are on by default: meshnode.meshtastic.i2c.enable = false; to turn off.

  time.timeZone = "America/New_York";
}
