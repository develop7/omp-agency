{
  description = "agency PureScript development toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mk-spago-derivation = {
      url = "github:jeslie0/mkSpagoDerivation/43dd4c8a0fed8fcfdeb98bd1687f06f198ab4d20";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.ps-overlay.inputs.nixpkgs.follows = "nixpkgs";
    };
    # Binary-distributed Rust toolchains with cross targets (wasm32 std).
    # nixpkgs' own rustc cannot add wasm32-unknown-unknown, and
    # pkgsCross.wasm32-unknown-unknown.buildPackages.rustc does not exist
    # in this nixpkgs rev.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    mk-spago-derivation,
    treefmt-nix,
  }: let
    # nixpkgs unstable dropped x86_64-darwin; re-add when a supported nixpkgs provides it.
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    forAllSystems = nixpkgs.lib.genAttrs systems;

    pkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [
          rust-overlay.overlays.default
          mk-spago-derivation.overlays.default
          (
            _final: prev:
              prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
                purescript = prev.purescript.overrideAttrs (old: {
                  # Combined interpreter/RPATH rewriting makes patchelf 0.19.2
                  # overlap writable .dynamic with a read-only LOAD segment.
                  # Set RPATH first, preserving the compiler and completion check.
                  # https://github.com/NixOS/patchelf/issues/674
                  installPhase = let
                    patched =
                      builtins.replaceStrings
                      [
                        "patchelf --interpreter ${prev.stdenv.cc.bintools.dynamicLinker} --set-rpath ${old.libPath} $PURS"
                      ]
                      [
                        ''
                          patchelf --set-rpath ${old.libPath} $PURS
                          patchelf --interpreter ${prev.stdenv.cc.bintools.dynamicLinker} $PURS
                        ''
                      ]
                      old.installPhase;
                  in
                    assert patched
                    != old.installPhase
                    || throw "PureScript install phase changed; review the patchelf command override."; patched;
                });
              }
          )
        ];
      };

    # nickel-lang-core 0.18.0's published crate evaluates the in-memory
    # source marker only after normalize_path, which fails on wasm32 where
    # current_dir is unavailable. Keep the one-line-order fix isolated in
    # nickel-vm/patches and apply it to the crate source used by the VM.

    # nixpkgs' `spago` is the legacy 0.21 CLI. The project uses the
    # registry-based Spago 1 CLI, whose npm tarball is a self-contained
    # Node bundle, so pin that exact release in a small Nix derivation.
    spagoFor = system: let
      pkgs = pkgsFor system;
    in
      pkgs.stdenvNoCC.mkDerivation {
        pname = "spago";
        version = "1.0.4";
        src = pkgs.fetchzip {
          url = "https://registry.npmjs.org/spago/-/spago-1.0.4.tgz";
          hash = "sha256-93DGEspzPS+XeqAlxkek+ubDW6FbVbpscO2QvRGKIfg=";
          stripRoot = true;
        };
        nativeBuildInputs = [pkgs.makeWrapper];
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
    rustToolchainFor = system: let
      pkgs = pkgsFor system;
    in
      # The failure was in buildRustPackage's double-target hook: it
      # injected the host target before the requested wasm32 target.
      pkgs.rust-bin.stable."1.99.1".default.override {
        targets = ["wasm32-unknown-unknown"];
      };
    # rustPlatform built on the overlay toolchain so buildRustPackage
    # compiles with the same rustc that carries the wasm32 std.
    # rust-overlay's toolchain is a single derivation carrying both
    # rustc and cargo — pass it in both roles (the standard pattern).
    rustPlatformFor = system: let
      pkgs = pkgsFor system;
    in
      pkgs.makeRustPlatform {
        cargo = rustToolchainFor system;
        rustc = rustToolchainFor system;
      };
    # wasm-bindgen's CLI must match the crate resolved by Cargo: mismatched
    # versions can generate incompatible JavaScript glue.
    wasmBindgenCliFor = system: let
      pkgs = pkgsFor system;
      cargoLock = builtins.fromTOML (builtins.readFile ./nickel-vm/Cargo.lock);
      wasmBindgenPackages = builtins.filter (pkg: pkg.name == "wasm-bindgen") cargoLock.package;
      wasmBindgenVersion = (builtins.head wasmBindgenPackages).version;
      wasmBindgenCli = pkgs.wasm-bindgen-cli;
    in
      assert builtins.length wasmBindgenPackages
      == 1
      || throw "Expected nickel-vm/Cargo.lock to resolve exactly one wasm-bindgen package, found ${toString (builtins.length wasmBindgenPackages)}.";
      assert wasmBindgenCli.version
      == wasmBindgenVersion
      || throw "wasm-bindgen-cli ${wasmBindgenCli.version} from nixpkgs does not match wasm-bindgen ${wasmBindgenVersion} resolved in nickel-vm/Cargo.lock. Update the flake input or Cargo.lock so their wasm-bindgen versions match."; wasmBindgenCli;
    # treefmt configuration — formatter multiplexer for all source languages.
    # Consumed by `nix fmt` (via formatter output) and `nix flake check`
    # (via checks.formatting). See treefmt.nix.
    treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix);
  in {
    # nickel-vm compiled to wasm32-unknown-unknown with wasm-bindgen
    # Node.js glue, installed into nickel-vm/dist/ by `just nickel-build`
    # (a generated runtime artifact; build output, not committed).
    packages = forAllSystems (
      system: let
        pkgs = pkgsFor system;
        spago = spagoFor system;
        # Application edits must not invalidate the compiled dependency cache.
        pureDependencySrc = pkgs.lib.cleanSourceWith {
          name = "agency-spago-dependencies";
          src = ./pure;
          filter = path: type:
            builtins.elem (baseNameOf path) [
              "spago.yaml"
              "spago.lock"
            ];
        };
        pureSrc = pkgs.lib.cleanSourceWith {
          name = "agency-pure-source";
          src = ./.;
          filter = path: type: let
            relative = pkgs.lib.removePrefix "${toString ./.}/" path;
          in
            # Generated vocabulary is rebuilt from the manifest in the sandbox.
            relative
            != "pure/src/Agency/Scripts/Do/WorkflowVocabulary.purs"
            && (
              builtins.elem relative [
                "pure"
                "pure/src"
                "pure/test"
                "pure/package.json"
                "pure/spago.yaml"
                "pure/spago.lock"
                "scripts"
                "scripts/generate-workflow-vocabulary.mjs"
                "skills"
                "skills/do"
                "skills/do/workflow-manifest.json"
              ]
              || pkgs.lib.hasPrefix "pure/src/" relative
              || pkgs.lib.hasPrefix "pure/test/" relative
            );
        };
        pureDependencies = pkgs.mkSpagoDerivation {
          name = "agency-pure-dependencies";
          src = pureDependencySrc;
          nativeBuildInputs = [
            pkgs.purescript
            spago
          ];
          buildPhase = "spago install --offline";
          installPhase = ''
            mkdir -p "$out"
            cp -R output "$out/output"
          '';
          dontFixup = true;
        };
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
          hash = "sha256-kBBZZ7AIiGbWvkJi2oeDEbu1MepRls62ylkRpLpYgrQ=";
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
      in {
        # Cachix stores both the reusable compiler output and the final bundles.
        inherit pureDependencies;
        pureScripts = pkgs.mkSpagoDerivation {
          name = "agency-pure-scripts";
          src = pureSrc;
          spagoYaml = "${pureSrc}/pure/spago.yaml";
          spagoLock = "${pureSrc}/pure/spago.lock";
          nativeBuildInputs = [
            pkgs.purescript
            spago
            pkgs.esbuild
            pkgs.nodejs
          ];
          preBuild = "cd pure";
          buildPhase = ''
            cp -R ${pureDependencies}/output .
            chmod -R u+w output
            mkdir -p ../src
            node ../scripts/generate-workflow-vocabulary.mjs
            spago bundle --offline --module Agency.Scripts.Do.Cli \
              --outfile dist/agency-do.js --force --platform node
            spago bundle --offline --module Agency.Scripts.Do.Api \
              --outfile dist/agency-api.js --force --platform node --bundle-type=module
          '';
          installPhase = ''
            mkdir -p "$out/dist"
            cp dist/agency-do.js dist/agency-api.js "$out/dist/"
          '';
          dontFixup = true;
        };

        nickelVmWasm = pkgs.stdenv.mkDerivation {
          pname = "nickel-vm";
          version = "0.1.0";
          src = nickelVmSrc;
          nativeBuildInputs = [
            rustToolchain
            rustPlatform.cargoSetupHook
            (wasmBindgenCliFor system)
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
      }
    );

    # Dev shell with the pinned PureScript + Rust toolchains.
    devShells = forAllSystems (
      system: let
        pkgs = pkgsFor system;
        spago = spagoFor system;
      in {
        default = pkgs.mkShell {
          packages = [
            pkgs.purescript
            spago
            pkgs.esbuild
            pkgs.bats
            pkgs.nickel
            pkgs.nodejs
            pkgs.just
            # Gate tools driven by the justfile recipes: shellcheck backs
            # `just lint`; actionlint backs `just lint-workflows`; git and
            # jj are the VCS binaries the bats integration fixtures drive
            # (jj arms skip when absent).
            pkgs.shellcheck
            pkgs.actionlint
            pkgs.git
            pkgs.jujutsu
            # treefmt backs `just fmt-check` (treefmt --check). The
            # formatter output (nix fmt) is the same wrapper.
            treefmtEval.${system}.config.build.wrapper
            (rustToolchainFor system)
            (wasmBindgenCliFor system)
          ];
        };
      }
    );

    # `nix fmt` — runs treefmt across the whole project.
    formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

    # `nix flake check` — fails if any file would be reformatted.
    checks = forAllSystems (system: {
      formatting = treefmtEval.${system}.config.build.check self;
    });
  };
}
