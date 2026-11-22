# Fleet-wide settings shared by every board image.
# Per-device bits (hostname, Tailscale auth key, Wi-Fi, extra SSH keys) are NOT set here:
# scripts/personalize-image.sh writes them onto the FIRMWARE partition after the build.
{ ... }:
{
  meshnode.sshKeys = [
    # "ssh-ed25519 AAAA... you@workstation"
  ];

  meshnode.tailscale.ssh = true;
  # meshnode.tailscale.extraUpFlags = [ "--advertise-tags=tag:meshnode" ];

  services.meshtasticd.settings = {
    Lora = {
      Module = "auto";
      # USB (CH341) or SPI HAT radios need explicit pins/module settings; copy the matching
      # file from meshtastic/firmware bin/config.d/ and translate it here.
    };
  };

  time.timeZone = "America/New_York";
}
