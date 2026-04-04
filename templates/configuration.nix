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
    repoPath = "/home/nix-cluster/";
    isController = IS_CONTROLLER_PLACEHOLDER;
    placement = {
      nodeRole = "NODE_ROLE_PLACEHOLDER";
      haRole = "HA_ROLE_PLACEHOLDER";
      keepalivedRole = "KEEPALIVED_ROLE_PLACEHOLDER";
    };
    modules = {
      caddy.enable = CADDY_ENABLE_PLACEHOLDER;
      keepalived = {
        enable = KEEPALIVED_ENABLE_PLACEHOLDER;
        interface = "KEEPALIVED_INTERFACE_PLACEHOLDER";
        virtualRouterId = KEEPALIVED_ROUTER_ID_PLACEHOLDER;
        priority = KEEPALIVED_PRIORITY_PLACEHOLDER;
        vipCidr = "KEEPALIVED_VIP_CIDR_PLACEHOLDER";
      };
      cloudflare = {
        enable = CLOUDFLARE_ENABLE_PLACEHOLDER;
        tunnel = CLOUDFLARE_TUNNEL_ENABLE_PLACEHOLDER;
        tunnelName = "CLOUDFLARE_TUNNEL_NAME_PLACEHOLDER";
        tunnelDomain = "CLOUDFLARE_TUNNEL_DOMAIN_PLACEHOLDER";
        vip = "CLOUDFLARE_TUNNEL_VIP_PLACEHOLDER";
        zoneId = "CLOUDFLARE_ZONE_ID_PLACEHOLDER";
        accountId = "CLOUDFLARE_ACCOUNT_ID_PLACEHOLDER";
      };
      pxe = {
        enable = PXE_ENABLE_PLACEHOLDER;
        authorizedKeys = PXE_AUTHORIZED_KEYS_PLACEHOLDER;
        dhcpEnable = PXE_DHCP_ENABLE_PLACEHOLDER;
        interface = "PXE_INTERFACE_PLACEHOLDER";
        httpPort = PXE_HTTP_PORT_PLACEHOLDER;
        bootUrl = "PXE_BOOT_URL_PLACEHOLDER";
      };
      postgresBackup.enable = POSTGRES_BACKUP_ENABLE_PLACEHOLDER;
    };
    matrix.enable = MATRIX_ENABLE_PLACEHOLDER;
    webhook.enable = WEBHOOK_ENABLE_PLACEHOLDER;
    webhook.port = 8080;
    controllerScript = builtins.readFile ./controllerScript-autoprovision.sh;
    afterPush = [
      "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --working-directory=${config.services."nix-cluster".repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin --setenv=NIXPKGS_ALLOW_UNFREE=1 -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services."nix-cluster".repoPath}#${config.networking.hostName} --impure"
    ];
  };

  networking.hostName = "nix-cluster-node";
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
    settings = {
      PasswordAuthentication = SSH_PASSWORD_AUTH_PLACEHOLDER;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.mutableUsers = false;

  users.users.tdavis = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    ADMIN_PASSWORD_CONFIG_PLACEHOLDER
    SSH_PUB_KEY_PLACEHOLDER
  };

  security.sudo.wheelNeedsPassword = false;

  security.sudo.extraRules = [
    {
      users = [ "nix-cluster" ];
      commands = [
        { command = "ALL"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  nix.settings = {
    experimental-features = [ "flakes" "nix-command" ];
    trusted-users = [ "root" "NODE_ADMIN_PLACEHOLDER" ];
  };
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
    matrix_bot_token = { owner = "nix-cluster"; };
    matrix_room_id = { owner = "nix-cluster"; };
    matrix_homeserver = { owner = "nix-cluster"; };
    git_username = { owner = "nix-cluster"; };
    git_password = { owner = "nix-cluster"; };
    webhook_secret = { owner = "nix-cluster"; };
    cloudflare_api_token = { owner = "nix-cluster"; };
    cloudflare_tunnel_name = { owner = "nix-cluster"; };
    cloudflare_tunnel_domain = { owner = "nix-cluster"; };
    cloudflare_zone_id = { owner = "nix-cluster"; };
    cloudflare_account_id = { owner = "nix-cluster"; };
  };

  environment.etc."git-credential-nix-cluster" = {
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
      credential.helper = "/etc/git-credential-nix-cluster";
      safe.directory = "*";
    };
  };

  system.stateVersion = "25.11";
}