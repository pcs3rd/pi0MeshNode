#!/usr/bin/env bash
# Personalize a built meshnode image for one device - secrets never enter the Nix store.
#
#   scripts/personalize-image.sh -i result/meshnode-pi0-*.img.zst -o node-01.img -n node-01 \
#       -k ~/secrets/tskey-node-01 -w ~/secrets/wifi.conf [-s extra_authorized_keys]
#
# Needs: zstd, mtools (`nix develop` provides both). Works on Linux and macOS, no root.
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: $0 -i <image.img[.zst]> -o <out.img> -n <hostname> [-k <tailscale-authkey-file>]
          [-w <wpa_supplicant.conf>] [-s <authorized_keys>]
USAGE
  exit 2
}

in="" out="" name="" key="" wifi="" ssh=""
while getopts "i:o:n:k:w:s:h" opt; do
  case "$opt" in
    i) in=$OPTARG ;;
    o) out=$OPTARG ;;
    n) name=$OPTARG ;;
    k) key=$OPTARG ;;
    w) wifi=$OPTARG ;;
    s) ssh=$OPTARG ;;
    *) usage ;;
  esac
done
[ -n "$in" ] && [ -n "$out" ] && [ -n "$name" ] || usage
for t in zstd mcopy; do
  command -v "$t" > /dev/null || { echo "missing $t (try: nix develop)" >&2; exit 1; }
done

case "$in" in
  *.zst) zstd -dc "$in" > "$out" ;;
  *) cp "$in" "$out" ;;
esac

# FIRMWARE is partition 1 at 1 MiB (see modules/ab-image.nix / layout.env).
export MTOOLS_SKIP_CHECK=1
fat="$out@@1M"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'NODE_HOSTNAME=%s\n' "$name" > "$tmp/node.env"
mcopy -o -i "$fat" "$tmp/node.env" ::node/node.env

if [ -n "$key" ]; then
  tr -d ' \r\n' < "$key" > "$tmp/tailscale-authkey"
  grep -q '^tskey-' "$tmp/tailscale-authkey" || echo "warning: $key does not look like a tskey-... auth key" >&2
  mcopy -o -i "$fat" "$tmp/tailscale-authkey" ::node/tailscale-authkey
fi
if [ -n "$wifi" ]; then mcopy -o -i "$fat" "$wifi" ::node/wpa_supplicant.conf; fi
if [ -n "$ssh" ]; then mcopy -o -i "$fat" "$ssh" ::node/authorized_keys; fi

echo "wrote $out for $name"
echo "flash: sudo dd if=$out of=/dev/<card> bs=4M conv=fsync status=progress"
echo "note: $out now contains secrets - delete it after flashing."
