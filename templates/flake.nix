{
  description = "nix-cluster Fleet Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    
    # nix-cluster flake input — provides nixosModules.default (the service module) and the install CLI.
    nixCluster.url = "git+https://git.smallguytech.org/SGT/nix-cluster.git";
    nixCluster.inputs.nixpkgs.follows = "nixpkgs";
    nixCluster.inputs.sops-nix.follows = "sops-nix";

    APP_REGISTRY_INPUT_PLACEHOLDER

    # disko for declarative disk partitioning
    disko.url = "github:nix-community/disko";
  };

  outputs = inputs@{ self, nixpkgs, sops-nix, nixCluster, disko, ... }: {
    
    # nix-cluster install appends nixosConfigurations.<hostname> entries below this line via sed.
    # NODES_MARKER

  };
}