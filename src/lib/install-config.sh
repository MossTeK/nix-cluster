#!/usr/bin/env bash

if [ -n "${NIX_CLUSTER_INSTALL_CONFIG_HELPER_LOADED:-}" ]; then
  return 0
fi
NIX_CLUSTER_INSTALL_CONFIG_HELPER_LOADED=1

declare -ag NIX_CLUSTER_INSTALL_OVERRIDE_KEYS=()
declare -Ag NIX_CLUSTER_INSTALL_OVERRIDE_VALUES=()

nix_cluster_escape_sed() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

normalize_install_override_key() {
  case "$1" in
    bootstrap_mode|is_controller|node_role|keepalived_role|git_user|git_token|repo_url|nix_cluster_repo_url|nops_repo_url|nixos_install_repo_url|registry_mode|module_registry_url|repo_host_ip|node_group|node_admin|node_admin_pass|node_admin_password_hash|node_ssh_pub_key|installer_auth_mode|installer_ssh_pub_key|ssh_password_auth|trigger_choice|fleet_private_key|matrix_bot_token|matrix_room_id|matrix_homeserver|webhook_secret|cloudflare_api_token|forgejo_public_host|custom_group_config|custom_group_imports|custom_node_config|custom_node_imports)
      printf '%s\n' "$1"
      ;;
    caddy_enable|modules.caddy.enable)
      printf 'modules.caddy.enable\n'
      ;;
    keepalived_enable|modules.keepalived.enable)
      printf 'modules.keepalived.enable\n'
      ;;
    keepalived_interface|modules.keepalived.interface)
      printf 'modules.keepalived.interface\n'
      ;;
    keepalived_virtual_router_id|modules.keepalived.virtual_router_id|modules.keepalived.virtualRouterId)
      printf 'modules.keepalived.virtual_router_id\n'
      ;;
    keepalived_priority|modules.keepalived.priority)
      printf 'modules.keepalived.priority\n'
      ;;
    keepalived_vip_cidr|modules.keepalived.vip_cidr|modules.keepalived.vipCidr)
      printf 'modules.keepalived.vip_cidr\n'
      ;;
    cloudflare_tunnel|modules.cloudflare.enable|modules.cloudflare.tunnel)
      printf 'modules.cloudflare.enable\n'
      ;;
    cloudflare_tunnel_name|modules.cloudflare.tunnel_name|modules.cloudflare.tunnelName)
      printf 'modules.cloudflare.tunnel_name\n'
      ;;
    cloudflare_tunnel_domain|modules.cloudflare.tunnel_domain|modules.cloudflare.tunnelDomain)
      printf 'modules.cloudflare.tunnel_domain\n'
      ;;
    cloudflare_tunnel_vip|modules.cloudflare.tunnel_vip|modules.cloudflare.vip)
      printf 'modules.cloudflare.tunnel_vip\n'
      ;;
    cloudflare_zone_id|modules.cloudflare.zone_id|modules.cloudflare.zoneId)
      printf 'modules.cloudflare.zone_id\n'
      ;;
    cloudflare_account_id|modules.cloudflare.account_id|modules.cloudflare.accountId)
      printf 'modules.cloudflare.account_id\n'
      ;;
    pxe_enable|modules.pxe.enable)
      printf 'modules.pxe.enable\n'
      ;;
    pxe_dhcp_enable|modules.pxe.dhcp_enable|modules.pxe.dhcpEnable)
      printf 'modules.pxe.dhcp_enable\n'
      ;;
    pxe_interface|modules.pxe.interface)
      printf 'modules.pxe.interface\n'
      ;;
    pxe_http_port|modules.pxe.http_port|modules.pxe.httpPort)
      printf 'modules.pxe.http_port\n'
      ;;
    pxe_boot_url|modules.pxe.boot_url|modules.pxe.bootUrl)
      printf 'modules.pxe.boot_url\n'
      ;;
    postgres_backup_enable|modules.postgres_backup.enable|modules.postgresBackup.enable)
      printf 'modules.postgres_backup.enable\n'
      ;;
    *)
      return 1
      ;;
  esac
}

add_install_override() {
  local raw_key="$1"
  local value="$2"
  local key

  if ! key=$(normalize_install_override_key "$raw_key"); then
    echo "Unknown install override key: $raw_key"
    exit 1
  fi

  if [ -z "${NIX_CLUSTER_INSTALL_OVERRIDE_VALUES[$key]+x}" ]; then
    NIX_CLUSTER_INSTALL_OVERRIDE_KEYS+=("$key")
  fi
  NIX_CLUSTER_INSTALL_OVERRIDE_VALUES[$key]="$value"
}

parse_install_cli_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --config)
        CONFIG_FILE="$2"
        shift
        ;;
      --clean)
        CLEAN=true
        ;;
      --set)
        if [[ "$2" != *=* ]]; then
          echo "Expected --set key=value"
          exit 1
        fi
        add_install_override "${2%%=*}" "${2#*=}"
        shift
        ;;
      --enable)
        add_install_override "$2" "true"
        shift
        ;;
      --disable)
        add_install_override "$2" "false"
        shift
        ;;
      *)
        echo "Unknown parameter passed: $1"
        exit 1
        ;;
    esac
    shift
  done
}

apply_install_overrides() {
  local key value
  for key in "${NIX_CLUSTER_INSTALL_OVERRIDE_KEYS[@]}"; do
    value="${NIX_CLUSTER_INSTALL_OVERRIDE_VALUES[$key]}"
    case "$key" in
      bootstrap_mode) IS_BOOTSTRAP="$value" ;;
      is_controller) IS_CONTROLLER="$value" ;;
      node_role) NODE_ROLE="$value" ;;
      keepalived_role) KEEPALIVED_ROLE="$value" ;;
      git_user) GIT_USER="$value" ;;
      git_token) GIT_TOKEN="$value" ;;
      repo_url) REPO_URL="$value" ;;
      nix_cluster_repo_url|nops_repo_url) NIX_CLUSTER_REPO_URL="$value" ;;
      nixos_install_repo_url) NIXOS_INSTALL_REPO_URL="$value" ;;
      registry_mode) REGISTRY_MODE="$value" ;;
      module_registry_url) MODULE_REGISTRY_URL="$value" ;;
      repo_host_ip) REPO_HOST_IP="$value" ;;
      node_group) NODE_GROUP="$value" ;;
      node_admin) NODE_ADMIN="$value" ;;
      node_admin_pass) NODE_ADMIN_PASS="$value" ;;
      node_admin_password_hash) NODE_ADMIN_PASSWORD_HASH="$value" ;;
      node_ssh_pub_key) NODE_SSH_PUB_KEY="$value" ;;
      installer_auth_mode) INSTALLER_AUTH_MODE="$value" ;;
      installer_ssh_pub_key) INSTALLER_SSH_PUB_KEY="$value" ;;
      ssh_password_auth) SSH_PASSWORD_AUTH="$value" ;;
      trigger_choice) TRIGGER_CHOICE="$value" ;;
      fleet_private_key) FLEET_PRIVATE_KEY="$value" ;;
      matrix_bot_token) MATRIX_BOT_TOKEN="$value" ;;
      matrix_room_id) MATRIX_ROOM_ID="$value" ;;
      matrix_homeserver) MATRIX_HOMESERVER="$value" ;;
      webhook_secret) WEBHOOK_SECRET="$value" ;;
      cloudflare_api_token) CF_API_TOKEN="$value" ;;
      forgejo_public_host) FORGEJO_PUBLIC_HOST="$value" ;;
      custom_group_config) CUSTOM_GROUP_CONFIG="$value" ;;
      custom_group_imports) CUSTOM_GROUP_IMPORTS="$value" ;;
      custom_node_config) CUSTOM_NODE_CONFIG="$value" ;;
      custom_node_imports) CUSTOM_NODE_IMPORTS="$value" ;;
      modules.caddy.enable) CADDY_ENABLE="$value" ;;
      modules.keepalived.enable) KEEPALIVED_ENABLE="$value" ;;
      modules.keepalived.interface) KEEPALIVED_INTERFACE="$value" ;;
      modules.keepalived.virtual_router_id) KEEPALIVED_ROUTER_ID="$value" ;;
      modules.keepalived.priority) KEEPALIVED_PRIORITY="$value" ;;
      modules.keepalived.vip_cidr) KEEPALIVED_VIP_CIDR="$value" ;;
      modules.cloudflare.enable) CF_TUNNEL="$value" ;;
      modules.cloudflare.tunnel_name) CF_TUNNEL_NAME="$value" ;;
      modules.cloudflare.tunnel_domain) CF_TUNNEL_DOMAIN="$value" ;;
      modules.cloudflare.tunnel_vip) CF_TUNNEL_VIP="$value" ;;
      modules.cloudflare.zone_id) CF_ZONE_ID="$value" ;;
      modules.cloudflare.account_id) CF_ACCOUNT_ID="$value" ;;
      modules.pxe.enable) PXE_ENABLE="$value" ;;
      modules.pxe.dhcp_enable) PXE_DHCP_ENABLE="$value" ;;
      modules.pxe.interface) PXE_INTERFACE="$value" ;;
      modules.pxe.http_port) PXE_HTTP_PORT="$value" ;;
      modules.pxe.boot_url) PXE_BOOT_URL="$value" ;;
      modules.postgres_backup.enable) POSTGRES_BACKUP_ENABLE="$value" ;;
    esac
  done
}
