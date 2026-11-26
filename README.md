# pi0MeshNode

NixOS image generator for Raspberry Pi **Zero / Zero W**, **Zero 2 W**, **3** and **4**, running
**meshtasticd** (Elecrow MeshStick radio and I2C sensors by default) and **Tailscale**, with:

- **systemd everywhere** – PID 1 *and* the initrd (the only initrd nixpkgs still has)
- **tmpfs root, Nix-free device** – `/` is tmpfs; `/nix/store` is a read-only **EROFS** image per
  slot; no Nix daemon, store DB or `/nix/var` on the node; only `/boot/state` is writable and persistent
- **fast boot** – no Perl activation (`/etc` overlay image + userborn), lz4hc initrd, lz4hc or
  uncompressed store
- **A/B slots with signed OTA** – firmware `tryboot` one-shot trial boots, automatic fallback;
  bundles must be signed by a trusted SSH key (hardware keys like a TKey or YubiKey work) and be
  newer than anything the node has run
- **Tailscale pre-enrollment** – auth key injected per device after the build, used once, then shredded
- **Factory reset** – drop a `FACTORY_RESET` file on the boot partition from any PC

> Status: template. It has not been evaluated or built yet. See [Verify first](#verify-first).

## Layout

```
flake.nix                 boards × build systems → images + OTA bundles
boards/                   pi0 (armv6l, cross), pi02w / pi3 / pi4 (aarch64)
hosts/default.nix         fleet-wide settings: SSH keys, OTA signers (from keys/), radio, tailscale flags
keys/                     trusted OTA signing public keys (keys/<name>.pub) - see keys/README.md
modules/
  base.nix                filesystems (tmpfs root, slot, state), factory reset, users, networkd
  rpi-boot.nix            direct firmware boot: config.txt / tryboot.txt / slot_X/ contents
  ab-image.nix            SD image + OTA bundle builders
  ota.nix                 meshnode-ota CLI, health check → boot-complete.target → commit
  node-config.nix         imports per-device files from the boot partition
  tailscale.nix           enrollment, Pi Zero quirks
  meshtastic.nix          meshtasticd: MeshStick radio preset, I2C sensors
pkgs/tailscale-static-arm.nix   pinned Tailscale 1.62.0 static ARM binary (Pi Zero)
scripts/meshnode-ota.sh         on-device updater (packaged by ota.nix)
scripts/meshnode-factory-reset.sh  on-device factory reset, `--force` to confirm (packaged by base.nix)
scripts/sign-ota.sh             sign an OTA bundle on your workstation (key file, FIDO key or ssh-agent)
scripts/personalize-image.sh    inject hostname / tskey / Wi-Fi / SSH keys into a built image
```

### Disk

| # | Label      | FS   | Mounted at       | Contents |
|---|------------|------|------------------|----------|
| 1 | `FIRMWARE` | vfat | `/boot/firmware` | Pi firmware, `config.txt`, `tryboot.txt`, `common.txt`, `slot_a/`, `slot_b/`, `node/` |
| 2 | slot A     | erofs | `/nix/store` (if active) | read-only image of the whole system closure |
| 3 | slot B     | erofs | `/nix/store` (if active) | same, written by OTA (empty on a fresh card) |
| 4 | `STATE`    | ext4 | `/boot/state`    | tailscale, meshtasticd, SSH host keys, machine-id, users/groups, OTA state |

`/` is tmpfs. `/etc` is an overlay of a prebuilt EROFS image (`system.etc.overlay`), with a
writable layer on tmpfs. Directories in `meshnode.state.directories` are bind-mounted from
`/boot/state`. The initrd chooses the slot from `abslot=a|b` on the kernel command line. A udev
rule maps that to the partition with PARTUUID `4d455348-02` or `-03`
(`meshnode.image.diskId`) and exposes it as `/dev/disk/by-slot/active`. Slots carry no per-slot
label, so an update is a plain raw write.

There is no Nix on the device (`nix.enable = false`). The binaries still need their
`/nix/store/...` paths, so the store is mounted there, but read-only and with nothing that could
install or change packages.

STATE is its own ext4 partition, not a folder on the FAT partition: FAT has no ownership or
permissions, which sshd host keys and non-root services such as meshtasticd need. It is mounted
under `/boot`, and you reset it from the FAT partition (see below).

## Build

Requires a Linux builder (on macOS use a remote builder or nix-darwin's `linux-builder`).

Images refuse to build until at least one OTA signing key is trusted. Add yours first: see
[keys/README.md](keys/README.md).

```sh
nix flake lock

# aarch64 boards: build *on* aarch64-linux (native, or x86 with
# boot.binfmt.emulatedSystems = [ "aarch64-linux" ]) to hit the binary cache.
nix build .#packages.aarch64-linux.pi4-image
nix build .#packages.aarch64-linux.pi02w-ota

# Pi Zero (armv6l) is always cross-compiled. There is no cache, so the first build
# compiles the whole closure (expect hours).
nix build .#packages.x86_64-linux.pi0-image
```

Outputs:

- `*-image` → `meshnode-<board>-<version>.img.zst` + `layout.env`
- `*-ota`   → `manifest.json`, `slotfs.img.zst`, `boot.tar.zst`

The version is `0.1.0+<git short rev>`. It is set in `flake.nix` and baked into `/etc/meshnode-release`.

## Access

- **Password SSH is on** (`meshnode.ssh.passwordAuth`) for the `meshtastic` user. Set its hash
  in `hosts/default.nix` (`nix shell nixpkgs#mkpasswd -c mkpasswd`). Until you do, the placeholder
  `"!"` means no password works. Root login is disabled; `sudo` needs no password.
- **SSH keys** still work too: fleet-wide in `meshnode.sshKeys`, or per device with
  `personalize-image.sh -s`.
- **Tailscale SSH** (`meshnode.tailscale.ssh = true`): `tailscale ssh meshtastic@node-01`,
  authenticated by your tailnet ACLs, with no password or key.
- SSH (password and keys) listens on every interface, LAN and tailnet alike. Nodes are expected
  to sit behind a firewall or other network appliance. The repo is public, so treat the password
  hash as public too and use a long random password.

## Personalize and flash

A built image is generic: every card flashed from it is identical. Per-device settings and secrets
(hostname, Tailscale auth key, Wi-Fi, extra SSH keys) are added to the card's FIRMWARE (FAT)
partition **after** the build, in a `node/` folder. They never enter the Nix store, a binary cache,
the repo or an OTA bundle.

Every file is optional. A card with none of them boots with the default hostname, uses Ethernet
only and stays off the tailnet until you enroll it by hand (see below).

| File in `node/` | Script flag | What it does |
| --- | --- | --- |
| `node.env` | `-n <hostname>` (required) | `NODE_HOSTNAME=<name>` sets the hostname (and the Tailscale machine name) |
| `tailscale-authkey` | `-k <file>` | a `tskey-auth-...` key on one line. Enrolls the node on first boot |
| `wpa_supplicant.conf` | `-w <file>` | Wi-Fi networks (below) |
| `authorized_keys` | `-s <file>` | extra SSH public keys for the `meshtastic` user |

### 1. Get a Tailscale auth key

In the Tailscale admin console: **Settings → Keys → Generate auth key**.

- **Pre-approved:** on, if your tailnet requires device approval.
- **Tags:** e.g. `tag:meshnode` (define it in your ACL `tagOwners` first). A tagged node has
  no owner key expiry, so it doesn't drop off the tailnet after 180 days.
- **Reusable:** off for one node; on (with a short expiration) to enroll a batch with one key.
- **Ephemeral:** off, so the node keeps its tailnet identity.

Save the key in `secrets/` at the repo root, with nothing else in the file. `.gitignore` excludes
`secrets/`, and flakes only copy git-tracked files into the Nix store, so it stays out of both:

```sh
mkdir -p secrets && chmod 700 secrets
printf '%s\n' 'tskey-auth-XXXXXXXX-YYYYYYYYYYYY' > secrets/tskey-node-01
chmod 600 secrets/tskey-node-01
```

Ignored isn't the same as protected: `secrets/` is still synced by iCloud/Dropbox if the repo lives
in a synced folder, and building with an explicit `path:` flake reference (instead of `.`) copies
the whole directory into the store. Build with `.` as shown, and delete keys you've used.

Tailscale SSH (`--ssh`) is already turned on by `meshnode.tailscale.ssh` in `hosts/default.nix`.
Tags and approval come from the key, so no per-device flags are needed. Fleet-wide `tailscale up`
flags go in `meshnode.tailscale.extraUpFlags`.

### 2a. Add it to the image before flashing (scriptable)

```sh
nix develop      # provides zstd + mtools (also on macOS)
scripts/personalize-image.sh \
  -i pi0-image/meshnode-pi0-*.img.zst \
  -o node-01.img \
  -n node-01 \
  -k secrets/tskey-node-01 \
  -w secrets/wifi.conf \
  -s secrets/extra_authorized_keys
```

`-i` is the `.img.zst` inside the `nix build` output link (`result/` if you didn't pass `-o`).
The script unpacks it to `node-01.img` and copies the files into `node/`. The image itself is not
modified. Flash `node-01.img` with balenaEtcher, Raspberry Pi Imager ("Use custom"), or `dd`, then
**delete `node-01.img`: it contains the key.**

```sh
sudo dd if=node-01.img of=/dev/<card> bs=4M conv=fsync status=progress   # Linux; /dev/rdiskN on macOS
rm node-01.img
```

### 2b. Or add it to an already-flashed card

Flash the plain image (Etcher can take the `.img.zst` directly), then re-insert the card. Its first
partition mounts as **FIRMWARE** on macOS, Windows and Linux. Before the card's first boot, put the
files in its `node/` folder (a `README.txt` there lists them):

```sh
cp secrets/tskey-node-01 /Volumes/FIRMWARE/node/tailscale-authkey   # macOS
echo NODE_HOSTNAME=node-01 > /Volumes/FIRMWARE/node/node.env
cp secrets/wifi.conf     /Volumes/FIRMWARE/node/wpa_supplicant.conf   # optional
diskutil eject /Volumes/FIRMWARE
```

The file names must match exactly. Leave out `.txt` extensions: in TextEdit, use Format → Make
Plain Text and untick "If no extension is provided, use .txt".

### Wi-Fi file

```
country=US
network={
    ssid="MyNetwork"
    psk="password"
}
network={
    ssid="Backup"
    psk="password2"
}
```

`wpa_passphrase "MyNetwork" "password"` prints a block with a hashed `psk=` if you'd rather not keep
the plain password. The Pi Zero W only sees 2.4 GHz networks.

### What happens on first boot

1. `meshnode-node-config` moves `node/*` to `/boot/state/meshnode/node` (mode 0600) and deletes the
   copies on FAT, then sets the hostname and installs the Wi-Fi networks.
2. nixpkgs' `tailscaled-autoconnect` runs `tailscale up --auth-key=file:…`.
3. Once the backend reports `Running`, `meshnode-tailscale-key-cleanup` shreds the key. The node's
   tailnet identity stays in `/boot/state/tailscale`, so reboots and OTA updates keep it.

A **factory reset** wipes that identity: add a fresh key to `node/` (2b) before the next boot.
Expired or already-used keys fail quietly. Check with `journalctl -u tailscaled-autoconnect -b`.

### Enroll by hand instead

With no key on the card, SSH in over Ethernet or Wi-Fi as `meshtastic` and run:

```sh
sudo tailscale up --ssh                      # prints a login URL to open in a browser
sudo tailscale up --ssh --auth-key=tskey-auth-...   # or with a key
```

The identity persists in `/boot/state` the same way.

## OTA updates (A/B)

A node has two OS slots. One holds the running, committed system. An update is written to the
other slot and booted **once** as a trial. It is only made permanent after it proves healthy.
Nodes only accept bundles that are **signed** by a trusted key and **newer** than anything they
have run. There is no unsigned mode: an image built with
`meshnode.ota.requireSignature = false` has OTA disabled entirely and refuses every bundle, so
those nodes are updated by reflashing.

### 1. Make a release

Change whatever you need (modules, `hosts/default.nix`, a `nixpkgs` bump via `nix flake update`),
then commit. Every commit is a new release:

- The version string is `0.1.0+<git short rev>`, for humans. Bump the `0.1.0` in `flake.nix` for
  releases you want to name. Builds from a dirty tree are tagged `+<rev>-dirty`.
- The build number is the commit time (`self.lastModified`). It's what nodes compare for
  anti-rollback, so release from committed trees.

Keep the slot image under `meshnode.image.rootSizeMiB` (2560 MiB by default). Slot size is fixed
when a card is flashed, and the image build fails loudly if the system no longer fits.

### 2. Build the bundle

Bundles are per board, and `meshnode-ota` refuses a bundle built for a different board:

```sh
nix build .#packages.aarch64-linux.pi4-ota   -o ota-pi4
nix build .#packages.aarch64-linux.pi02w-ota -o ota-pi02w
nix build .#packages.x86_64-linux.pi0-ota    -o ota-pi0    # cross
```

Each output directory contains:

| File | What |
|------|------|
| `manifest.json`  | `format`, `board`, `version`, `build`, `toplevel` store path, file names + sha256 |
| `slotfs.img.zst` | the slot's EROFS image (the store), zstd-compressed for transfer; the manifest also carries the raw size + sha256 |
| `boot.tar.zst`   | contents of `slot_X/` on FIRMWARE: kernel, initrd, DTBs, overlays, `cmdline.base` |

No secrets are in a bundle, so the same bundle serves every node of that board.

### 3. Sign it

```sh
scripts/sign-ota.sh -k ~/.ssh/meshnode-ota ota-pi4      # key file or YubiKey sk handle
scripts/sign-ota.sh -k keys/raine-tkey.pub ota-pi4      # key held in ssh-agent (TKey)
```

This copies the bundle out of the read-only Nix store to `signed/<board>-<build>/`. It adds
`manifest.json.sig` (an OpenSSH signature, namespace `meshnode-ota`) and checks it against
`keys/*.pub`, the same keys the images trust. The manifest pins the payload hashes, board and
build, so the one signature covers the whole bundle. Signing happens outside Nix, so the private
key never touches the store. Key setup, hardware keys and rotation are in
[keys/README.md](keys/README.md).

### 4. Publish it

Publish the **signed** directory. Any static HTTP(S) server or plain directory works;
`meshnode-ota` only fetches files relative to the bundle location. Serving over the tailnet is
simplest:

```sh
cd signed/pi4-<build> && python3 -m http.server 8080   # http://<builder>.<tailnet>.ts.net:8080
# or: tailscale serve --bg --set-path /pi4 "$PWD"    # https://<builder>.<tailnet>.ts.net/pi4
```

Or copy it to the node and apply it from disk. Put it under `/boot/state`, since the tmpfs root
is small:

```sh
rsync -a signed/pi4-<build>/ meshtastic@node-01:/boot/state/ota-pi4/
```

Because bundles are signed, the server and the network don't need to be trusted. A tampered,
re-signed or replayed bundle is refused by the node. Serving over the tailnet still keeps it
private.

### 5. Apply it on the node

```sh
sudo meshnode-ota status                                 # slots, build, signers, anti-rollback floor
sudo meshnode-ota verify http://builder.tailnet:8080     # optional: check without installing
sudo meshnode-ota update http://builder.tailnet:8080     # or a directory, or …/manifest.json
```

`update` does the following, then reboots:

1. Refuses to run if the node is already in an uncommitted trial.
2. Downloads `manifest.json` and `manifest.json.sig` to `/boot/state/meshnode/ota/`. It verifies
   the signature against the trusted keys baked into the running image, and stops right there if
   the bundle is unsigned, signed by an unknown key, or altered. Only then does it trust the
   manifest's contents.
3. Checks `board`, and refuses a `build` that isn't newer than both the running build and the
   newest build this node has ever committed. `--allow-downgrade` overrides that, for reinstalls
   and deliberate downgrades.
4. Downloads both payloads and verifies their sha256 sums against the signed manifest.
5. Checks that the image fits, streams it raw onto the **inactive** slot partition (never the one
   mounted at `/nix/store`), flushes the cache, and reads it back from the card to verify the raw
   sha256.
6. Unpacks `boot.tar.zst` into `slot_X.new/` on FIRMWARE, writes `cmdline.txt`
   (`… abslot=X`), and swaps it into place as `slot_X/`.
7. Points `tryboot.txt` at the new slot, records the pending version, and syncs.
8. Runs `systemctl reboot --reboot-argument="0 tryboot"`. The firmware reads `tryboot.txt` for
   this one boot only.

To stage now and reboot later: `meshnode-ota update <bundle> --no-reboot`, then
`systemctl reboot --reboot-argument="0 tryboot"`. A plain reboot just boots the old slot again.

### 6. Trial boot → commit or roll back

On the trial boot:

- `meshnode-ota-health` waits up to `meshnode.ota.healthTimeoutSec` (180 s) for every unit in
  `meshnode.ota.healthUnits` (sshd, tailscaled, meshtasticd by default) to be active. It then runs
  `meshnode.ota.extraHealthCheck`. Passing lets `boot-complete.target` be reached.
- `meshnode-ota-commit` runs after `boot-complete.target` and rewrites `config.txt` (and resets
  `tryboot.txt`) to the new slot. The update is now permanent. It also raises the anti-rollback
  floor (`/boot/state/meshnode/ota/min-build`) to this build. A failed trial never raises it, so
  you can retry with a fixed build.

The node falls back to the previous slot automatically if:

| Situation | What happens |
|-----------|--------------|
| a health check fails | no commit; `meshnode-ota-trial-timeout` reboots after `meshnode.ota.trialTimeout` (15 min, time to SSH in and look) |
| kernel panic / hang | the hardware watchdog (15 s) resets the board |
| power loss during the trial | the tryboot flag doesn't survive power-off |
| you change your mind | `sudo meshnode-ota abort` |

In every case the next boot reads `config.txt`, which still points at the old slot. State in
`/boot/state` is shared by both slots, so a rolled-back node keeps its Tailscale identity and
mesh DB.

### 7. Confirm

```sh
sudo meshnode-ota status         # state: committed, running == committed
cat /etc/meshnode-release        # <board> <version>
journalctl -b -u meshnode-ota-health -u meshnode-ota-commit
```

After a successful update the old system is still in the other slot. It is overwritten by the
*next* update. `nixos-rebuild switch` is intentionally not wired up; OTA bundles are the only
update path.

**Not A/B-protected:** the shared firmware blobs (`bootcode.bin`, `start*.elf`, `fixup*.dat`) and
`common.txt` at the top of FIRMWARE. Bundles only replace `slot_X/`, so changing those files
(e.g. a firmware bump or a new `meshnode.rpi.extraConfig`) needs a reflash.

This uses the firmware's `os_prefix` + `tryboot.txt` mechanism rather than
[Raspberry Pi Connect's A/B updates](https://github.com/raspberrypi/documentation/blob/master/documentation/asciidoc/services/connect/ab-boot-update.adoc).
That service is built on `rpi-image-gen` and only supports Pi 4 and later. The Pi 4 could also use
partition-level `autoboot.txt` (`tryboot_a_b=1`), but sticking to one scheme keeps all four boards
on the same code path.

## Radio and sensors

meshtasticd is configured for the **Elecrow MeshStick** out of the box: a CH341 USB-to-SPI
bridge with an SX1262 (TCXO, up to 22 dBm). `modules/meshtastic.nix` carries the settings from
upstream's `lora-usb-meshstick-1262.yaml` and a udev rule so meshtasticd (as its own user) can
reach the CH341 (`1a86:5512`) through libusb. Plug the stick in and set the region and channels
from the Meshtastic app or CLI; that config lives in `/boot/state`. On a Pi Zero / Zero 2 W the
stick needs a USB OTG adapter on the data port.

- **Several sticks on one node:** pin one with `meshnode.meshtastic.usbSerial = "<CH341 serial>"`
  (see `lsusb -v -d 1a86:5512`).
- **Heltec T114 as the radio:** flash it with [t114-ch341](https://github.com/pcs3rd/t114-ch341)
  and set `meshnode.meshtastic.radio = "t114-ch341"`. It looks like a MeshStick on USB
  (`1a86:5512`), so the same udev rule and `usbSerial` pinning apply. Its status LEDs are
  turned off once the node has been up 30 s (and right away if the T114 is plugged in later):
  a udev rule matching the T114's USB product string starts `meshnode-t114-leds.service`,
  which runs `t114ctl brightness 0`. MeshSticks are never sent the request. Change the delay
  with `meshnode.meshtastic.t114.ledsOffAfterBoot = <seconds>`, or keep the LEDs on with
  `= null`. `t114ctl` is on the image if you want them back: `sudo t114ctl brightness 24`.
- **Other radios (SPI HATs, other USB sticks):** set `meshnode.meshtastic.radio = "custom"` and
  translate the matching file from meshtastic/firmware `bin/config.d/` into
  `services.meshtasticd.settings.Lora`. Any single MeshStick value can also be overridden there.

**I2C sensors** are enabled by default. `/dev/i2c-1` (SDA GPIO2 / SCL GPIO3 on the 40-pin
header) is passed to meshtasticd as `I2C.I2CDevice`, and meshtasticd auto-detects supported
sensors on it (temperature/humidity/pressure and similar). The image sets `dtparam=i2c_arm=on`,
loads `i2c-dev`, and adds meshtasticd's user to the `i2c` group. Change the bus with
`meshnode.meshtastic.i2c.device`, or turn it off with `meshnode.meshtastic.i2c.enable = false`.

**On-node overrides without a rebuild:** meshtasticd also reads every `*.yaml` in
`/boot/state/meshtasticd/config.d/` (`General.ConfigDirectory`). That directory is on the state
partition, so files there survive reboots and OTAs; a factory reset clears them. Restart
meshtasticd after adding one. The startup log lists each file it picks up as `Also using "…" as
additional config file`. Values in those files override the image's config.

**Web client** (`meshnode.meshtastic.web`, on by default): meshtasticd serves the Meshtastic web
app over HTTPS on port 9443. It and the 4403 API are reachable **only over Tailscale**: the
firewall trusts `tailscale0` and doesn't open either port on Ethernet or Wi-Fi. Browse to
`https://<node's tailnet IP or MagicDNS name>:9443`. The certificate is self-signed (generated by
`meshtasticd-web-cert.service` on first boot and kept in `/boot/state`), so expect one browser warning per node. For a trusted
certificate instead, run `sudo tailscale serve --bg https+insecure://localhost:9443` on the node
and use `https://<node>.<tailnet>.ts.net`; this needs HTTPS certificates enabled for your tailnet.

**GPS** (any 3.3 V UART GPS, such as an HGLRC M100 Mini) on the header UART is enabled by default:

- **`mode = "serial"`** (default): meshtasticd reads the module directly (`GPS.SerialPath`).
- **`mode = "gpsd"`**: gpsd owns the module, meshtasticd reads it from gpsd (`GPS.GpsdHost`),
  and chrony sets the system clock from it. Use this on off-grid nodes: the Pi has no real-time
  clock, so without network time a node boots with the wrong time. Wire the module's PPS pin
  to a GPIO and set `meshnode.meshtastic.gps.ppsGpio = <BCM number>` for sub-millisecond time.
  Without PPS (the default, and e.g. the M100 Mini, which has no PPS pin) chrony uses the
  NMEA sentence timing, which is good to roughly 100 ms. That's plenty for logs and TLS on a
  node with no RTC.
  gpsd and chrony add some RAM and closure, which matters on a Zero.

Enabling GPS takes the kernel console and serial login off pins 8/10, since they share them
(`meshnode.rpi.serialConsole`). The kernel console always goes to `tty1` instead; with no
`console=` at all, the kernel would fall back to the header UART. HDMI is off by default too
(`meshnode.rpi.hdmi = false`): the firmware keeps the HDMI output powered down, about 25 mA saved
on a Zero, and there are no virtual terminals. With both off, a node is reachable only over the
network (SSH or Tailscale SSH). Set `meshnode.rpi.hdmi = true` on a bench node.

The GPS is read from `/dev/serial0`. As on Raspberry Pi OS, a udev rule links that to whichever
UART the firmware routed to pins 8/10. The image also adds `dtoverlay=disable-bt`
(`gps.disableBluetooth`), which should put the full PL011 UART there instead of the weaker mini
UART on Bluetooth boards (Zero W, Zero 2 W, 3, 4). Either UART works for NMEA. Wi-Fi is
unaffected. meshtasticd probes the module's baud rate itself. If it never
gets a fix, check the raw output with `stty -F /dev/serial0 9600 && cat /dev/serial0` (try
115200 too): readable `$GN…`/`$GP…` sentences mean the wiring is right. Disable GPS with
`meshnode.meshtastic.gps.enable = false`.

**Wiring** (physical header pins; same on every 40-pin Pi). Power both from 3.3 V: the Pi's
GPIOs aren't 5 V tolerant.

| Device | Signal | Pi pin |
|--------|--------|--------|
| GPS | VCC | 1 (3.3 V) |
| GPS | GND | 6 (GND) |
| GPS | TX → | 10 (GPIO15, RXD) |
| GPS | RX ← | 8 (GPIO14, TXD) |
| GPS | PPS (only if the module has one; gpsd mode) | e.g. 12 (GPIO18) → `ppsGpio = 18` |
| I2C sensor (BME280/680 …) | VIN | 17 (3.3 V) |
| I2C sensor | GND | 9 (GND) |
| I2C sensor | SDA | 3 (GPIO2) |
| I2C sensor | SCL | 5 (GPIO3) |

GPS TX goes to Pi RX and vice versa. Swapped TX/RX is the most common reason a GPS shows
nothing. Several I2C sensors can share pins 3/5 as long as their addresses differ (BME
sensors are 0x76 or 0x77).

**USB Wi-Fi.** Atheros AR9271/AR7010 adapters (Netgear WNA1100, TP-Link TL-WN722N v1, Alfa
AWUS036NHA) work out of the box: the vendor kernel has `ath9k_htc`, and the image ships its
firmware (`meshnode.rpi.usbWifi.ath9kHtc`). They join the same networks as onboard Wi-Fi
(`node/wpa_supplicant.conf`). The Pi Zero has one USB data port, so a USB radio *and* a Wi-Fi
adapter need a hub, preferably a powered one: an AR9271 can draw a few hundred mA when
transmitting.

## Boot time

What's done to keep boot fast, especially on the single-core Pi Zero:

- **No Perl activation.** With a tmpfs root, activation runs from scratch every boot, so the Perl
  scripts are replaced:
  - `system.etc.overlay` mounts `/etc` from a prebuilt image instead of creating thousands of
    symlinks.
  - `services.userborn` sets up users and groups. Its files live in
    `/boot/state/var/lib/nixos/userborn`, so UIDs of persisted data never shift.
  - `system.switch.enable = false`.

  Once it builds, set `meshnode.forbidPerl = true` to fail the build if Perl creeps back in.
- **Less to read.** Nix is disabled, along with docs, default packages, fontconfig, the xdg
  databases, LVM, udisks and containers. nftables replaces the iptables firewall script.
- **Cheap decompression.**
  - The store slot is EROFS, set by `meshnode.image.slotCompression`: `lz4hc` by default, `none`
    on the Pi 0. lz4hc decompresses exactly as fast as lz4 and only costs build time. It uses
    EROFS's default 4K clusters, which keep random reads cheap.
  - The initrd is LZ4 at HC level (`-l -12`) instead of zstd.
- **Nothing waits on the network** (`wait-online` off).

The Raspberry Pi vendor kernel comes from nixos-hardware's kernel builder
(`raspberry-pi/common/kernel.nix`, selected by `meshnode.rpi.rpiVersion`), because nixpkgs
removed its `linux_rpi*` packages. Only the kernel builder is used. nixos-hardware's board
profiles boot through U-Boot/extlinux, which would bypass the firmware A/B path. This kernel isn't
in any binary cache, so every board builds it locally.

**Kernel trim** (`modules/kernel.nix`, `meshnode.rpi.kernelTrim`, on by default). The vendor
config builds drivers for everything a Pi can be plugged into. The image switches off whole
subsystems a headless mesh node never uses:
- graphics/DRM, sound, cameras/V4L2/DVB/IR, staging, Bluetooth
- CAN, NFC, AX.25, 802.15.4, IIO, 1-Wire, joysticks/touchscreens, USB serial, USB gadget mode,
  USB/IP
- Wi-Fi chips other than `brcmfmac` and `ath9k_htc`
- USB Ethernet other than `r8152`/`smsc95xx`/`lan78xx`/CDC
- filesystems beyond ext4/vfat/erofs/overlay/tmpfs/FUSE
- software RAID, TPM, MTD, powerline, 6LoWPAN, Open vSwitch

That roughly halves the module count, as checked against the vendor defconfigs:

| Vendor config (boards) | Modules | Built-in |
|---|---|---|
| `bcmrpi` (pi0) | 1806 → 812 | 1500 → 1181 |
| `bcm2711` (pi02w, pi3, pi4) | 1912 → 871 | 1953 → 1619 |

It runs in the kernel's `postConfigure` (`scripts/config --disable …`, then
`make olddefconfig`). It fails the build if it turns off anything the image relies on: SD/USB
hosts, the network and Wi-Fi drivers above, I2C/SPI, PPS, the watchdog, TUN, nftables, zram, the
filesystems, device-mapper and more. Extend it with `kernelTrim.extraDisable` /
`kernelTrim.extraKeep`, or turn it off with `kernelTrim.enable = false`. Deliberately kept:
netfilter (Tailscale, firewall), RTC drivers (for an add-on DS3231), hwmon (the Pi's
undervoltage monitor), bridge/VXLAN/WireGuard/batman-adv and generic HID. `boot.kernelPatches`
has no effect on this kernel: nixos-hardware's builder sets its own patch list.

Measure on hardware with `systemd-analyze critical-chain` / `systemd-analyze blame`. To see
what's heavy in the closure:
`nix path-info -rSh .#nixosConfigurations.pi3.config.system.build.toplevel | sort -k2 -h | tail`.

## Factory reset

Do either of these:

- Put the card in any computer and create an empty `FACTORY_RESET` file in the root of the
  `FIRMWARE` partition. Add fresh `node/` files next to it if the device should re-enroll.
- Run `sudo meshnode-factory-reset --force` on the node. `--force` is the only accepted
  argument and confirms intent; without it the script prints what will be erased and exits.

On the next boot the initrd reformats STATE before mounting it. This wipes the Tailscale identity,
the meshtastic node DB, SSH host keys, machine-id and the imported node files. The OS slots are
untouched.

## Pi Zero (original) quirks

Based on [this gist](https://gist.github.com/StrixROX/5b1b035351a00e5498ad6099e961c64d), on by
default for `board = "pi0"`:

- `meshnode.tailscale.pi0StaticBinary`: the pinned upstream static `tailscale_1.62.0_arm.tgz`
  instead of the nixpkgs build. `tailscale update` can't work on NixOS; bump `version` and `hash`
  in `pkgs/tailscale-static-arm.nix`.
- `meshnode.tailscale.userspaceNetworking`: `--tun=userspace-networking`. With it, the node is
  reachable over the tailnet (Tailscale SSH works), but it doesn't get a `tailscale0` interface for
  routing.
- Worth trying: `pi0StaticBinary = false` builds current Tailscale from nixpkgs with `GOARM=6`.
  The gist's segfaults may have been specific to the upstream static build.
- 512 MB RAM, one ARMv6 core: zram at 75%, 64 MB tmpfs root, volatile journald, uncompressed store slot.

## Customizing

- Radio hardware: see [Radio and sensors](#radio-and-sensors).
- OTA signers: `keys/*.pub` (see [keys/README.md](keys/README.md)).
- Board config.txt lines: `meshnode.rpi.extraConfig`.
- Persist another directory: add it to `meshnode.state.directories`.
- More OTA health gates: add units to `meshnode.ota.healthUnits`, or put shell in
  `meshnode.ota.extraHealthCheck` (for example, require `tailscale status` to be `Running`).

## Verify first

This template was written without a Nix evaluator, so expect a few fix-up rounds on the first
`nix build`. Check these first:

- [ ] `nix flake check` / eval of each `nixosConfigurations.<board>` (option names drift between
      nixpkgs releases, e.g. `networking.wireless.*`)
- [ ] bind mounts with `neededForBoot` resolve under `/sysroot` in the systemd initrd, and
      `meshnode-state-dirs` runs before them
- [ ] the udev `IMPORT{cmdline}="abslot"` + `ID_PART_ENTRY_UUID` rule creates
      `/dev/disk/by-slot/active` in the initrd, and `/nix/store` mounts from it as EROFS
- [ ] `system.etc.overlay`, `services.userborn.passwordFilesLocation` and `nix.enable = false`
      evaluate together, and nothing else in the closure expects a writable `/nix`
- [ ] `mkfs.erofs` flags (`-zlz4hc,12 --all-root -T0 -L`) match the erofs-utils in your nixpkgs
- [ ] the `extraStructuredConfig` EROFS/overlay options are accepted by the rpi kernel configs
- [ ] nixos-hardware's `raspberry-pi/common/kernel.nix` builds for each `rpiVersion`, and its DTB
      paths (`dtbs/` on armv6l, `dtbs/broadcom/` on aarch64, `dtbs/overlays/`) match `rpi-boot.nix`
- [ ] meshtasticd cross-builds via `modules/cross-fixes.nix` (build-machine platformio + cross
      gcc/pkg-config on PATH) and the result is an ARM binary; upstream lists only x86_64/aarch64
- [ ] the static Tailscale package works with the NixOS tailscale module (it uses `systemd.packages`)
- [ ] on hardware: `reboot "0 tryboot"` selects `tryboot.txt` on Zero / Zero 2 W / 3 firmware, and
      `meshnode-ota commit` and rollback both behave
- [ ] `lib.trim` exists in your nixpkgs (used by `modules/ota.nix` to normalise keys)
- [ ] meshtasticd reaches the MeshStick as its own user (udev rule + libusb), and
      `services.meshtasticd.user`/`group` exist under those option names
- [ ] `dtoverlay=disable-bt` takes effect (on a Zero W it didn't: `ttyAMA1` stayed bound to
      Bluetooth); the GPS works regardless via `/dev/serial0`, and
      the packaged meshtasticd version reads `GPS.SerialPath` / `GPS.GpsdHost`
- [ ] gpsd + chrony SHM/PPS refclocks lock (`chronyc sources`), and the closure cost on pi0
- [ ] imperative Wi-Fi path (`/etc/wpa_supplicant/imperative.conf` vs `/etc/wpa_supplicant.conf`)
