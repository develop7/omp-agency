# treefmt configuration — single source of truth for formatting,
# consumed by the flake's `formatter` (`nix fmt`) and `checks.formatting`
# (`nix flake check`) outputs. See flake.nix.
#
# Formatters:
#   prettier   — TypeScript, JavaScript, JSON, Markdown, YAML (all from nixpkgs)
#   rustfmt    — Rust (nickel-vm/)
#   alejandra  — Nix (flake.nix, treefmt.nix)
#   shfmt      — Shell scripts (scripts/, tests/helpers/)
#   nickel     — Nickel workflow files (skills/do/workflow.ncl)
#   taplo      — TOML (Cargo.toml, spago.yaml is YAML not TOML)
#   just       — justfile
#   purs-tidy  — PureScript (custom formatter; npm-only, not in treefmt-nix)
{pkgs, ...}: {
  # Used to find the project root
  projectRootFile = "flake.nix";

  # Enable formatters from nixpkgs (wrapped into the treefmt binary)
  programs.prettier.enable = true;
  programs.rustfmt = {
    enable = true;
    # nickel-vm/Cargo.toml uses edition 2021
    edition = "2021";
  };
  programs.alejandra.enable = true;
  programs.nickel.enable = true;
  programs.taplo.enable = true;
  programs.just.enable = true;

  # shfmt with bats extension added (.bats files are bash)
  programs.shfmt = {
    enable = true;
    includes = [
      "*.sh"
      "*.bash"
      "*.bats"
    ];
  };

  # Custom formatter for PureScript — purs-tidy is npm-only (not in nixpkgs
  # nodePackages was removed). Installed via package.json devDependencies;
  # resolved through npx which finds node_modules/.bin/purs-tidy.
  settings.formatter.purs-tidy = {
    command = "${pkgs.nodejs}/bin/npx";
    options = [
      "purs-tidy"
      "format-in-place"
    ];
    includes = ["*.purs"];
  };

  # Exclude generated/build output and vendored trees from formatting
  settings.global.excludes = [
    # Node
    "node_modules/*"
    "package-lock.json"
    # Build outputs
    "dist/*"
    "pure/dist/*"
    "pure/output/*"
    "pure/.spago/*"
    "nickel-vm/dist/*"
    "nickel-vm/target/*"
    "target/*"
    # VCS internals
    ".git/*"
    ".jj/*"
    # Nix build results
    "result"
    "result-*"
    ".#*"
    # IDE / tool caches
    ".codegraph/*"
    ".idea/*"
    ".omp/*"
    ".omp-plugin/*"
    ".agency/*"
    # Agency runtime state
    ".do-results.json"
  ];
}
