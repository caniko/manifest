{
  description = "Manifest — open-source AI model router and observability platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {self, nixpkgs, flake-utils, ...}:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.default = pkgs.writeShellApplication {
        name = "manifest-oci";
        text = ''
          echo "Manifest runs as an OCI container on NixOS."
          echo "Enable services.manifest on a NixOS host to deploy it."
        '';
      };
    })
    // {
      nixosModules.default = import ./modules/nixos.nix self;
    };
}
