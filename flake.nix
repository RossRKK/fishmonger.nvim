{
  description = "fishmonger.nvim's test suite, with its nvim and plenary from nixpkgs";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
          system: f nixpkgs.legacyPackages.${system}
        );
      # What `make test` needs; tests/minimal_init.lua reads PLENARY_DIR.
      testEnv = pkgs: {
        packages = [
          pkgs.neovim-unwrapped
          pkgs.gnumake
        ];
        PLENARY_DIR = "${pkgs.vimPlugins.plenary-nvim}";
      };
    in
    {
      # `nix develop -c make test`
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell (testEnv pkgs);
      });

      # `nix flake check`
      checks = forEachSystem (pkgs: {
        test = pkgs.runCommand "fishmonger-tests" (
          (testEnv pkgs) // { nativeBuildInputs = (testEnv pkgs).packages; }
        ) "cd ${self} && HOME=$TMPDIR make test && touch $out";
      });
    };
}
