# OTA signing keys

Nodes install an OTA bundle only if its `manifest.json` carries a valid signature from one of
the keys in this directory. The manifest pins the sha256 of every payload, the target board and
a build number, so one signature covers the whole bundle.

- **Public keys live here** as `keys/<name>.pub`: one OpenSSH public key per file. `<name>`
  becomes the signer name nodes log and show in `meshnode-ota status`.
- **Private keys never go in this repo** (or in the Nix store). Signing happens after the build,
  in `scripts/sign-ota.sh`.

Signatures are standard OpenSSH signatures (`ssh-keygen -Y sign`, namespace `meshnode-ota`).
OpenSSH is already on every node, so verification adds nothing to the image.

## Set up a signing key

Pick one. Hardware-backed keys are best: the private key can't be copied off the device.

**Tillitis TKey** (with [`tkey-ssh-agent`](https://github.com/tillitis/tkey-ssh-agent)):

```sh
tkey-ssh-agent -a ~/.tkey-ssh-agent.sock &        # touch the TKey when it blinks
export SSH_AUTH_SOCK=~/.tkey-ssh-agent.sock
ssh-add -L > keys/raine-tkey.pub
```

The TKey derives its key from the app and your optional USS (`--uss`), so use the same USS
every time or you'll get a different key.

**YubiKey / FIDO2** (OpenSSH `-sk` keys):

```sh
ssh-keygen -t ed25519-sk -O resident -O application=ssh:meshnode-ota -f ~/.ssh/meshnode-ota-sk
cp ~/.ssh/meshnode-ota-sk.pub keys/raine-yubikey.pub
```

**Plain key file** (fine to start with; keep it offline or in a password manager):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/meshnode-ota -C meshnode-ota
cp ~/.ssh/meshnode-ota.pub keys/raine.pub
```

Then commit it. Flakes only see git-tracked files:

```sh
git add keys/raine-tkey.pub && git commit -m "Trust OTA signing key raine-tkey"
```

`hosts/default.nix` turns every `keys/*.pub` into `meshnode.ota.trustedKeys`. Images refuse to
build with no trusted keys. The one exception is `meshnode.ota.requireSignature = false`, which
builds an image with **OTA disabled**: its nodes refuse every bundle, signed or not, and can only
be updated by reflashing. There is no way to build a node that accepts unsigned updates.

## Sign a bundle

```sh
nix build .#packages.aarch64-linux.pi4-ota -o ota-pi4
scripts/sign-ota.sh -k ~/.ssh/meshnode-ota ota-pi4         # key file or sk handle
scripts/sign-ota.sh -k keys/raine-tkey.pub ota-pi4         # key in ssh-agent (TKey)
```

The script copies the bundle out of the read-only Nix store into `signed/<board>-<build>/`,
writes `manifest.json.sig`, and verifies it against `keys/*.pub`. If it says the signer isn't
trusted, nodes will reject the bundle too. Publish the `signed/...` directory, not the raw
`nix build` output.

Check a published bundle from a node without installing it:

```sh
sudo meshnode-ota verify https://builder.tailnet.ts.net/pi4
```

## Rotate or revoke a key

Nodes trust the keys baked into the image they're running, so key changes ship as an update:

1. Add the new key as `keys/<new>.pub`, keeping the old one. Build, sign with the **old** key
   (nodes don't trust the new one yet), and roll it out.
2. Once every node runs that release, remove the old `.pub`. Build, sign with the **new** key, and
   roll out.

To revoke a lost or compromised key, do step 2 straight away, signing with a key that's still
trusted. Nodes that never got the release that removed the key still trust it until they do.
That's another reason to prefer hardware keys and to keep at least two trusted keys (say a
daily TKey plus a backup kept offline).

## Anti-rollback

Each build carries a build number: the commit time of the flake source (`self.lastModified`).
A node refuses any bundle whose build number isn't newer than the one it's running *and* the
newest it has ever booted healthily (`/boot/state/meshnode/ota/min-build`). An attacker can't
replay an older, validly signed release with known bugs. A failed trial doesn't raise the floor,
so you can retry a fixed build. To reinstall or deliberately downgrade, pass
`meshnode-ota update <bundle> --allow-downgrade`. A factory reset clears the recorded floor
(the running build still applies).

## Keeping keys and fleet settings in a private repo

This repo is a public builder. To keep your trusted keys, password hash and other fleet settings
out of it, use a small private flake that takes this repo as an input and adds a module through
`lib.mkNode { extraModules = [ ... ]; }`. That flake:

- sets `meshnode.ota.trustedKeys` from its own `keys/*.pub` and forces
  `meshnode.ota.requireSignature = true` (overriding the temporary `false` here);
- sets `meshnode.buildNumber` to the newer of the two repos' commit times, so a commit to either
  repo produces a bundle nodes accept as newer;
- signs with `MESHNODE_KEYS_DIR=<fleet>/keys scripts/sign-ota.sh ...` (or `-K <fleet>/keys`), so
  the self-check runs against the keys its images actually trust.

Keys left in this repo's `keys/` are still trusted (the attrsets merge), so keep it empty when a
fleet repo owns the keys. Private keys stay out of both repos.
