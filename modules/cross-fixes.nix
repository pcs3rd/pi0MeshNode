# Fixes for nixpkgs packages that don't cross-compile (pi0 is always cross-built; the aarch64
# boards are too when built from x86_64). Each override only applies when cross-compiling,
# so native builds keep the cached upstream packages.
{ lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev:
      let
        # Read platforms from prev: the overlay's attribute *names* must not depend on final,
        # and the decision whether to patch is made inside each attribute.
        isCross = prev.stdenv.buildPlatform != prev.stdenv.hostPlatform;
        prefix = prev.stdenv.cc.targetPrefix; # e.g. armv6l-unknown-linux-gnueabihf-
      in
      {
        # meshtasticd builds with `platformio run --environment native-tft`, which breaks
        # under cross in two ways:
        #  1. nixpkgs wraps platformio-core in overridePythonAttrs inside nativeBuildInputs.
        #     That drops splicing, so a *target* (armv6l) platformio gets built and then run
        #     on the build machine ("import: command not found").
        #  2. PlatformIO's "native" platform calls plain gcc/g++/ar and `pkg-config`, which
        #     on the build machine would produce an x86 binary.
        # Fix: use the build machine's platformio, and put the cross toolchain (and the cross
        # pkg-config) first on PATH under the unprefixed names PlatformIO calls.
        meshtasticd = if !isCross then prev.meshtasticd else prev.meshtasticd.overrideAttrs (old: {
          nativeBuildInputs =
            (lib.filter (p: lib.getName p != "platformio") old.nativeBuildInputs)
            ++ [
              (final.buildPackages.platformio-core.overridePythonAttrs (o: {
                dependencies = o.dependencies ++ [ final.buildPackages.python3Packages.grpcio-tools ];
              }))
            ];

          preBuild = (old.preBuild or "") + ''
            crossbin="$TMPDIR/meshnode-cross-bin"
            mkdir -p "$crossbin"
            for t in gcc g++ cc c++ cpp ar ranlib nm objcopy objdump strip ld as readelf size; do
              if p=$(command -v "${prefix}$t"); then ln -sf "$p" "$crossbin/$t"; fi
            done
            ln -sf "$(command -v "${prefix}pkg-config")" "$crossbin/pkg-config"
            export PATH="$crossbin:$PATH"
            echo "meshnode: cross-building meshtasticd with $(command -v gcc) -> $(gcc -dumpmachine)"
          '';

          # Fail loudly if PlatformIO still produced a build-machine binary.
          postInstall = (old.postInstall or "") + ''
            if ! ${final.buildPackages.file}/bin/file -L "$out/bin/meshtasticd" | grep -q ARM; then
              echo "meshtasticd was not cross-compiled for ARM:" >&2
              ${final.buildPackages.file}/bin/file -L "$out/bin/meshtasticd" >&2
              exit 1
            fi
          '';
        });
      })
  ];
}
