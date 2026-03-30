{
  description = "nops Fleet Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    
    # nops flake input — provides nixosModules.default (the service module) and the nops-install CLI.
    nops.url = "NOPS_FLAKE_URL_PLACEHOLDER";
    nops.inputs.nixpkgs.follows = "nixpkgs";
    nops.inputs.sops-nix.follows = "sops-nix";

    # disko for declarative disk partitioning
    disko.url = "github:nix-community/disko";
  };

  outputs = { self, nixpkgs, sops-nix, nops, disko, ... }: {
    
    # nops-install appends nixosConfigurations.<hostname> entries below this line via sed.
    # NODES_MARKER

  };
}