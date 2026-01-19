{ config, pkgs, ... }:

{
  imports = [ 
    ./hardware-configuration.nix 
    ./modules/imports.nix
  ];

  # nad daemon
  services.nad = {
    enable = true;
    repoPath = "/home/nad/${config.networking.hostName}";
  };

  networking.hostName = "nad"; 
  time.timeZone = "UTC";

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.networkmanager.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 5000 ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  # admin user
  users.users.admin_placeholder = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "password_placeholder";
  };

  users.users.nad = {
    isNormalUser = true;
    group = "nad";
    extraGroups = [ "wheel" "docker" ];
  };
  users.groups.nad = {};

  security.sudo.extraRules = [
    {
      users = [ "nad" ];
      commands = [
        { command = "ALL"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  environment.systemPackages = with pkgs; [ 
    git
    vim
    nano
    sops
    age 
  ];

  sops.defaultSopsFile = ./secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets = {
    forgejo_webhook_secret = { owner = "nad"; };
    git_username = { owner = "nad"; };
    git_password = { owner = "nad"; };
  };

  environment.etc."git-credential-nad" = {
    mode = "0555";
    text = ''
      #!${pkgs.runtimeShell}
      echo username=$(cat ${config.sops.secrets.git_username.path})
      echo password=$(cat ${config.sops.secrets.git_password.path})
    '';
  };

  programs.git = {
    enable = true;
    config = {
      credential.helper = "/etc/git-credential-nad";
      safe.directory = "/home/nad/${config.networking.hostName}";
    };
  };

  nix.settings.experimental-features = [ "flakes" "nix-command" ];
  system.stateVersion = "25.11";
}