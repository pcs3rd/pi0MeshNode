# shellcheck shell=bash
# meshnode-factory-reset - wipe /boot/state on the next boot.
# Packaged by modules/base.nix (writeShellApplication adds the shebang and PATH) and
# installed as /run/current-system/sw/bin/meshnode-factory-reset.
#
# It only drops the FACTORY_RESET flag on the FIRMWARE partition and reboots; the
# initrd (meshnode-factory-reset unit in modules/base.nix) reformats STATE before it
# is mounted. The OS slots are not touched.

set -euo pipefail

FLAG=/boot/firmware/FACTORY_RESET

usage() {
  cat >&2 <<'USAGE'
usage: meshnode-factory-reset --force

Wipes /boot/state on the next boot and reboots immediately. This erases:
  - the Tailscale identity (the node must re-enroll with a new auth key)
  - the meshtasticd node database and settings
  - SSH host keys and machine-id
  - per-node files imported from the boot partition (hostname, Wi-Fi, SSH keys)

--force is required to confirm.
USAGE
  exit 2
}

[ $# -eq 1 ] && [ "$1" = "--force" ] || usage
[ "$(id -u)" -eq 0 ] || { echo "meshnode-factory-reset: must run as root" >&2; exit 1; }
mountpoint -q /boot/firmware || { echo "meshnode-factory-reset: /boot/firmware is not mounted" >&2; exit 1; }

touch "$FLAG"
sync
echo "meshnode-factory-reset: reset flagged; rebooting" >&2
systemctl reboot
