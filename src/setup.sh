#!/usr/bin/env bash
set -e

HOSTNAME=$(hostname)
TARGET_DIR="/home/nad/$HOSTNAME"
CONFIG_SRC="${NAD_CONFIG_DIR:-../config}" 
SRC_DIR="${NAD_SRC_DIR:-../src}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[NAD-SETUP]${NC} $1"; }
log "Setup Users..."

read -p "SETUP ADMIN USERNAME (Outside of 'nad'): " ADMIN_USER
read -s -p "SETUP PASSWORD FOR $ADMIN_USER: " ADMIN_PASS
echo ""

log "Git Auth"

read -s -p "ENTER GIT ACCESS TOKEN/PASSWORD: " GIT_TOKEN
echo ""

#handle keys
KEY_FILE="/var/lib/sops-nix/key.txt"
if [ ! -f "$KEY_FILE" ]; then
    sudo mkdir -p $(dirname $KEY_FILE)
    sudo age-keygen -o "$KEY_FILE"
    sudo chmod 600 "$KEY_FILE"
    sudo chown root:root "$KEY_FILE"
fi
PUB_KEY=$(sudo age-keygen -y "$KEY_FILE")

#clone repo
log "Cloning Private Configuration..."
read -p "Enter Repository URL: " REPO_URL
[ -d "$TARGET_DIR" ] && sudo rm -rf "$TARGET_DIR"

#handle git / repo
TEMP_USER_FILE="/home/nad/.git-temp-user"
TEMP_PASS_FILE="/home/nad/.git-temp-pass"

printf "%s" "$ADMIN_USER" | sudo -u nad tee "$TEMP_USER_FILE" > /dev/null
printf "%s" "$GIT_TOKEN" | sudo -u nad tee "$TEMP_PASS_FILE" > /dev/null
sudo chmod 600 "$TEMP_USER_FILE" "$TEMP_PASS_FILE"

#store git creds
TEMP_HELPER="/home/nad/.git-credential-helper-temp"
sudo -u nad tee "$TEMP_HELPER" > /dev/null <<EOF
#!/bin/sh
echo username=\$(cat "$TEMP_USER_FILE")
echo password=\$(cat "$TEMP_PASS_FILE")
EOF
sudo chmod +x "$TEMP_HELPER"

sudo -u nad git config --global credential.helper "$TEMP_HELPER"
sudo -u nad git config --global --add safe.directory "$TARGET_DIR"
sudo git config --global --add safe.directory "$TARGET_DIR"

#clone repo
log "Cloning repository..."
sudo -u nad git clone "$REPO_URL" "$TARGET_DIR"

#copy templates
log "Copying templates..."
sudo -u nad cp -r "$CONFIG_SRC"/. "$TARGET_DIR"
sudo -u nad mkdir -p "$TARGET_DIR/src" "$TARGET_DIR/log"
sudo -u nad cp "$SRC_DIR/ops.yaml" "$TARGET_DIR/src/ops.yaml"
sudo -u nad touch "$TARGET_DIR/log/main.log"

#copy hardware-configuration.nix to /home/nad/$HOST_NAME/
if [ -f "/etc/nixos/hardware-configuration.nix" ]; then
    sudo cp /etc/nixos/hardware-configuration.nix "$TARGET_DIR/hardware-configuration.nix"
    sudo chown nad: "$TARGET_DIR/hardware-configuration.nix"
fi

#hyrdating /home/nad/$HOST_NAME/
log "Hydrating ..."
sudo -u nad sed -i "s|networking.hostName = \".*\";|networking.hostName = \"$HOSTNAME\";|" "$TARGET_DIR/configuration.nix"
sudo -u nad sed -i "s|users.users.admin_placeholder|users.users.$ADMIN_USER|" "$TARGET_DIR/configuration.nix"
sudo -u nad sed -i "s|initialPassword = \".*\";|initialPassword = \"$ADMIN_PASS\";|" "$TARGET_DIR/configuration.nix"
sudo -u nad sed -i "s|nixosConfigurations\..* =|    nixosConfigurations.$HOSTNAME =|" "$TARGET_DIR/flake.nix"

sudo -u nad sed -i "s|repo: \".*\"|repo: \"$TARGET_DIR\"|" "$TARGET_DIR/src/ops.yaml"
sudo -u nad sed -i "s|log: \".*\"|log: \"$TARGET_DIR/log\"|" "$TARGET_DIR/src/ops.yaml"
sudo -u nad sed -i "s|.*nixos-rebuild.*flake.*|    - [\"sudo\", \"nixos-rebuild\", \"switch\", \"--flake\", \".#$HOSTNAME\", \"--impure\"]|" "$TARGET_DIR/src/ops.yaml"

# secrets
log "Setting up SOPS..."
SOPS_CONFIG="$TARGET_DIR/.sops.yaml"
sudo -u nad tee "$SOPS_CONFIG" > /dev/null <<EOF
creation_rules:
  - path_regex: secrets.yaml$
    key_groups:
      - age:
        - $PUB_KEY
EOF

# inject creds
SECRETS_FILE="$TARGET_DIR/secrets.yaml"
printf "forgejo_webhook_secret: PASTE_WEBHOOK_SECRET_HERE\n" | sudo -u nad tee "$SECRETS_FILE" > /dev/null
printf "git_username: " | sudo -u nad tee -a "$SECRETS_FILE" > /dev/null
sudo -u nad cat "$TEMP_USER_FILE" | sudo -u nad tee -a "$SECRETS_FILE" > /dev/null
printf "\n" | sudo -u nad tee -a "$SECRETS_FILE" > /dev/null
printf "git_password: " | sudo -u nad tee -a "$SECRETS_FILE" > /dev/null
sudo -u nad cat "$TEMP_PASS_FILE" | sudo -u nad tee -a "$SECRETS_FILE" > /dev/null
printf "\n" | sudo -u nad tee -a "$SECRETS_FILE" > /dev/null

log "Opening secrets.yaml... PASTE YOUR WEBHOOK SECRET NOW."
log "Your Git credentials have been auto-filled."
read -p "Press Enter to open editor..."
sudo vim "$SECRETS_FILE"

sudo -u nad sops --config "$SOPS_CONFIG" --encrypt --in-place "$SECRETS_FILE"

#set up perms push repo
log "Finalizing permissions..."
sudo chown -R nad: "$TARGET_DIR"
sudo -u nad git -C "$TARGET_DIR" config user.email "nad@installer.local"
sudo -u nad git -C "$TARGET_DIR" config user.name "NAD Installer"
sudo -u nad git -C "$TARGET_DIR" add .
sudo -u nad git -C "$TARGET_DIR" commit -m "Bootstrap: $HOSTNAME (Admin: $ADMIN_USER)"
sudo -u nad git -C "$TARGET_DIR" push origin main

#rebuild nix & clean
log "Initiating system rebuild..."
sudo nixos-rebuild switch --flake "$TARGET_DIR#$HOSTNAME" --upgrade
sudo rm "$TEMP_HELPER" "$TEMP_USER_FILE" "$TEMP_PASS_FILE"
sudo -u nad git config --global --unset credential.helper

echo -e "${GREEN}[SUCCESS]${NC} NAD is now managing $HOSTNAME."