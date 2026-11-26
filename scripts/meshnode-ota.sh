# shellcheck shell=bash
# meshnode-ota - signed A/B OS updates for Raspberry Pi using the firmware "tryboot" flag.
# Packaged by modules/ota.nix (writeShellApplication adds the shebang and PATH).
#
# FIRMWARE (p1) holds shared firmware plus slot_a/ and slot_b/ (kernel, initrd, dtbs,
# overlays, cmdline.txt). config.txt picks the committed slot via os_prefix, tryboot.txt
# picks the candidate. `reboot "0 tryboot"` makes the firmware read tryboot.txt for
# exactly one boot; any later reboot falls back to config.txt.
# Slot images: p2 = slot A, p3 = slot B - read-only EROFS images of the whole closure,
# the active one mounted at /nix/store. An update is a verified raw write of the image.
#
# Trust: manifest.json must carry a valid `ssh-keygen -Y` signature (manifest.json.sig,
# namespace "meshnode-ota") from a key in meshnode.ota.trustedKeys. The manifest pins the
# sha256 of every payload, the board and a build number; bundles whose build is not newer
# than anything this node has run are refused (anti-rollback). An image built with
# signing disabled (meshnode.ota.requireSignature = false) refuses every bundle: there is
# no unsigned OTA path. Such nodes are updated by reflashing.

set -euo pipefail

BOARD="@BOARD@"
ALLOWED_SIGNERS="@ALLOWED_SIGNERS@"
REQUIRE_SIG="@REQUIRE_SIG@"
NAMESPACE="meshnode-ota"
FW=/boot/firmware
STATE=/boot/state/meshnode/ota
SRC=""
WORK=""

log() { echo "meshnode-ota: $*" >&2; }
die() { log "error: $*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: meshnode-ota <command>
  status                    show slots, builds, trial state and trusted signers
  verify <bundle>           check a bundle's signature, board and build without installing
  update <bundle> [flags]   install a bundle into the inactive slot, then reboot into it
                            as a one-shot trial. <bundle> is an http(s) URL or directory
                            holding manifest.json + manifest.json.sig
      --no-reboot           stage only; reboot later with: systemctl reboot --reboot-argument="0 tryboot"
      --allow-downgrade     accept a bundle whose build is not newer (reinstall / deliberate downgrade)
  commit                    make the running trial slot permanent
                            (normally run by meshnode-ota-commit.service)
  abort                     leave a trial now: reboot into the committed slot
  trial-timeout             internal: run by meshnode-ota-trial-timeout.timer
USAGE
  exit 2
}

current_slot() {
  local -a args
  local arg
  read -r -a args < /proc/cmdline
  for arg in "${args[@]}"; do
    case "$arg" in
      abslot=a | abslot=b) echo "${arg#abslot=}"; return 0 ;;
    esac
  done
  die "no abslot= on the kernel command line"
}

committed_slot() {
  local s
  s=$(sed -n 's|^os_prefix=slot_\([ab]\)/$|\1|p' "$FW/config.txt" | head -n1)
  [ -n "$s" ] || die "cannot parse os_prefix from $FW/config.txt"
  echo "$s"
}

other_slot() {
  case "$1" in
    a) echo b ;;
    b) echo a ;;
    *) die "bad slot: $1" ;;
  esac
}

part_for_slot() {
  local num disk
  case "$1" in
    a) num=2 ;;
    b) num=3 ;;
    *) die "bad slot: $1" ;;
  esac
  disk=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE /boot/state)")
  case "$disk" in
    *[0-9]) echo "/dev/${disk}p${num}" ;;
    *) echo "/dev/${disk}${num}" ;;
  esac
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

running_build() { tr -d '[:space:]' < /etc/meshnode-build; }

# Lowest build this node will accept: newer than what is running and than anything it
# has ever committed (so rolling back to the old slot does not reopen old builds).
build_floor() {
  local floor rec
  floor=$(running_build)
  if [ -f "$STATE/min-build" ]; then
    rec=$(tr -d '[:space:]' < "$STATE/min-build")
    if is_uint "$rec" && [ "$rec" -gt "$floor" ]; then floor=$rec; fi
  fi
  echo "$floor"
}

write_cfg() { # write_cfg <file> <slot>
  local tmp="$1.tmp"
  printf '# managed by meshnode-ota - do not edit by hand\n[all]\nos_prefix=slot_%s/\ninclude common.txt\n' "$2" > "$tmp"
  sync "$tmp"
  mv -f "$tmp" "$1"
  sync
}

fetch() { # fetch <name> <dest>
  case "$SRC" in
    http://* | https://*) curl -fsSL --retry 3 -o "$2" "$SRC/$1" ;;
    *) cp "$SRC/$1" "$2" ;;
  esac
}

cleanup() { if [ -n "$WORK" ]; then rm -rf "$WORK"; fi; }

require_ota_enabled() {
  [ "$REQUIRE_SIG" = 1 ] \
    || die "OTA is disabled: this image was built with signing off (meshnode.ota.requireSignature = false), so it accepts no bundles. Reflash it, or build with a key in keys/ to enable signed OTA."
}

set_source() {
  SRC="${1%/}"
  SRC="${SRC%/manifest.json}"
}

# fetch_and_check_manifest <allow_downgrade 0|1>: leaves a verified $WORK/manifest.json
fetch_and_check_manifest() {
  local allow_downgrade="$1" mf signer mboard mbuild floor
  mkdir -p "$STATE"
  WORK=$(mktemp -d "$STATE/dl.XXXXXX") # on STATE: tmpfs root is too small on a Pi Zero
  trap cleanup EXIT
  mf="$WORK/manifest.json"

  require_ota_enabled # defence in depth; callers check first
  fetch manifest.json "$mf"
  fetch manifest.json.sig "$mf.sig" || die "bundle is not signed (no manifest.json.sig)"
  signer=$(ssh-keygen -Y find-principals -f "$ALLOWED_SIGNERS" -s "$mf.sig" 2>/dev/null | head -n1) \
    || die "manifest is not signed by a trusted key"
  [ -n "$signer" ] || die "manifest is not signed by a trusted key"
  ssh-keygen -Y verify -q -f "$ALLOWED_SIGNERS" -I "$signer" -n "$NAMESPACE" -s "$mf.sig" < "$mf" > /dev/null \
    || die "bad signature on manifest.json"
  log "signature OK (signer: $signer)"

  # Everything below is read from the now-authenticated manifest.
  [ "$(jq -r .format "$mf")" = "3" ] || die "unsupported manifest format"
  mboard=$(jq -r .board "$mf")
  [ "$mboard" = "$BOARD" ] || die "bundle is for $mboard, this node is $BOARD"
  mbuild=$(jq -r .build "$mf")
  is_uint "$mbuild" || die "manifest has no valid build number"
  floor=$(build_floor)
  if [ "$mbuild" -le "$floor" ]; then
    if [ "$allow_downgrade" = 1 ]; then
      log "WARNING: build $mbuild is not newer than $floor; continuing (--allow-downgrade)"
    else
      die "bundle build $mbuild is not newer than $floor (pass --allow-downgrade to force)"
    fi
  fi
  log "bundle: $mboard $(jq -r .version "$mf") build $mbuild"
}

cmd_status() {
  local cur com
  cur=$(current_slot)
  com=$(committed_slot)
  echo "board:     $BOARD"
  echo "release:   $(cat /etc/meshnode-release 2>/dev/null || echo unknown)"
  echo "running:   slot $cur"
  echo "committed: slot $com"
  if [ "$cur" != "$com" ]; then
    echo "state:     TRIAL (pending: $(cat "$STATE/pending" 2>/dev/null || echo '?'))"
  else
    echo "state:     committed"
  fi
  echo "accepts:   builds newer than $(build_floor)"
  if [ "$REQUIRE_SIG" = 1 ]; then
    echo "signers:   $(cut -d' ' -f1 "$ALLOWED_SIGNERS" | tr '\n' ' ')"
  else
    echo "ota:       DISABLED - built without signing; updates require a reflash"
  fi
}

cmd_verify() {
  [ $# -eq 1 ] || usage
  require_ota_enabled
  set_source "$1"
  fetch_and_check_manifest 1
  log "bundle verifies; not installed"
}

cmd_update() {
  local reboot=1 allow_downgrade=0 src=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-reboot) reboot=0 ;;
      --allow-downgrade) allow_downgrade=1 ;;
      -*) usage ;;
      *) [ -z "$src" ] || usage; src="$1" ;;
    esac
    shift
  done
  [ -n "$src" ] || usage
  require_ota_enabled
  set_source "$src"

  local cur com tgt part mf version build fsFile fsSum rawSum rawSize bootFile bootSum stage
  cur=$(current_slot)
  com=$(committed_slot)
  [ "$cur" = "$com" ] || die "running an uncommitted trial of slot $cur; commit or abort first"
  tgt=$(other_slot "$cur")
  part=$(part_for_slot "$tgt")

  [ "$(readlink -f "$part")" != "$(readlink -f "$(findmnt -no SOURCE /nix/store)")" ] \
    || die "refusing to overwrite the running slot ($part)"
  [ -z "$(findmnt -rno TARGET "$part" || true)" ] || die "$part is mounted"

  fetch_and_check_manifest "$allow_downgrade"
  mf="$WORK/manifest.json"
  version=$(jq -r .version "$mf")
  build=$(jq -r .build "$mf")
  fsFile=$(jq -r .slotfs.file "$mf")
  fsSum=$(jq -r .slotfs.sha256 "$mf")
  rawSum=$(jq -r .slotfs.rawSha256 "$mf")
  rawSize=$(jq -r .slotfs.rawSize "$mf")
  bootFile=$(jq -r .boot.file "$mf")
  bootSum=$(jq -r .boot.sha256 "$mf")
  case "$fsFile$bootFile" in */* | *..*) die "manifest file names must be plain names" ;; esac
  is_uint "$rawSize" || die "manifest has no valid slot image size"

  log "downloading $version"
  fetch "$fsFile" "$WORK/$fsFile"
  fetch "$bootFile" "$WORK/$bootFile"
  echo "$fsSum  $WORK/$fsFile" | sha256sum -c --quiet - || die "checksum mismatch: $fsFile"
  echo "$bootSum  $WORK/$bootFile" | sha256sum -c --quiet - || die "checksum mismatch: $bootFile"

  [ "$rawSize" -le "$(blockdev --getsize64 "$part")" ] \
    || die "image ($rawSize bytes) is larger than slot partition $part"

  log "writing slot $tgt ($part)"
  zstd -dc "$WORK/$fsFile" | dd of="$part" bs=4M conv=fsync status=none
  # Read back what landed on the card - catches bad SD writes, not just bad downloads.
  # Flush the block device's cache first so the read really comes from the card.
  blockdev --flushbufs "$part"
  [ "$(head -c "$rawSize" "$part" | sha256sum | cut -d' ' -f1)" = "$rawSum" ] \
    || die "read-back verification of $part failed"

  log "installing boot files into $FW/slot_$tgt"
  stage="$FW/slot_${tgt}.new"
  rm -rf "$stage"
  mkdir -p "$stage"
  # Unpack on STATE (ext4) first, then copy onto FAT: an archive may hold hard links (older
  # bundles did), which FAT can't store. cp -r writes each link as a separate file.
  mkdir -p "$WORK/boot"
  zstd -dc "$WORK/$bootFile" | tar --no-same-owner --no-same-permissions -x -C "$WORK/boot" -f -
  cp -r "$WORK/boot/." "$stage/"
  printf '%s abslot=%s\n' "$(cat "$stage/cmdline.base")" "$tgt" > "$stage/cmdline.txt"
  rm -rf "$FW/slot_$tgt"
  mv "$stage" "$FW/slot_$tgt"
  write_cfg "$FW/tryboot.txt" "$tgt"
  echo "$version build $build" > "$STATE/pending"
  sync

  log "slot $tgt staged with $version (build $build)"
  if [ "$reboot" = 1 ]; then
    log "rebooting into a one-shot trial of slot $tgt"
    systemctl reboot --reboot-argument="0 tryboot"
  else
    log "run: systemctl reboot --reboot-argument=\"0 tryboot\""
  fi
}

cmd_commit() {
  local cur com rb
  cur=$(current_slot)
  com=$(committed_slot)
  mkdir -p "$STATE"
  # Raise the anti-rollback floor to the build we are running (on every boot, so a fresh
  # card records its build too).
  rb=$(running_build)
  if is_uint "$rb" && [ "$rb" -gt "$(build_floor_recorded)" ]; then
    echo "$rb" > "$STATE/min-build.tmp"
    mv -f "$STATE/min-build.tmp" "$STATE/min-build"
  fi
  if [ "$cur" = "$com" ]; then
    log "slot $cur already committed"
    return 0
  fi
  write_cfg "$FW/config.txt" "$cur"
  write_cfg "$FW/tryboot.txt" "$cur"
  if [ -f "$STATE/pending" ]; then mv -f "$STATE/pending" "$STATE/committed"; fi
  log "committed slot $cur"
}

build_floor_recorded() {
  local rec=0
  if [ -f "$STATE/min-build" ]; then rec=$(tr -d '[:space:]' < "$STATE/min-build"); fi
  if is_uint "$rec"; then echo "$rec"; else echo 0; fi
}

cmd_leave_trial() { # cmd_leave_trial <reason>
  local cur com
  cur=$(current_slot)
  com=$(committed_slot)
  if [ "$cur" = "$com" ]; then
    log "not in a trial boot"
    return 0
  fi
  log "$1; rebooting into committed slot $com"
  systemctl reboot
}

cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  status) cmd_status ;;
  verify) cmd_verify "$@" ;;
  update) cmd_update "$@" ;;
  commit) cmd_commit ;;
  abort) cmd_leave_trial "trial aborted by user" ;;
  trial-timeout) cmd_leave_trial "trial was not committed in time" ;;
  *) usage ;;
esac
