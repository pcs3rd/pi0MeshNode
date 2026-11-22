{
  description = "pi0MeshNode - NixOS A/B images (meshtasticd + tailscale) for Raspberry Pi Zero, Zero 2 W, 3 and 4";

  inputs = {
    # meshtasticd + services.meshtasticd live in recent nixpkgs; pin with `nix flake lock`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      version = "0.1.0+${self.shortRev or self.dirtyShortRev or "dirty"}";

      boards = {
        pi0 = { module = ./boards/pi0.nix; host = lib.systems.examples.raspberryPi; }; # armv6l, always cross
        pi02w = { module = ./boards/pi02w.nix; host = "aarch64-linux"; };
        pi3 = { module = ./boards/pi3.nix; host = "aarch64-linux"; };
        pi4 = { module = ./boards/pi4.nix; host = "aarch64-linux"; };
      };

      # Machines that can run the build. aarch64 boards built on aarch64-linux (native
      # or binfmt-emulated) hit the binary cache; built from x86_64-linux they cross-compile.
      buildSystems = [ "x86_64-linux" "aarch64-linux" ];
      shellSystems = buildSystems ++ [ "aarch64-darwin" "x86_64-darwin" ];

      mkNode = { board, buildSystem, extraModules ? [ ] }:
        lib.nixosSystem {
          modules = [
            self.nixosModules.default
            boards.${board}.module
            ./hosts/default.nix
            {
              nixpkgs.hostPlatform = boards.${board}.host;
              nixpkgs.buildPlatform = buildSystem;
              meshnode.version = lib.mkDefault version;
            }
          ] ++ extraModules;
        };

      perBoard = buildSystem: lib.concatMapAttrs (board: _:
        let node = mkNode { inherit board buildSystem; }; in {
          "${board}-image" = node.config.system.build.abImage;  # full card image (.img.zst)
          "${board}-ota" = node.config.system.build.otaBundle;  # OTA bundle (manifest.json + payloads)
        }) boards;
    in
    {
      nixosModules.default = ./modules;

      lib = { inherit mkNode boards; };

      nixosConfigurations = lib.mapAttrs (board: _: mkNode { inherit board; buildSystem = "x86_64-linux"; }) boards;

      packages = lib.genAttrs buildSystems perBoard;

      devShells = lib.genAttrs shellSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.mkShell { packages = with pkgs; [ mtools zstd jq ]; };
        });
    };
}
