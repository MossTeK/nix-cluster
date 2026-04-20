{ config, pkgs, inputs, ... }:

{
  imports = [
    ../../apps/caddy/caddy.nix
    ../../apps/cloudflare/cloudflared.nix
    ../../apps/backup/postgres.nix
    ../../apps/ingress/keepalived.nix
  ];
}