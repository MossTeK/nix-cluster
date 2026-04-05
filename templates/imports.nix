{ config, pkgs, inputs, ... }:

{
  imports = [
    ../../modules/caddy/caddy.nix
    ../../modules/cloudflare/cloudflared.nix
    ../../modules/backup/postgres.nix
    ../../modules/ingress/keepalived.nix
  ];
}