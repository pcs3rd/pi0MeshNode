# Tailscale's upstream static 32-bit ARM build, pinned for the original Pi Zero (ARMv6).
# Per https://gist.github.com/StrixROX/5b1b035351a00e5498ad6099e961c64d newer static
# builds segfaulted on the Zero W, while 1.62.0 + --tun=userspace-networking works.
# `tailscale update` cannot work on NixOS - bump `version` + `hash` here instead, or try
# the nixpkgs cross build (meshnode.tailscale.pi0StaticBinary = false), which compiles
# with GOARM=6 for this target.
{ lib, stdenvNoCC, fetchurl }:

stdenvNoCC.mkDerivation rec {
  pname = "tailscale-static-arm";
  version = "1.62.0";

  src = fetchurl {
    url = "https://dl.tailscale.com/stable/tailscale_${version}_arm.tgz";
    hash = "sha256-//i8G01n26ksmrlDE+GIVrc9uvLGN3BE4uffl8NOoDg=";
  };

  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 tailscale $out/bin/tailscale
    install -Dm755 tailscaled $out/bin/tailscaled
    # The NixOS tailscale module uses the upstream unit via systemd.packages and feeds
    # PORT/FLAGS through Environment=, same as nixpkgs' own tailscale package.
    install -Dm644 systemd/tailscaled.service $out/lib/systemd/system/tailscaled.service
    sed -i -e "s#/usr/sbin#$out/bin#" -e "/^EnvironmentFile/d" $out/lib/systemd/system/tailscaled.service
    runHook postInstall
  '';

  meta = {
    description = "Tailscale ${version} static ARM binaries (Pi Zero / ARMv6)";
    homepage = "https://tailscale.com";
    license = lib.licenses.bsd3;
    mainProgram = "tailscale";
    platforms = [ "armv6l-linux" "armv7l-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
