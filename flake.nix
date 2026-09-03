{
  description = "agency PureScript development toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # nixpkgs unstable dropped x86_64-darwin; re-add when a supported nixpkgs provides it.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };

      # nixpkgs' `spago` is the legacy 0.21 CLI. The project uses the
      # registry-based Spago 1 CLI, whose npm tarball is a self-contained
      # Node bundle, so pin that exact release in a small Nix derivation.
      spagoFor = system:
        let pkgs = pkgsFor system; in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "spago";
          version = "1.0.4";
          src = pkgs.fetchzip {
            url = "https://registry.npmjs.org/spago/-/spago-1.0.4.tgz";
            hash = "sha256-93DGEspzPS+XeqAlxkek+ubDW6FbVbpscO2QvRGKIfg=";
            stripRoot = true;
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            mkdir -p "$out/lib/spago" "$out/bin"
            cp -R . "$out/lib/spago"
            makeWrapper "${pkgs.nodejs}/bin/node" "$out/bin/spago" \
              --add-flags "$out/lib/spago/bin/bundle.js"
          '';
          dontFixup = true;
        };
    in
    {
      # Dev shell with the PureScript toolchain used by the project.
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          spago = spagoFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.purescript
              spago
              pkgs.esbuild
              pkgs.bats
              pkgs.nickel
              pkgs.nodejs
              pkgs.just
            ];
          };
        });
    };
}
