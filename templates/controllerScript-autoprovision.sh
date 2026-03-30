#!/usr/bin/env bash
# nops Controller Node: Autonomous Bare-Metal Provisioning State Machine
set -euo pipefail

# Configuration Paths
DEPLOYMENTS_JSON="deployments.json"
NOPS_SSH_KEY="/home/nops/.ssh/id_ed25519"
SOPS_KEY="/var/lib/sops-nix/key.txt"

SSH_BASE_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
)
TEMP_FILES=()

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

# Skip if there's no deployments file
if [ ! -f "$DEPLOYMENTS_JSON" ]; then
  exit 0
fi

DEPLOYMENTS_INPUT=$(mktemp)
prepare_json_input "$DEPLOYMENTS_JSON" "$DEPLOYMENTS_INPUT"

NOPS_CONFIG_TEMPLATE_INPUT=""
if [ -s "nops-config-template.json" ]; then
  NOPS_CONFIG_TEMPLATE_INPUT=$(mktemp)
  prepare_json_input "nops-config-template.json" "$NOPS_CONFIG_TEMPLATE_INPUT"
fi

echo "[nops] === Auto-Provisioning Fleet Nodes ==="

# Ensure SSH key exists for the Controller to access new nodes
if [ ! -f "$NOPS_SSH_KEY" ]; then
  mkdir -p "$(dirname "$NOPS_SSH_KEY")"
  ssh-keygen -t ed25519 -f "$NOPS_SSH_KEY" -N ""
fi

ssh_with_key() {
  local remote="$1"
  shift

  ssh -n -i "$NOPS_SSH_KEY" -o BatchMode=yes "${SSH_BASE_OPTS[@]}" "$remote" "$@"
}

ssh_with_password() {
  local password="$1"
  local remote="$2"
  shift 2

  SSHPASS="$password" sshpass -e ssh -n -o PreferredAuthentications=password -o PubkeyAuthentication=no "${SSH_BASE_OPTS[@]}" "$remote" "$@"
}

stop_pixiecore_for_disk_boot() {
  if sudo systemctl is-active --quiet pixiecore.service 2>/dev/null; then
    echo "[nops] Stopping pixiecore so the node can boot from local disk..."
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

copy_to_remote() {
  local source_file="$1"
  local user="$2"
  local host="$3"
  local password="$4"
  local target_path="$5"
  local auth_mode="${6:-auto}"

  if [ "$auth_mode" = "ssh_key" ]; then
    scp -i "$NOPS_SSH_KEY" -o BatchMode=yes "${SSH_BASE_OPTS[@]}" "$source_file" "$user@$host:$target_path"
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
    scp -i "$NOPS_SSH_KEY" -o BatchMode=yes "${SSH_BASE_OPTS[@]}" "$source_file" "$user@$host:$target_path"
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

provision_live_installer() {
  local PXE_TEMP_DISABLED=0
  local TMP_DIR
  local HOST_ID
  local HASHED_PASS

  if [ -z "$DISK" ] || [ -z "$FS" ]; then
    echo "[nops] $HOSTNAME is missing disk or fs in deployments.json. Skipping."
    return 1
  fi

  if ! run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "test -b '$DISK'"; then
    echo "[nops] $HOSTNAME configured disk $DISK does not exist on the live installer. Available disks:"
    run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "lsblk -dn -o NAME,PATH,SIZE,MODEL,TYPE | awk '\$5 == \"disk\" { print }'" || true
    return 1
  fi

  TMP_DIR=$(mktemp -d)
  HOST_ID=$(head -c 4 /dev/urandom | od -A n -t x4 | tr -d ' ' | cut -c 1-8)
  HASHED_PASS=$(mkpasswd -m sha-512 -s <<< "$NODE_ADMIN_PASS")

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
            services.openssh.settings.PasswordAuthentication = true;
            services.openssh.settings.KbdInteractiveAuthentication = false;

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
    echo "[nops] $HOSTNAME is reachable on the live installer, but no password was provided. Skipping."
    rm -rf "$TMP_DIR"
    return 1
  fi

  rm -rf "$TMP_DIR"

  if stop_pixiecore_for_disk_boot; then
    PXE_TEMP_DISABLED=1
  fi

  echo "[nops] Rebooting $HOSTNAME into the installed system..."
  run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "sudo nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true

  echo "[nops] Waiting for $HOSTNAME to reboot..."
  if ! wait_for_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" 36; then
    if [ "$PXE_TEMP_DISABLED" -eq 1 ]; then
      start_pixiecore_after_disk_boot
    fi
    if can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"; then
      echo "[nops] $HOSTNAME rebooted back into the live installer instead of the installed system. Boot from the local disk to continue enrollment."
    else
      echo "[nops] $HOSTNAME did not become reachable after installation. Skipping enrollment."
    fi
    return 1
  fi

  if [ "$PXE_TEMP_DISABLED" -eq 1 ]; then
    start_pixiecore_after_disk_boot
  fi

  return 0
}

# Extract Fleet Secrets for provisioning
GIT_USER=$(sudo env SOPS_AGE_KEY_FILE=$SOPS_KEY sops -d --extract '["git_username"]' secrets/secrets.yaml)
GIT_PASS=$(sudo env SOPS_AGE_KEY_FILE=$SOPS_KEY sops -d --extract '["git_password"]' secrets/secrets.yaml)
WEBHOOK_SECRET=$(sudo env SOPS_AGE_KEY_FILE=$SOPS_KEY sops -d --extract '["webhook_secret"]' secrets/secrets.yaml)
REPO_URL=$(git remote get-url origin | sed -E 's|^https?://[^/@]+:[^/@]+@|https://|')
CONTROLLER_SSH_PUB_KEY=$(cat "${NOPS_SSH_KEY}.pub")

while read -r node; do
  HOSTNAME=$(echo "$node" | jq -r '.hostname')
  INSTALLER_IP=$(echo "$node" | jq -r '.installer_ip')
  INSTALLER_USER=$(echo "$node" | jq -r '.installer_user // "nixos"')
  INSTALLER_PASSWORD=$(echo "$node" | jq -r '.installer_password // empty')
  INSTALLER_AUTH_MODE=$(echo "$node" | jq -r '.installer_auth_mode // "auto"')
  INSTALLER_SSH_PUB_KEY=$(echo "$node" | jq -r '.installer_ssh_pub_key // empty')
  DISK=$(echo "$node" | jq -r '.disk')
  FS=$(echo "$node" | jq -r '.fs')
  NODE_GROUP=$(echo "$node" | jq -r '.node_group')
  NODE_ROLE=$(echo "$node" | jq -r '.node_role // "worker"')
  KEEPALIVED_ROLE=$(echo "$node" | jq -r '.keepalived_role // "backup"')
  NODE_ADMIN=$(echo "$node" | jq -r '.node_admin')
  NODE_ADMIN_PASS=$(echo "$node" | jq -r '.node_admin_pass')
  REINSTALL=$(echo "$node" | jq -r '.reinstall // "false"')

  if [ -z "$HOSTNAME" ] || [ -z "$INSTALLER_IP" ]; then
    echo "[nops] Skipping malformed deployment entry: $node"
    continue
  fi

  # State 1: Already active (answers as nops)
  if can_login_with_key nops "$INSTALLER_IP"; then
    if [ "$REINSTALL" = "true" ]; then
      echo "[nops] $HOSTNAME already active, but reinstall=true so a reprovision will be attempted."
    else
    echo "[nops] $HOSTNAME already active, skipping."
    continue
    fi
  fi

  # State 2: Live ISO (answers as the installer user)
  if can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"; then
    echo "[nops] $HOSTNAME detected as Live ISO, provisioning through $INSTALLER_USER@$INSTALLER_IP..."
    if ! provision_live_installer; then
      continue
    fi
  fi

  # State 3: Base OS (answers as admin user)
  if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS"; then
    if [ "$REINSTALL" = "true" ]; then
      echo "[nops] $HOSTNAME detected as Base OS, but reinstall=true so rebooting into netboot for a fresh install..."
      run_remote "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto "printf '%s\n' '$NODE_ADMIN_PASS' | sudo -S nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true

      echo "[nops] Waiting for $HOSTNAME to come back on the live installer..."
      if ! wait_for_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" 18; then
        if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS"; then
          echo "[nops] $HOSTNAME came back on the installed system instead of netboot. Ensure PXE/network boot is selected first, then rerun the controller."
        else
          echo "[nops] $HOSTNAME did not become reachable on the live installer after reboot. Skipping reinstall."
        fi
        continue
      fi

      echo "[nops] $HOSTNAME is back on the live installer. Reinstalling..."
      if ! provision_live_installer; then
        continue
      fi
    fi

    echo "[nops] $HOSTNAME detected as Base OS, enrolling..."

    CONFIG_JSON=$(mktemp)
    if [ -n "$NOPS_CONFIG_TEMPLATE_INPUT" ]; then
      jq \
        --arg git_user "$GIT_USER" \
        --arg git_token "$GIT_PASS" \
        --arg repo_url "$REPO_URL" \
        --arg node_group "$NODE_GROUP" \
        --arg admin "$NODE_ADMIN" \
        --arg admin_pass "$NODE_ADMIN_PASS" \
        --arg node_ssh_pub_key "$CONTROLLER_SSH_PUB_KEY" \
        --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
        --arg installer_ssh_pub_key "$INSTALLER_SSH_PUB_KEY" \
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
         .node_admin_pass = $admin_pass |
         .node_ssh_pub_key = $node_ssh_pub_key |
         .installer_auth_mode = $installer_auth_mode |
         .installer_ssh_pub_key = $installer_ssh_pub_key |
         .node_role = $node_role |
         .keepalived_role = $keepalived_role |
         .fleet_private_key = $fleet_private_key |
         .webhook_secret = $webhook_secret' \
        "$NOPS_CONFIG_TEMPLATE_INPUT" > "$CONFIG_JSON"
    else
      jq -n \
        --arg git_user "$GIT_USER" \
        --arg git_token "$GIT_PASS" \
        --arg repo_url "$REPO_URL" \
        --arg node_group "$NODE_GROUP" \
        --arg admin "$NODE_ADMIN" \
        --arg admin_pass "$NODE_ADMIN_PASS" \
        --arg node_ssh_pub_key "$CONTROLLER_SSH_PUB_KEY" \
        --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
        --arg installer_ssh_pub_key "$INSTALLER_SSH_PUB_KEY" \
        --arg node_role "$NODE_ROLE" \
        --arg keepalived_role "$KEEPALIVED_ROLE" \
        --arg fleet_private_key "$(sudo cat "$SOPS_KEY")" \
        --arg webhook_secret "$WEBHOOK_SECRET" \
        '{bootstrap_mode: false, is_controller: ($node_role == "controller"), git_user: $git_user, git_token: $git_token, repo_url: $repo_url, node_group: $node_group, node_admin: $admin, node_admin_pass: $admin_pass, node_ssh_pub_key: $node_ssh_pub_key, installer_auth_mode: $installer_auth_mode, installer_ssh_pub_key: $installer_ssh_pub_key, node_role: $node_role, keepalived_role: $keepalived_role, fleet_private_key: $fleet_private_key, trigger_choice: "2", webhook_secret: $webhook_secret}' > "$CONFIG_JSON"
    fi

    if copy_to_remote "$CONFIG_JSON" "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" /tmp/nops-config.json "$INSTALLER_AUTH_MODE"; then
      run_remote "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" "$INSTALLER_AUTH_MODE" "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#git -c sh -lc 'sudo env PATH=\"\$PATH\" nix --extra-experimental-features \"nix-command flakes\" run git+NOPS_INSTALL_REPO_URL_PLACEHOLDER#install -- --config /tmp/nops-config.json'"
    else
      echo "[nops] Failed to copy worker config to $HOSTNAME. Skipping enrollment."
    fi

    rm -f "$CONFIG_JSON"
  fi
done < <(jq -c '.[]' "$DEPLOYMENTS_INPUT")