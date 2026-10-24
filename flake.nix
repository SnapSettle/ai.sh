{
  description = "ai.sh - POSIX sh AI assistant for your terminal";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # The installable package (built from package.nix in this repo)
        ai-sh = pkgs.callPackage ./package.nix { src = self; };

        # Evaluate treefmt configuration for markdown, shell scripts, and nix
        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs = {
            shfmt.enable = true;
            prettier.enable = true;
            nixfmt.enable = true;
          };
        };
      in
      {
        formatter = treefmtEval.config.build.wrapper;

        packages = {
          inherit ai-sh;
          default = ai-sh;
        };

        # Makes `nix run github:snapsettle/ai.sh` work
        apps.default = {
          type = "app";
          program = "${ai-sh}/bin/ai.sh";
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            shfmt
            shellcheck
            jq
          ];
        };
      }
    )
    // {
      # Lets users write `pkgs.ai-sh` in their own NixOS / Home Manager config.
      # Outside the per-system part because overlays are not tied to one system.
      overlays.default = final: _prev: {
        ai-sh = final.callPackage ./package.nix { src = self; };
      };
    };
}
