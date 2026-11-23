#!/usr/bin/env bash
# Sign an OTA bundle so nodes will accept it.
#
#   nix build .#packages.aarch64-linux.pi4-ota -o ota-pi4
#   scripts/sign-ota.sh -k ~/.ssh/meshnode-ota ota-pi4           # plain key file
#   scripts/sign-ota.sh -k keys/raine-tkey.pub ota-pi4           # key held in ssh-agent (TKey, YubiKey, 1Password...)
#
# Copies the bundle out of the (read-only) Nix store into signed/<board>-<build>/, writes
# manifest.json.sig with `ssh-keygen -Y sign -n meshnode-ota`, then checks the signature
# against keys/*.pub - the same keys the images trust - so you find out here, not on a node.
# Needs: ssh-keygen (OpenSSH >= 8.2), jq.
set -euo pipefail

NAMESPACE="meshnode-ota"
repo=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "sign-ota: $*" >&2; exit 1; }
usage() {
  cat >&2 <<USAGE
usage: $0 -k <key> [-o <outdir>] <bundle-dir>
  -k  signing key: a private key file, an sk- key handle (YubiKey/FIDO), or a .pub
      whose private half is loaded in ssh-agent (e.g. tkey-ssh-agent for a Tillitis TKey)
  -o  output directory (default: signed/<board>-<build>)
USAGE
  exit 2
}

key="" out=""
while getopts "k:o:h" opt; do
  case "$opt" in
    k) key=$OPTARG ;;
    o) out=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] && [ -n "$key" ] || usage
bundle=${1%/}
for t in ssh-keygen jq; do command -v "$t" > /dev/null || die "missing $t (try: nix develop)"; done
[ -f "$bundle/manifest.json" ] || die "$bundle/manifest.json not found - is this an OTA bundle (nix build .#<board>-ota)?"
[ -e "$key" ] || die "key $key not found"

board=$(jq -r .board "$bundle/manifest.json")
build=$(jq -r .build "$bundle/manifest.json")
version=$(jq -r .version "$bundle/manifest.json")
out=${out:-$repo/signed/$board-$build}

mkdir -p "$out"
for f in manifest.json "$(jq -r .slotfs.file "$bundle/manifest.json")" "$(jq -r .boot.file "$bundle/manifest.json")"; do
  cp -fL "$bundle/$f" "$out/$f"
  chmod u+w "$out/$f"
done
rm -f "$out/manifest.json.sig"

echo "signing $board $version (build $build) with $key ..." >&2
ssh-keygen -Y sign -q -f "$key" -n "$NAMESPACE" "$out/manifest.json"
[ -s "$out/manifest.json.sig" ] || die "ssh-keygen did not produce a signature"

# Self-check against the keys the images trust.
allowed=$(mktemp)
trap 'rm -f "$allowed"' EXIT
for f in "$repo"/keys/*.pub; do
  [ -e "$f" ] || continue
  printf '%s namespaces="%s" %s\n' "$(basename "$f" .pub)" "$NAMESPACE" "$(awk 'NF { print $1, $2; exit }' "$f")"
done > "$allowed"

if [ ! -s "$allowed" ]; then
  echo "warning: no keys/*.pub in the repo, so images trust no signer yet - skipped self-check" >&2
else
  signer=$(ssh-keygen -Y find-principals -f "$allowed" -s "$out/manifest.json.sig" 2>/dev/null | head -n1) \
    || die "signed, but the key is not in keys/ - nodes will reject this bundle"
  ssh-keygen -Y verify -q -f "$allowed" -I "$signer" -n "$NAMESPACE" -s "$out/manifest.json.sig" \
    < "$out/manifest.json" > /dev/null || die "signature failed self-check"
  echo "verified: signer '$signer' is trusted by images built from keys/" >&2
fi

echo "$out"
