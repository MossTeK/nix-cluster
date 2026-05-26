{
  description = "private nix-cluster app registry";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { ... }:
  let
    privateApps = {
PRIVATE_APPS_PLACEHOLDER
    };

    nixosApps = {
      official = {};
      community = {};
      private = privateApps;
    };
  in {
    inherit nixosApps;
    nixosModules = nixosApps;
    registry = {
      official = {};
      community = {};
      private = builtins.mapAttrs (name: _: {
        source = "fleet-local";
        visibility = "private";
        moduleRef = "private.${name}";
      }) privateApps;
    };
  };
}