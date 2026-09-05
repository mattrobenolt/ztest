{
  description = "Zig development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    mattware = {
      url = "github:mattrobenolt/nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      mattware,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ mattware.overlays.default ];
          };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              zig_0_15
              zls_0_15
              ziglint
              zigdoc
            ];

            shellHook = ''
              unset NIX_CFLAGS_COMPILE
              unset ZIG_GLOBAL_CACHE_DIR
            '';
          };

          # Compiler-test shell for verifying against Zig 0.16. The default
          # shell above stays on 0.15: `nix develop .#zig_0_16`
          devShells.zig_0_16 = pkgs.mkShell {
            packages = with pkgs; [
              zig_0_16
            ];

            shellHook = ''
              unset NIX_CFLAGS_COMPILE
              unset ZIG_GLOBAL_CACHE_DIR
            '';
          };
        };
    };
}
