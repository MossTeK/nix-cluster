# Provides a base Caddy service so generated fleets can append reverse proxy routes.
{ config, pkgs, lib, ... }:

lib.mkIf config.services."nix-cluster".modules.caddy.enable {
  services.caddy = {
    enable = true;
    package = pkgs.caddy;
    globalConfig = ''
      auto_https off
    '';
    virtualHosts = {};
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}