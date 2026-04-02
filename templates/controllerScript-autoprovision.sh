#!/usr/bin/env bash
# nix-cluster Controller Node: Autonomous Bare-Metal Provisioning State Machine
set -euo pipefail

# Configuration Paths
DEPLOYMENTS_JSON="deployments.json"
NIX_CLUSTER_SSH_KEY="/home/nix-cluster/.ssh/id_ed25519"
SOPS_KEY="/var/lib/sops-nix/key.txt"
RUNTIME_CONFIG="/etc/nix-cluster-runtime-config.json"

SSH_BASE_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
)
TEMP_FILES=()

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

detect_primary_ip() {
  local primary_ip

  primary_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
  if [ -n "$primary_ip" ]; then
    printf '%s\n' "$primary_ip"
    return 0
  fi

  ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

base64_nowrap() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

cleanup() {
  if [ "${#TEMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TEMP_FILES[@]}"
  fi
}

prepare_json_input() {
  local source_file="$1"
  local temp_file="$2"

  if sudo env SOPS_AGE_KEY_FILE="$SOPS_KEY" sops -d "$source_file" 2>/dev/null | tee "$temp_file" >/dev/null; then
    TEMP_FILES+=("$temp_file")
    return 0
  fi

  cp "$source_file" "$temp_file"
  TEMP_FILES+=("$temp_file")
}

trap cleanup EXIT

if [ ! -r "$RUNTIME_CONFIG" ] && [ -r "/etc/nops-runtime-config.json" ]; then
  RUNTIME_CONFIG="/etc/nops-runtime-config.json"
fi

# Skip if there's no deployments file
if [ ! -f "$DEPLOYMENTS_JSON" ]; then
  exit 0
fi

DEPLOYMENTS_INPUT=$(mktemp)
prepare_json_input "$DEPLOYMENTS_JSON" "$DEPLOYMENTS_INPUT"

NIX_CLUSTER_CONFIG_TEMPLATE_INPUT=""
if [ -s "nix-cluster-config-template.json" ]; then
  NIX_CLUSTER_CONFIG_TEMPLATE_INPUT=$(mktemp)
  prepare_json_input "nix-cluster-config-template.json" "$NIX_CLUSTER_CONFIG_TEMPLATE_INPUT"
elif [ -s "nops-config-template.json" ]; then
  NIX_CLUSTER_CONFIG_TEMPLATE_INPUT=$(mktemp)
  prepare_json_input "nops-config-template.json" "$NIX_CLUSTER_CONFIG_TEMPLATE_INPUT"
fi

echo "[nix-cluster] === Auto-Provisioning Fleet Nodes ==="

ETCD_ENDPOINT=""
ETCD_INVENTORY_PREFIX="/nix-cluster/inventory"
ETCD_JOIN_PREFIX="/nix-cluster/join"
if [ -r "$RUNTIME_CONFIG" ]; then
  ETCD_ENDPOINT=$(jq -r '.ha.runtime_store.endpoint // empty' "$RUNTIME_CONFIG" 2>/dev/null || true)
  ETCD_INVENTORY_PREFIX=$(jq -r '.ha.runtime_store.inventory_prefix // "/nix-cluster/inventory"' "$RUNTIME_CONFIG" 2>/dev/null || true)
  ETCD_JOIN_PREFIX=$(jq -r '.ha.runtime_store.join_prefix // "/nix-cluster/join"' "$RUNTIME_CONFIG" 2>/dev/null || true)
fi

etcd_enabled() {
  [ -n "$ETCD_ENDPOINT" ]
}

etcd_put_json() {
  local key="$1"
  local payload="$2"
  local request_body

  if ! etcd_enabled; then
    return 0
  fi

  request_body=$(jq -nc \
    --arg key "$(base64_nowrap "$key")" \
    --arg value "$(base64_nowrap "$payload")" \
    '{key: $key, value: $value}')

  curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$request_body" \
    "$ETCD_ENDPOINT/v3/kv/put" >/dev/null || echo "[nix-cluster] warning: failed to publish runtime state for $key" >&2
}

publish_inventory_record() {
  local node_name="$1"
  local payload="$2"
  etcd_put_json "$ETCD_INVENTORY_PREFIX/$node_name" "$payload"
}

publish_join_record() {
  local node_name="$1"
  local payload="$2"
  etcd_put_json "$ETCD_JOIN_PREFIX/$node_name" "$payload"
}

# Ensure SSH key exists for the controller to access new nodes
if [ ! -f "$NIX_CLUSTER_SSH_KEY" ]; then
  mkdir -p "$(dirname "$NIX_CLUSTER_SSH_KEY")"
  ssh-keygen -t ed25519 -f "$NIX_CLUSTER_SSH_KEY" -N ""
fi

CONTROLLER_HOSTNAME=$(hostname -s)
CONTROLLER_PRIMARY_IP=$(detect_primary_ip)

ssh_with_key() {
  local remote="$1"
  shift

  ssh -n -i "$NIX_CLUSTER_SSH_KEY" -o BatchMode=yes "${SSH_BASE_OPTS[@]}" "$remote" "$@"
}

ssh_with_password() {
  local password="$1"
  local remote="$2"
  shift 2

  SSHPASS="$password" sshpass -e ssh -n -o PreferredAuthentications=password -o PubkeyAuthentication=no "${SSH_BASE_OPTS[@]}" "$remote" "$@"
}

stop_pixiecore_for_disk_boot() {
  if sudo systemctl is-active --quiet pixiecore.service 2>/dev/null; then
    echo "[nix-cluster] Stopping pixiecore so the node can boot from local disk..."
    sudo systemctl stop pixiecore.service
    return 0
  fi

  return 1
}

start_pixiecore_after_disk_boot() {
  if systemctl list-unit-files pixiecore.service >/dev/null 2>&1; then
    sudo systemctl start pixiecore.service || true
  fi
}

can_login_with_key() {
  local user="$1"
  local host="$2"

  ssh_with_key "$user@$host" exit >/dev/null 2>&1
}

can_login_with_password() {
  local user="$1"
  local host="$2"
  local password="$3"

  if [ -z "$password" ]; then
    return 1
  fi

  ssh_with_password "$password" "$user@$host" exit >/dev/null 2>&1
}

can_login() {
  local user="$1"
  local host="$2"
  local password="${3:-}"
  local auth_mode="${4:-auto}"

  case "$auth_mode" in
    ssh_key)
      can_login_with_key "$user" "$host"
      ;;
    password)
      can_login_with_password "$user" "$host" "$password"
      ;;
    *)
      can_login_with_key "$user" "$host" || can_login_with_password "$user" "$host" "$password"
      ;;
  esac
}

run_remote() {
  local user="$1"
  local host="$2"
  local password="$3"
  local auth_mode="${4:-auto}"
  shift 4

  if [ "$auth_mode" = "ssh_key" ]; then
    ssh_with_key "$user@$host" "$@"
    return $?
  fi

  if [ "$auth_mode" = "password" ]; then
    if [ -n "$password" ]; then
      ssh_with_password "$password" "$user@$host" "$@"
      return $?
    fi
    return 1
  fi

  if can_login_with_key "$user" "$host"; then
    ssh_with_key "$user@$host" "$@"
    return $?
  fi

  if [ -n "$password" ]; then
    ssh_with_password "$password" "$user@$host" "$@"
    return $?
  fi

  return 1
}

run_remote_sudo_command() {
  local user="$1"
  local host="$2"
  local password="$3"
  local auth_mode="${4:-auto}"
  local remote_command="$5"
  local quoted_command

  printf -v quoted_command "%q" "$remote_command"

  if [ -n "$password" ]; then
    local password_escaped
    printf -v password_escaped "%q" "$password"
    run_remote "$user" "$host" "$password" "$auth_mode" "printf '%s\n' $password_escaped | sudo -S sh -lc $quoted_command"
    return $?
  fi

  run_remote "$user" "$host" "$password" "$auth_mode" "sudo sh -lc $quoted_command"
}

copy_to_remote() {
  local source_file="$1"
  local user="$2"
  local host="$3"
  local password="$4"
  local target_path="$5"
  local auth_mode="${6:-auto}"

  if [ "$auth_mode" = "ssh_key" ]; then
    scp -i "$NIX_CLUSTER_SSH_KEY" -o BatchMode=yes "${SSH_BASE_OPTS[@]}" "$source_file" "$user@$host:$target_path"
    return $?
  fi

  if [ "$auth_mode" = "password" ]; then
    if [ -n "$password" ]; then
      SSHPASS="$password" sshpass -e scp -o PreferredAuthentications=password -o PubkeyAuthentication=no "${SSH_BASE_OPTS[@]}" "$source_file" "$user@$host:$target_path"
      return $?
    fi
    return 1
  fi

  if can_login_with_key "$user" "$host"; then
    scp -i "$NIX_CLUSTER_SSH_KEY" -o BatchMode=yes "${SSH_BASE_OPTS[@]}" "$source_file" "$user@$host:$target_path"
    return $?
  fi

  if [ -n "$password" ]; then
    SSHPASS="$password" sshpass -e scp -o PreferredAuthentications=password -o PubkeyAuthentication=no "${SSH_BASE_OPTS[@]}" "$source_file" "$user@$host:$target_path"
    return $?
  fi

  return 1
}

wait_for_login() {
  local user="$1"
  local host="$2"
  local password="$3"
  local max_attempts="${4:-30}"
  local attempt=1

  until can_login "$user" "$host" "$password"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi

    sleep 10
    attempt=$((attempt + 1))
  done

  return 0
}

seed_installer_authorized_key() {
  local ssh_pub_key_escaped="$1"

  if [ -z "$ssh_pub_key_escaped" ]; then
    return 1
  fi

  run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF $ssh_pub_key_escaped ~/.ssh/authorized_keys 2>/dev/null || printf '%s\\n' $ssh_pub_key_escaped >> ~/.ssh/authorized_keys"
}

publish_controller_inventory() {
  local controller_payload

  controller_payload=$(jq -nc \
    --arg hostname "$CONTROLLER_HOSTNAME" \
    --arg installer_ip "$CONTROLLER_PRIMARY_IP" \
    --arg node_role "controller" \
    --arg keepalived_role "master" \
    --arg source "controller-runtime" \
    --arg state "active" \
    --arg seen_at "$(timestamp_utc)" \
    '{hostname: $hostname, installer_ip: $installer_ip, node_role: $node_role, keepalived_role: $keepalived_role, source: $source, state: $state, seen_at: $seen_at}')

  publish_inventory_record "$CONTROLLER_HOSTNAME" "$controller_payload"
}

publish_node_inventory() {
  local source_name="$1"
  local state_name="$2"
  local inventory_payload

  inventory_payload=$(jq -nc \
    --arg hostname "$HOSTNAME" \
    --arg installer_ip "$INSTALLER_IP" \
    --arg installer_user "$INSTALLER_USER" \
    --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
    --arg disk "$DISK" \
    --arg fs "$FS" \
    --arg node_group "$NODE_GROUP" \
    --arg node_role "$NODE_ROLE" \
    --arg keepalived_role "$KEEPALIVED_ROLE" \
    --arg node_admin "$NODE_ADMIN" \
    --arg source "$source_name" \
    --arg state "$state_name" \
    --arg controller "$CONTROLLER_HOSTNAME" \
    --arg seen_at "$(timestamp_utc)" \
    '{hostname: $hostname, installer_ip: $installer_ip, installer_user: $installer_user, installer_auth_mode: $installer_auth_mode, disk: $disk, fs: $fs, node_group: $node_group, node_role: $node_role, keepalived_role: $keepalived_role, node_admin: $node_admin, source: $source, state: $state, controller: $controller, seen_at: $seen_at}')

  publish_inventory_record "$HOSTNAME" "$inventory_payload"
}

publish_join_state() {
  local phase="$1"
  local detail="$2"
  local join_payload

  join_payload=$(jq -nc \
    --arg hostname "$HOSTNAME" \
    --arg installer_ip "$INSTALLER_IP" \
    --arg controller "$CONTROLLER_HOSTNAME" \
    --arg phase "$phase" \
    --arg detail "$detail" \
    --arg updated_at "$(timestamp_utc)" \
    '{hostname: $hostname, installer_ip: $installer_ip, controller: $controller, phase: $phase, detail: $detail, updated_at: $updated_at}')

  publish_join_record "$HOSTNAME" "$join_payload"
}

provision_live_installer() {
  local PXE_TEMP_DISABLED=0
  local TMP_DIR
  local HOST_ID
  local HASHED_PASS

  if [ -z "$DISK" ] || [ -z "$FS" ]; then
    echo "[nix-cluster] $HOSTNAME is missing disk or fs in deployments.json. Skipping."
    publish_join_state "invalid-config" "missing disk or fs"
    return 1
  fi

  if ! run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "test -b '$DISK'"; then
    echo "[nix-cluster] $HOSTNAME configured disk $DISK does not exist on the live installer. Available disks:"
    run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "lsblk -dn -o NAME,PATH,SIZE,MODEL,TYPE | awk '\$5 == \"disk\" { print }'" || true
    publish_join_state "invalid-config" "configured disk missing on installer"
    return 1
  fi

  publish_join_state "provisioning-live-installer" "running nixos-anywhere"

  TMP_DIR=$(mktemp -d)
  HOST_ID=$(head -c 4 /dev/urandom | od -A n -t x4 | tr -d ' ' | cut -c 1-8)
  if [ -n "$NODE_ADMIN_PASSWORD_HASH" ]; then
    HASHED_PASS="$NODE_ADMIN_PASSWORD_HASH"
  elif [ -n "$NODE_ADMIN_PASS" ]; then
    HASHED_PASS=$(mkpasswd -m sha-512 -s <<< "$NODE_ADMIN_PASS")
  else
    HASHED_PASS="!"
  fi

  cat <<EOF > "$TMP_DIR/flake.nix"
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    nixos-install.url = "git+NIXOS_INSTALL_REPO_URL_PLACEHOLDER";
  };
  outputs = { self, nixpkgs, disko, nixos-install }:
    let
      renderedDisko = builtins.toFile "disko-$FS.nix" (
        builtins.replaceStrings [ "__DISK__" ] [ "$DISK" ]
          (builtins.readFile (nixos-install + "/templates/disko-$FS.nix"))
      );
    in {
    nixosConfigurations."$HOSTNAME" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        renderedDisko
        ({ lib, ... }: lib.mkMerge [
          {
            networking.hostName = "$HOSTNAME";
            networking.hostId = "$HOST_ID";
            networking.networkmanager.enable = true;

            services.openssh.enable = true;
            services.openssh.openFirewall = true;
            services.openssh.settings.PasswordAuthentication = $SSH_PASSWORD_AUTH;
            services.openssh.settings.KbdInteractiveAuthentication = false;
            services.openssh.settings.PermitRootLogin = "no";

            users.mutableUsers = false;
            users.users.$NODE_ADMIN = {
              isNormalUser = true;
              extraGroups = [ "wheel" "networkmanager" ];
              hashedPassword = "$HASHED_PASS";
              openssh.authorizedKeys.keys = [ "$CONTROLLER_SSH_PUB_KEY" ];
            };

            security.sudo.wheelNeedsPassword = false;
            nix.settings.experimental-features = [ "nix-command" "flakes" ];
            system.stateVersion = "25.11";
          }
          (lib.mkIf ("$FS" == "zfs") {
            boot.loader.systemd-boot.enable = false;
            boot.loader.grub.enable = true;
            boot.loader.grub.devices = [ "nodev" ];
            boot.loader.grub.efiSupport = true;
            boot.loader.grub.useOSProber = false;
            boot.loader.efi.canTouchEfiVariables = true;
            boot.initrd.supportedFilesystems = [ "zfs" ];
            boot.supportedFilesystems = [ "zfs" ];
            boot.zfs.forceImportRoot = true;
            services.zfs.autoScrub.enable = true;
          })
          (lib.mkIf ("$FS" != "zfs") {
            boot.loader.systemd-boot.enable = true;
            boot.loader.efi.canTouchEfiVariables = true;
          })
        ])
      ];
    };
  };
}
EOF

  if [ "$INSTALLER_AUTH_MODE" = "ssh_key" ] || { [ "$INSTALLER_AUTH_MODE" = "auto" ] && can_login_with_key "$INSTALLER_USER" "$INSTALLER_IP"; }; then
    nix --extra-experimental-features "nix-command flakes" run github:nix-community/nixos-anywhere -- \
      --phases kexec,disko,install \
      --flake "$TMP_DIR#$HOSTNAME" \
      --target-host "$INSTALLER_USER@$INSTALLER_IP"
  elif [ "$INSTALLER_AUTH_MODE" = "password" ] && [ -n "$INSTALLER_PASSWORD" ]; then
    SSHPASS="$INSTALLER_PASSWORD" nix --extra-experimental-features "nix-command flakes" run github:nix-community/nixos-anywhere -- \
      --env-password \
      --phases kexec,disko,install \
      --flake "$TMP_DIR#$HOSTNAME" \
      --target-host "$INSTALLER_USER@$INSTALLER_IP"
  elif [ "$INSTALLER_AUTH_MODE" = "auto" ] && [ -n "$INSTALLER_PASSWORD" ]; then
    SSHPASS="$INSTALLER_PASSWORD" nix --extra-experimental-features "nix-command flakes" run github:nix-community/nixos-anywhere -- \
      --env-password \
      --phases kexec,disko,install \
      --flake "$TMP_DIR#$HOSTNAME" \
      --target-host "$INSTALLER_USER@$INSTALLER_IP"
  else
    echo "[nix-cluster] $HOSTNAME is reachable on the live installer, but no password was provided. Skipping."
    rm -rf "$TMP_DIR"
    return 1
  fi

  rm -rf "$TMP_DIR"

  if stop_pixiecore_for_disk_boot; then
    PXE_TEMP_DISABLED=1
  fi

  echo "[nix-cluster] Rebooting $HOSTNAME into the installed system..."
  run_remote_sudo_command "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true
  publish_join_state "waiting-for-installed-os" "waiting for first boot after install"

  echo "[nix-cluster] Waiting for $HOSTNAME to reboot..."
  if ! wait_for_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" 36; then
    if [ "$PXE_TEMP_DISABLED" -eq 1 ]; then
      start_pixiecore_after_disk_boot
    fi
    if can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"; then
      echo "[nix-cluster] $HOSTNAME rebooted back into the live installer instead of the installed system. Boot from the local disk to continue enrollment."
      publish_join_state "installer-returned" "node rebooted back into live installer"
    else
      echo "[nix-cluster] $HOSTNAME did not become reachable after installation. Skipping enrollment."
      publish_join_state "install-failed" "node did not become reachable after install"
    fi
    return 1
  fi

  if [ "$PXE_TEMP_DISABLED" -eq 1 ]; then
    start_pixiecore_after_disk_boot
  fi

  publish_join_state "installed-os-online" "installed system is reachable"

  return 0
}

# Extract Fleet Secrets for provisioning
GIT_USER=$(sudo env SOPS_AGE_KEY_FILE=$SOPS_KEY sops -d --extract '["git_username"]' secrets/secrets.yaml)
GIT_PASS=$(sudo env SOPS_AGE_KEY_FILE=$SOPS_KEY sops -d --extract '["git_password"]' secrets/secrets.yaml)
WEBHOOK_SECRET=$(sudo env SOPS_AGE_KEY_FILE=$SOPS_KEY sops -d --extract '["webhook_secret"]' secrets/secrets.yaml)
REPO_URL=$(git remote get-url origin | sed -E 's|^https?://[^/@]+:[^/@]+@|https://|')
CONTROLLER_SSH_PUB_KEY=$(cat "${NIX_CLUSTER_SSH_KEY}.pub")
CONTROLLER_SSH_PUB_KEY_ESCAPED=$(printf "%q" "$CONTROLLER_SSH_PUB_KEY")

publish_controller_inventory

while read -r node; do
  HOSTNAME=$(echo "$node" | jq -r '.hostname')
  INSTALLER_IP=$(echo "$node" | jq -r '.installer_ip')
  INSTALLER_USER=$(echo "$node" | jq -r '.installer_user // "nixos"')
  INSTALLER_PASSWORD=$(echo "$node" | jq -r '.installer_password // empty')
  INSTALLER_AUTH_MODE=$(echo "$node" | jq -r '.installer_auth_mode // "ssh_key"')
  INSTALLER_SSH_PUB_KEY=$(echo "$node" | jq -r '.installer_ssh_pub_key // empty')
  DISK=$(echo "$node" | jq -r '.disk')
  FS=$(echo "$node" | jq -r '.fs')
  NODE_GROUP=$(echo "$node" | jq -r '.node_group')
  NODE_ROLE=$(echo "$node" | jq -r '.node_role // "worker"')
  KEEPALIVED_ROLE=$(echo "$node" | jq -r '.keepalived_role // "backup"')
  NODE_ADMIN=$(echo "$node" | jq -r '.node_admin')
  NODE_ADMIN_PASS=$(echo "$node" | jq -r '.node_admin_pass // empty')
  NODE_ADMIN_PASSWORD_HASH=$(echo "$node" | jq -r '.node_admin_password_hash // empty')
  SSH_PASSWORD_AUTH=$(echo "$node" | jq -r '.ssh_password_auth // false')
  REINSTALL=$(echo "$node" | jq -r '.reinstall // "false"')

  if [ -z "$HOSTNAME" ] || [ -z "$INSTALLER_IP" ]; then
    echo "[nix-cluster] Skipping malformed deployment entry: $node"
    continue
  fi

  publish_node_inventory "deployments.json" "desired"
  publish_join_state "desired" "inventory record loaded from deployments.json"

  # State 1: Already active (answers as nix-cluster)
  if can_login_with_key nix-cluster "$INSTALLER_IP"; then
    publish_node_inventory "controller-probe" "active"
    if [ "$REINSTALL" = "true" ]; then
      echo "[nix-cluster] $HOSTNAME already active, but reinstall=true so a reprovision will be attempted."
      publish_join_state "reinstall-requested" "node active but reinstall=true"
    else
    echo "[nix-cluster] $HOSTNAME already active, skipping."
    publish_join_state "active" "node reachable with controller key"
    continue
    fi
  fi

  # State 2: Live ISO (answers as the installer user)
  if can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"; then
    echo "[nix-cluster] $HOSTNAME detected as Live ISO, provisioning through $INSTALLER_USER@$INSTALLER_IP..."
    publish_node_inventory "controller-probe" "live-installer"
    publish_join_state "live-installer" "live installer reachable"
    seed_installer_authorized_key "$CONTROLLER_SSH_PUB_KEY_ESCAPED" || true
    if ! provision_live_installer; then
      continue
    fi
  fi

  # State 3: Base OS (answers as admin user)
  if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS"; then
    publish_node_inventory "controller-probe" "base-os"
    publish_join_state "base-os" "base operating system reachable"
    if [ "$REINSTALL" != "true" ] && run_remote_sudo_command "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto "systemctl cat nix-cluster.service >/dev/null 2>&1 || systemctl cat nops.service >/dev/null 2>&1"; then
      echo "[nix-cluster] $HOSTNAME detected as Base OS and already enrolled, skipping."
      publish_join_state "enrolled" "nix-cluster service already present"
      continue
    fi

    if [ "$REINSTALL" = "true" ]; then
      echo "[nix-cluster] $HOSTNAME detected as Base OS, but reinstall=true so rebooting into netboot for a fresh install..."
      publish_join_state "rebooting-for-reinstall" "base os reachable and reinstall requested"
      run_remote_sudo_command "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true

      echo "[nix-cluster] Waiting for $HOSTNAME to come back on the live installer..."
      if ! wait_for_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" 18; then
        if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS"; then
          echo "[nix-cluster] $HOSTNAME came back on the installed system instead of netboot. Ensure PXE/network boot is selected first, then rerun the controller."
          publish_join_state "reinstall-blocked" "node rebooted back into installed system instead of installer"
        else
          echo "[nix-cluster] $HOSTNAME did not become reachable on the live installer after reboot. Skipping reinstall."
          publish_join_state "reinstall-failed" "node did not return on live installer"
        fi
        continue
      fi

      echo "[nix-cluster] $HOSTNAME is back on the live installer. Reinstalling..."
      publish_join_state "live-installer" "node returned on live installer for reinstall"
      seed_installer_authorized_key "$CONTROLLER_SSH_PUB_KEY_ESCAPED" || true
      if ! provision_live_installer; then
        continue
      fi
    fi

    echo "[nix-cluster] $HOSTNAME detected as Base OS, enrolling..."
    publish_join_state "enrolling" "copying runtime config and running installer"

    CONFIG_JSON=$(mktemp)
    if [ -n "$NIX_CLUSTER_CONFIG_TEMPLATE_INPUT" ]; then
      jq \
        --arg git_user "$GIT_USER" \
        --arg git_token "$GIT_PASS" \
        --arg repo_url "$REPO_URL" \
        --arg node_group "$NODE_GROUP" \
        --arg admin "$NODE_ADMIN" \
        --arg admin_password_hash "$NODE_ADMIN_PASSWORD_HASH" \
        --arg node_ssh_pub_key "$CONTROLLER_SSH_PUB_KEY" \
        --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
        --arg installer_ssh_pub_key "$INSTALLER_SSH_PUB_KEY" \
        --argjson ssh_password_auth "$SSH_PASSWORD_AUTH" \
        --arg node_role "$NODE_ROLE" \
        --arg keepalived_role "$KEEPALIVED_ROLE" \
        --arg fleet_private_key "$(sudo cat "$SOPS_KEY")" \
        --arg webhook_secret "$WEBHOOK_SECRET" \
        '.bootstrap_mode = false |
         .is_controller = ($node_role == "controller") |
         .git_user = $git_user |
         .git_token = $git_token |
         .repo_url = $repo_url |
         .node_group = $node_group |
         .node_admin = $admin |
         .node_admin_pass = "" |
         .node_admin_password_hash = $admin_password_hash |
         .node_ssh_pub_key = $node_ssh_pub_key |
         .ssh_password_auth = $ssh_password_auth |
         .installer_auth_mode = $installer_auth_mode |
         .installer_ssh_pub_key = $installer_ssh_pub_key |
         .node_role = $node_role |
         .keepalived_role = $keepalived_role |
         .fleet_private_key = $fleet_private_key |
         .webhook_secret = $webhook_secret' \
        "$NIX_CLUSTER_CONFIG_TEMPLATE_INPUT" > "$CONFIG_JSON"
    else
      jq -n \
        --arg git_user "$GIT_USER" \
        --arg git_token "$GIT_PASS" \
        --arg repo_url "$REPO_URL" \
        --arg node_group "$NODE_GROUP" \
        --arg admin "$NODE_ADMIN" \
        --arg admin_password_hash "$NODE_ADMIN_PASSWORD_HASH" \
        --arg node_ssh_pub_key "$CONTROLLER_SSH_PUB_KEY" \
        --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
        --arg installer_ssh_pub_key "$INSTALLER_SSH_PUB_KEY" \
        --argjson ssh_password_auth "$SSH_PASSWORD_AUTH" \
        --arg node_role "$NODE_ROLE" \
        --arg keepalived_role "$KEEPALIVED_ROLE" \
        --arg fleet_private_key "$(sudo cat "$SOPS_KEY")" \
        --arg webhook_secret "$WEBHOOK_SECRET" \
        '{bootstrap_mode: false, is_controller: ($node_role == "controller"), git_user: $git_user, git_token: $git_token, repo_url: $repo_url, node_group: $node_group, node_admin: $admin, node_admin_pass: "", node_admin_password_hash: $admin_password_hash, node_ssh_pub_key: $node_ssh_pub_key, ssh_password_auth: $ssh_password_auth, installer_auth_mode: $installer_auth_mode, installer_ssh_pub_key: $installer_ssh_pub_key, node_role: $node_role, keepalived_role: $keepalived_role, fleet_private_key: $fleet_private_key, trigger_choice: "2", webhook_secret: $webhook_secret}' > "$CONFIG_JSON"
    fi

    if copy_to_remote "$CONFIG_JSON" "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" /tmp/nix-cluster-config.json auto; then
      run_remote_sudo_command "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#git -c nix --extra-experimental-features 'nix-command flakes' run git+https://git.smallguytech.org/SGT/nix-cluster.git#install -- --config /tmp/nix-cluster-config.json"
      publish_join_state "install-triggered" "remote nix-cluster install command started"
    else
      echo "[nix-cluster] Failed to copy worker config to $HOSTNAME. Skipping enrollment."
      publish_join_state "enroll-failed" "failed to copy installer config to target"
    fi

    rm -f "$CONFIG_JSON"
    continue
  fi

  publish_node_inventory "controller-probe" "unreachable"
  publish_join_state "unreachable" "installer and base os both unreachable"
done < <(jq -c '.[]' "$DEPLOYMENTS_INPUT")