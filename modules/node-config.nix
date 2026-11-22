# Per-device settings injected onto the FIRMWARE partition after the image is built
# (scripts/personalize-image.sh), so no secret ever lands in the Nix store.
{ pkgs, ... }:
{
  systemd.services.meshnode-node-config = {
    description = "Import per-node settings from the FIRMWARE partition";
    wantedBy = [ "multi-user.target" ];
    before = [ "wpa_supplicant.service" "tailscaled.service" "tailscaled-autoconnect.service" "sshd.service" ];
    unitConfig.RequiresMountsFor = [ "/boot/firmware" "/boot/state" ];
    path = [ pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      src=/boot/firmware/node
      dst=/boot/state/meshnode/node
      install -d -m 0700 "$dst"
      install -d -m 0755 /boot/state/meshnode/ssh

      # Move secrets off the FAT partition as early as possible.
      for f in node.env tailscale-authkey wpa_supplicant.conf authorized_keys; do
        if [ -s "$src/$f" ]; then
          install -m 0600 "$src/$f" "$dst/$f"
          rm -f "$src/$f"
        fi
      done
      sync

      if [ -f "$dst/authorized_keys" ]; then
        install -m 0644 "$dst/authorized_keys" /boot/state/meshnode/ssh/authorized_keys
      fi

      # Root is tmpfs, so re-install imperative Wi-Fi networks every boot. Current nixpkgs
      # reads /etc/wpa_supplicant/imperative.conf; older releases used /etc/wpa_supplicant.conf.
      if [ -f "$dst/wpa_supplicant.conf" ]; then
        install -D -m 0600 "$dst/wpa_supplicant.conf" /etc/wpa_supplicant/imperative.conf
        [ -e /etc/wpa_supplicant.conf ] || install -m 0600 "$dst/wpa_supplicant.conf" /etc/wpa_supplicant.conf
      fi

      NODE_HOSTNAME=""
      if [ -f "$dst/node.env" ]; then
        # shellcheck disable=SC1091
        . "$dst/node.env"
      fi
      if [ -n "$NODE_HOSTNAME" ]; then
        echo "$NODE_HOSTNAME" > /proc/sys/kernel/hostname
      fi
    '';
  };
}
