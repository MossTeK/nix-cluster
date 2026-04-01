{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./imports.nix
  ];

  # All module/service config blocks are injected via imports.nix and hydrated by nix-cluster.
  # nix-cluster daemon config — repoPath and afterPush are set by the installer; override trigger mode per node.
  services."nix-cluster" = {
    enable = true;
    repoPath = "/home/nops/";
    isController = IS_CONTROLLER_PLACEHOLDER;
    matrix.enable = MATRIX_ENABLE_PLACEHOLDER;
    webhook.enable = WEBHOOK_ENABLE_PLACEHOLDER;
    webhook.port = 8080;
    controllerScript = builtins.readFile ./controllerScript-autoprovision.sh;
    afterPush = [
      "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --working-directory=${config.services."nix-cluster".repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin --setenv=NIXPKGS_ALLOW_UNFREE=1 -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services."nix-cluster".repoPath}#${config.networking.hostName} --impure"
    ];
  };

  networking.hostName = "nops-node";
  networking.hostId = "HOST_ID_PLACEHOLDER";
  time.timeZone = "UTC";

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.networkmanager.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 80 443 9100 9256 8080 FIREWALL_FORGEJO_PLACEHOLDER ];
  ALLOW_UNFREE_PLACEHOLDER
  FORGEJO_CONFIG_PLACEHOLDER

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  users.users.tdavis = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "password";
    SSH_PUB_KEY_PLACEHOLDER
  };

  security.sudo.extraRules = [
    {
      users = [ "nops" ];
      commands = [
        { command = "ALL"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  nix.settings.experimental-features = [ "flakes" "nix-command" ];
  environment.systemPackages = with pkgs; [
    git
    vim
    sops
    age
    CONTROLLER_PACKAGES_PLACEHOLDER
  ];

  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.secrets = {
    matrix_bot_token = { owner = "nops"; };
    matrix_room_id = { owner = "nops"; };
    matrix_homeserver = { owner = "nops"; };
    git_username = { owner = "nops"; };
    git_password = { owner = "nops"; };
    webhook_secret = { owner = "nops"; };
    cloudflare_api_token = { owner = "nops"; };
    cloudflare_tunnel_name = { owner = "nops"; };
    cloudflare_tunnel_domain = { owner = "nops"; };
    cloudflare_zone_id = { owner = "nops"; };
    cloudflare_account_id = { owner = "nops"; };
  };

  environment.etc."git-credential-nops" = {
    mode = "0555";
    text = builtins.replaceStrings [ "\r" ] [ "" ] ''
      #!${pkgs.runtimeShell}
      echo username=$(cat ${config.sops.secrets.git_username.path})
      echo password=$(cat ${config.sops.secrets.git_password.path})
    '';
  };

  programs.git = {
    enable = true;
    config = {
      credential.helper = "/etc/git-credential-nops";
      safe.directory = "*";
    };
  };

  system.stateVersion = "25.11";
}