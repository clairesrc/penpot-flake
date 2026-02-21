{
  description = "NixOS module for deploying Penpot using OCI containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      nixosModules.penpot = import ./module.nix;
      nixosModules.default = self.nixosModules.penpot;

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          integration = pkgs.callPackage ./tests/basic.nix {
            inherit self;
          };
        }
      );
    };
}
