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
  # nickel is npm-only-incompatible: the nixpkgs nickel formatter always
  # rewrites files (updating mtime), which causes false positives in
  # treefmt's --ci/--fail-on-change mode. Override with a stdin/stdout
  # wrapper that only writes when content actually changes.
  programs.nickel.enable = false;
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
  # Uses a bash wrapper with stdin/stdout mode: purs-tidy reads from stdin
  # and writes formatted output to stdout, which treefmt applies only when
  # the content differs. This avoids spurious mtime changes that trigger
  # false positives in treefmt's --fail-on-change / --ci mode.
  settings.formatter.purs-tidy = {
    command = "${pkgs.bash}/bin/bash";
    options = [
      "-euc"
      ''
        for file in "$@"; do
          tmp="$(mktemp)"
          trap 'rm -f "$tmp"' EXIT
          ${pkgs.nodejs}/bin/npx purs-tidy format < "$file" > "$tmp"
          cmp -s "$file" "$tmp"
          status=$?
          if [ "$status" -eq 1 ]; then
            cp "$tmp" "$file"
          elif [ "$status" -ne 0 ]; then
            echo "cmp failed with status $status for $file" >&2
            exit "$status"
          fi
          rm -f "$tmp"
          trap - EXIT
        done
      ''
      "--" # bash swallows the second argument when using -c
    ];
    includes = ["*.purs"];
  };

  # Custom Nickel formatter — the built-in treefmt-nix nickel program uses
  # `nickel format <files>` which always rewrites files (updating mtime),
  # triggering false positives in treefmt's --ci mode. This wrapper uses
  # stdin/stdout: `nickel format` reads from stdin and writes to stdout,
  # and only writes back when content actually differs.
  settings.formatter.nickel = {
    command = "${pkgs.bash}/bin/bash";
    options = [
      "-euc"
      ''
        for file in "$@"; do
          tmp="$(mktemp)"
          trap 'rm -f "$tmp"' EXIT
          ${pkgs.nickel}/bin/nickel format < "$file" > "$tmp"
          cmp -s "$file" "$tmp"
          status=$?
          if [ "$status" -eq 1 ]; then
            cp "$tmp" "$file"
          elif [ "$status" -ne 0 ]; then
            echo "cmp failed with status $status for $file" >&2
            exit "$status"
          fi
          rm -f "$tmp"
          trap - EXIT
        done
      ''
    ];
    includes = [
      "*.ncl"
      "*.nickel"
    ];
  };

  # Exclude generated/build output and vendored trees from formatting.
  # treefmt v2 glob patterns: "dir/*" matches direct children only;
  # "dir/**" matches recursively. Use recursive patterns for directories
  # whose entire subtree should be excluded.
  settings.global.excludes = [
    # Node
    "node_modules/**"
    "package-lock.json"
    # Build outputs
    "dist/**"
    "pure/dist/**"
    "pure/output/**"
    "pure/.spago/**"
    "nickel-vm/dist/**"
    "nickel-vm/target/**"
    "target/**"
    # VCS internals
    ".git/**"
    ".jj/**"
    # Nix build results
    "result"
    "result-*"
    ".#*"
    # IDE / tool caches
    ".codegraph/**"
    ".idea/**"
    ".omp/**"
    ".omp-plugin/**"
    # Agency runtime state
    ".do-results.json"
  ];
}
