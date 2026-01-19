{
  description = "NAD Managed System";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    
    # Points to your library (will be cached by the system)
    nad-core.url = "git+https://forgejo.mosstek.co/moss/nad-core.git";
    nad-core.inputs.nixpkgs.follows = "nixpkgs";
    # FIX: Ensure the library uses the same version of sops-nix as the system
    nad-core.inputs.sops-nix.follows = "sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix, nad-core, ... }: {
    # The setup script will rename 'nad' to your hostname (e.g., 'nad2')
    nixosConfigurations.nad = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        # REMOVED: sops-nix.nixosModules.sops (Provided by nad-core)
        nad-core.nixosModules.default
      ];
    };
  };
}