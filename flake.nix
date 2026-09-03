{
  description = "agency PureScript development toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Binary-distributed Rust toolchains with cross targets (wasm32 std).
    # nixpkgs' own rustc cannot add wasm32-unknown-unknown, and
    # pkgsCross.wasm32-unknown-unknown.buildPackages.rustc does not exist
    # in this nixpkgs rev.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      # nixpkgs unstable dropped x86_64-darwin; re-add when a supported nixpkgs provides it.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };

      # nickel-lang-core 0.18.0's published crate evaluates the in-memory
      # source marker only after normalize_path, which fails on wasm32 where
      # current_dir is unavailable. Keep the one-line-order fix isolated in
      # nickel-vm/patches and apply it to the crate source used by the VM.

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

      # Pinned Rust toolchain with the wasm32-unknown-unknown std for
      # nickel-vm. Host rustup/cargo/rustc are not needed: the nix build
      # is the only producer of the WASM artifact.
      rustToolchainFor = system:
        let pkgs = pkgsFor system; in
        # The failure was in buildRustPackage's double-target hook: it
        # injected the host target before the requested wasm32 target.
        pkgs.rust-bin.stable."1.98.0".default.override {
          targets = [ "wasm32-unknown-unknown" ];
        };
      # rustPlatform built on the overlay toolchain so buildRustPackage
      # compiles with the same rustc that carries the wasm32 std.
      # rust-overlay's toolchain is a single derivation carrying both
      # rustc and cargo — pass it in both roles (the standard pattern).
      rustPlatformFor = system:
        let pkgs = pkgsFor system; in
        pkgs.makeRustPlatform {
          cargo = rustToolchainFor system;
          rustc = rustToolchainFor system;
        };
    in
    {
      # nickel-vm compiled to wasm32-unknown-unknown with wasm-bindgen
      # Node.js glue, ready to be copied into nickel-vm/dist/ (the
      # checked-in runtime plugin artifact).
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          rustPlatform = rustPlatformFor system;
          rustToolchain = rustToolchainFor system;
          nickelVmSrc = pkgs.lib.cleanSourceWith {
            src = ./nickel-vm;
            filter = path: type:
              (type == "directory" && pkgs.lib.hasSuffix "/src" path)
              || pkgs.lib.hasInfix "/src/" path
              || pkgs.lib.hasSuffix "/Cargo.toml" path
              || pkgs.lib.hasSuffix "/Cargo.lock" path;
          };
          cargoDeps = rustPlatform.fetchCargoVendor {
            src = nickelVmSrc;
            hash = "sha256-jGdjCI85lec90ubpPHyRqir+lOu1RfZlc5/dhscvgg4=";
          };
          patchedNickelCore = pkgs.stdenvNoCC.mkDerivation {
            pname = "nickel-lang-core";
            version = "0.18.0";
            src = pkgs.fetchCrate {
              pname = "nickel-lang-core";
              version = "0.18.0";
              hash = "sha256-+MYkJ2WybG3DDhUd6YyAj3AphSr9SMK9Ts05KYi9FGQ=";
            };
            patches = [
              ./nickel-vm/patches/nickel-lang-core-0.18.0-cache-resolver.patch
            ];
            installPhase = ''
              cp -R . "$out"
            '';
          };
        in
        {

          nickelVmWasm = pkgs.stdenv.mkDerivation {
            pname = "nickel-vm";
            version = "0.1.0";
            src = nickelVmSrc;
            nativeBuildInputs = [
              rustToolchain
              rustPlatform.cargoSetupHook
              pkgs.wasm-bindgen-cli
            ];
            inherit cargoDeps;
            postPatch = ''
              cat >> Cargo.toml <<EOF
              [patch.crates-io]
              nickel-lang-core = { path = "${patchedNickelCore}" }
              EOF
            '';
            dontConfigure = true;
            doCheck = false;
            buildPhase = ''
              runHook preBuild
              cargo build --release --target wasm32-unknown-unknown --offline
              runHook postBuild
            '';
            installPhase = ''
              export WASM=target/wasm32-unknown-unknown/release/nickel_vm.wasm
              mkdir -p "$out/dist"
              wasm-bindgen --target nodejs --out-dir "$out/dist" "$WASM"
              test -f "$out/dist/nickel_vm_bg.wasm"
              test -f "$out/dist/nickel_vm.js"
            '';
          };
        });

      # Dev shell with the pinned PureScript + Rust toolchains.
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
              (rustToolchainFor system)
              pkgs.wasm-bindgen-cli
            ];
          };

        });
    };
}