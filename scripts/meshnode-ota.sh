# shellcheck shell=bash
# meshnode-ota - A/B OS updates for Raspberry Pi using the firmware "tryboot" flag.
# Packaged by modules/ota.nix (writeShellApplication adds the shebang and PATH).
#
# FIRMWARE (p1) holds shared firmware plus slot_a/ and slot_b/ (kernel, initrd, dtbs,
# overlays, cmdline.txt). config.txt picks the committed slot via os_prefix, tryboot.txt
# picks the candidate. `reboot "0 tryboot"` makes the firmware read tryboot.txt for
# exactly one boot; any later reboot falls back to config.txt.
# Slot images: p2 = slot A, p3 = slot B - read-only EROFS images of the whole closure,
# the active one mounted at /nix/store. An update is a verified raw write of the image.

set -euo pipefail

BOARD="@BOARD@"
FW=/boot/firmware
STATE=/boot/state/meshnode/ota
SRC=""
WORK=""

log() { echo "meshnode-ota: $*" >&2; }
die() { log "error: $*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: meshnode-ota <command>
  status                         show slots and trial state
  update <bundle> [--no-reboot]  install an OTA bundle (http(s) URL or directory that
                                 holds manifest.json) into the inactive slot, then
                                 reboot into it as a one-shot trial
  commit                         make the running trial slot permanent
                                 (normally run by meshnode-ota-commit.service)
  abort                          leave a trial now: reboot into the committed slot
  trial-timeout                  internal: run by meshnode-ota-trial-timeout.timer
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
}

cmd_update() {
  [ $# -ge 1 ] || usage
  SRC="${1%/}"
  SRC="${SRC%/manifest.json}"
  local reboot=1
  if [ "${2:-}" = "--no-reboot" ]; then reboot=0; fi

  local cur com tgt part mf version fsFile fsSum rawSum rawSize bootFile bootSum stage
  cur=$(current_slot)
  com=$(committed_slot)
  [ "$cur" = "$com" ] || die "running an uncommitted trial of slot $cur; commit or abort first"
  tgt=$(other_slot "$cur")
  part=$(part_for_slot "$tgt")

  [ "$(readlink -f "$part")" != "$(readlink -f "$(findmnt -no SOURCE /nix/store)")" ] \
    || die "refusing to overwrite the running slot ($part)"
  [ -z "$(findmnt -rno TARGET "$part" || true)" ] || die "$part is mounted"

  mkdir -p "$STATE"
  WORK=$(mktemp -d "$STATE/dl.XXXXXX") # on STATE: tmpfs root is too small on a Pi Zero
  trap cleanup EXIT

  mf="$WORK/manifest.json"
  fetch manifest.json "$mf"
  [ "$(jq -r .format "$mf")" = "2" ] || die "unsupported manifest format"
  [ "$(jq -r .board "$mf")" = "$BOARD" ] || die "bundle is for $(jq -r .board "$mf"), this node is $BOARD"
  version=$(jq -r .version "$mf")
  fsFile=$(jq -r .slotfs.file "$mf")
  fsSum=$(jq -r .slotfs.sha256 "$mf")
  rawSum=$(jq -r .slotfs.rawSha256 "$mf")
  rawSize=$(jq -r .slotfs.rawSize "$mf")
  bootFile=$(jq -r .boot.file "$mf")
  bootSum=$(jq -r .boot.sha256 "$mf")

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
  zstd -dc "$WORK/$bootFile" | tar --no-same-owner --no-same-permissions -x -C "$stage" -f -
  printf '%s abslot=%s\n' "$(cat "$stage/cmdline.base")" "$tgt" > "$stage/cmdline.txt"
  rm -rf "$FW/slot_$tgt"
  mv "$stage" "$FW/slot_$tgt"
  write_cfg "$FW/tryboot.txt" "$tgt"
  echo "$version" > "$STATE/pending"
  sync

  log "slot $tgt staged with $version"
  if [ "$reboot" = 1 ]; then
    log "rebooting into a one-shot trial of slot $tgt"
    systemctl reboot --reboot-argument="0 tryboot"
  else
    log "run: systemctl reboot --reboot-argument=\"0 tryboot\""
  fi
}

cmd_commit() {
  local cur com
  cur=$(current_slot)
  com=$(committed_slot)
  if [ "$cur" = "$com" ]; then
    log "slot $cur already committed"
    return 0
  fi
  write_cfg "$FW/config.txt" "$cur"
  write_cfg "$FW/tryboot.txt" "$cur"
  mkdir -p "$STATE"
  if [ -f "$STATE/pending" ]; then mv -f "$STATE/pending" "$STATE/committed"; fi
  log "committed slot $cur"
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
  update) cmd_update "$@" ;;
  commit) cmd_commit ;;
  abort) cmd_leave_trial "trial aborted by user" ;;
  trial-timeout) cmd_leave_trial "trial was not committed in time" ;;
  *) usage ;;
esac
