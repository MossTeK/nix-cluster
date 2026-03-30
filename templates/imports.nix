{ config, pkgs, ... }:

{
  imports = [
    # These are injected by the installer if enabled in the JSON or prompts:
    CADDY_MODULE_PLACEHOLDER
    CLOUDFLARED_MODULE_PLACEHOLDER
    FORGEJO_MODULE_PLACEHOLDER
    PXE_MODULE_PLACEHOLDER
    POSTGRES_BACKUP_MODULE_PLACEHOLDER
    KEEPALIVED_MODULE_PLACEHOLDER
  ];
}