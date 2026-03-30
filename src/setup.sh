#!/usr/bin/env bash
# Enrolls a new node into the fleet: creates the nops user, clones the repo, scaffolds node config, configures SOPS, and pushes the enrollment commit.
set -e

# Ensure clean exit after git push (for Controller automation)
trap 'exit 0' EXIT

HOSTNAME=$(hostname)
TEMPLATES_DIR="${NOPS_TEMPLATES_DIR:-../templates}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILE=""
NON_INTERACTIVE=false
CLEAN=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --config) CONFIG_FILE="$2"; shift ;;
        --clean) CLEAN=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file $CONFIG_FILE not found!"
        exit 1
    fi
    NON_INTERACTIVE=true
fi

LOG_FILE="/var/log/nops-setup.log"

# Writes a timestamped INFO entry to both stdout and the log file.
log() { 
    echo -e "${BLUE}[nops-setup]${NC} $1"
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [nops-setup] [INFO] $1" | sudo tee -a "$LOG_FILE" > /dev/null
}

# Prints a yellow warning to stdout only.
warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Extracts the hostname component from an HTTP or HTTPS repository URL.
extract_repo_host() {
    echo "$1" | sed -E 's|^[A-Za-z]+://([^/@]+@)?([^/:]+)(:[0-9]+)?/.*$|\2|'
}

# Pins a hostname to a specific IP address in /etc/hosts on the current node.
set_hosts_entry() {
    local host_name="$1"
    local host_ip="$2"
    local escaped_host

    escaped_host=$(printf '%s\n' "$host_name" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
    sudo sed -i -E "/(^|[[:space:]])${escaped_host}([[:space:]]|$)/d" /etc/hosts
    printf '%s %s\n' "$host_ip" "$host_name" | sudo tee -a /etc/hosts > /dev/null
}

# Warns when the shared Git hostname resolves publicly instead of to an internal service IP.
warn_if_repo_host_resolves_publicly() {
    local host_name="$1"
    local resolved_ips

    resolved_ips=$(getent hosts "$host_name" 2>/dev/null | awk '{print $1}')
    if [ -z "$resolved_ips" ]; then
        warn "repo_url host '${host_name}' did not resolve on this node. Configure internal DNS or set repo_host_ip to pin it during install."
        return 0
    fi

    if ! echo "$resolved_ips" | grep -Eq '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|::1$|fc|fd)'; then
        warn "repo_url host '${host_name}' resolves to non-private addresses on this node. Internal Git traffic may hairpin through public DNS or fail. Configure internal DNS or set repo_host_ip."
    fi
}

# Exits when a numeric config value is missing or outside the accepted range.
require_integer_in_range() {
    local field_name="$1"
    local field_value="$2"
    local min_value="$3"
    local max_value="$4"

    if ! [[ "$field_value" =~ ^[0-9]+$ ]]; then
        echo "Error: ${field_name} must be an integer between ${min_value} and ${max_value}. Got: ${field_value}"
        exit 1
    fi

    if [ "$field_value" -lt "$min_value" ] || [ "$field_value" -gt "$max_value" ]; then
        echo "Error: ${field_name} must be between ${min_value} and ${max_value}. Got: ${field_value}"
        exit 1
    fi
}

# Writes a string secret into a SOPS document using valid JSON encoding.
set_sops_string_secret() {
    local key_name="$1"
    local key_value="$2"
    local target_file="$3"
    local json_value

    json_value=$(jq -Rn --arg value "$key_value" '$value')
    sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set "[\"${key_name}\"] ${json_value}" "$target_file"
}

# Decrypts a SOPS-managed JSON file to a temp file or copies plaintext through unchanged.
prepare_json_for_edit() {
    local source_file="$1"
    local temp_file="$2"

    if sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d "$source_file" 2>/dev/null | tee "$temp_file" >/dev/null; then
        return 0
    fi

    sudo -u nops cp --no-preserve=mode "$source_file" "$temp_file"
}

# Encrypts plaintext JSON files or rotates keys for already encrypted ones.
sync_encrypted_json_file() {
    local target_file="$1"

    if [ ! -f "$target_file" ]; then
        return 0
    fi

    if sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d "$target_file" >/dev/null 2>&1; then
        if ! sudo -u nops sops updatekeys -y "$target_file" 2>/dev/null; then
            warn "Manual authorization required on another node for $(basename "$target_file") key rotation."
        fi
        return 0
    fi

    if ! sudo -u nops sops --config "$SOPS_CONFIG" --encrypt --in-place "$target_file" 2>/dev/null; then
        warn "Could not encrypt $(basename "$target_file") during bootstrap; keeping the plaintext file for now."
        return 0
    fi
}

# Upserts a proxied Cloudflare CNAME record for the supplied name and target.
upsert_cloudflare_cname_record() {
    local api_token="$1"
    local zone_id="$2"
    local zone_domain="$3"
    local record_name="$4"
    local record_target="$5"
    local fqdn
    local query_name
    local list_response
    local record_id
    local payload

    if [ "$record_name" = "@" ]; then
        fqdn="$zone_domain"
    else
        fqdn="${record_name}.${zone_domain}"
    fi

    query_name=$(jq -nr --arg value "$fqdn" '$value | @uri')
    list_response=$(curl -fsS --max-time 30 \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${query_name}") || return 1

    record_id=$(echo "$list_response" | jq -r '.result[0].id // empty')
    payload=$(jq -n \
        --arg type "CNAME" \
        --arg name "$record_name" \
        --arg content "$record_target" \
        '{ type: $type, name: $name, content: $content, proxied: true }')

    if [ -n "$record_id" ]; then
        curl -fsS --max-time 30 \
            -X PUT \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type: application/json" \
            --data "$payload" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" >/dev/null || return 1
    else
        curl -fsS --max-time 30 \
            -X POST \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type: application/json" \
            --data "$payload" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" >/dev/null || return 1
    fi
}

# Reuses an existing Cloudflare tunnel when the requested tunnel name already exists.
reuse_existing_cloudflare_tunnel() {
    local repo_dir="$1"
    local api_token
    local tunnel_name
    local tunnel_domain
    local account_id
    local zone_id
    local encoded_name
    local tunnel_lookup_response
    local tunnel_id
    local token_response
    local tunnel_token
    local tunnel_target

    cd "$repo_dir"

    api_token=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_api_token"]' secrets/secrets.yaml)
    tunnel_name=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_name"]' secrets/secrets.yaml)
    tunnel_domain=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_domain"]' secrets/secrets.yaml)
    account_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_account_id"]' secrets/secrets.yaml)
    zone_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_zone_id"]' secrets/secrets.yaml)

    encoded_name=$(jq -nr --arg value "$tunnel_name" '$value | @uri')
    tunnel_lookup_response=$(curl -fsS --max-time 30 \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel?is_deleted=false&name=${encoded_name}") || return 1

    tunnel_id=$(echo "$tunnel_lookup_response" | jq -r '.result[0].id // empty')
    if [ -z "$tunnel_id" ]; then
        return 1
    fi

    token_response=$(curl -fsS --max-time 30 \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/token") || return 1

    tunnel_token=$(echo "$token_response" | jq -r '.result // .result.token // .token // empty')
    if [ -z "$tunnel_token" ]; then
        return 1
    fi

    tunnel_target="${tunnel_id}.cfargotunnel.com"
    upsert_cloudflare_cname_record "$api_token" "$zone_id" "$tunnel_domain" "*" "$tunnel_target" || return 1
    upsert_cloudflare_cname_record "$api_token" "$zone_id" "$tunnel_domain" "@" "$tunnel_target" || return 1

    set_sops_string_secret "cloudflare_tunnel_token" "$tunnel_token" "secrets/secrets.yaml"

    git add secrets/secrets.yaml
    git commit -m "chore: reuse CF tunnel token [skip nops]" || true
    git push origin main || true

    log "Reused existing Cloudflare tunnel. Tunnel ID: ${tunnel_id}, Tunnel Name: ${tunnel_name}"
}

# Prints recent diagnostics for the given systemd unit to help explain rebuild failures.
log_unit_diagnostics() {
    local unit_name="$1"

    log "=== ${unit_name} status ==="
    sudo systemctl status "$unit_name" --no-pager || true

    log "=== ${unit_name} journal (last 50 lines) ==="
    sudo journalctl -u "$unit_name" -n 50 --no-pager || true
}

# Prints failed unit details after a rebuild failure so the root cause is visible in installer output.
log_rebuild_failure_details() {
    log "Initial rebuild failed. Collecting systemd diagnostics..."

    local failed_units
    failed_units=$(sudo systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')

    if [ -z "$failed_units" ]; then
        warn "No failed systemd units were reported."
        return 0
    fi

    log "Failed units: $(echo "$failed_units" | tr '\n' ' ')"

    while IFS= read -r unit_name; do
        [ -n "$unit_name" ] || continue
        log_unit_diagnostics "$unit_name"
    done <<EOF
$failed_units
EOF
}

# Waits for Forgejo's HTTP endpoint to answer before bootstrap API calls proceed.
wait_for_forgejo_http() {
    local max_attempts="${1:-30}"
    local attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        if curl -fsS "http://localhost:3000/api/healthz" >/dev/null 2>&1 || curl -fsS "http://localhost:3000/" >/dev/null 2>&1; then
            log "Forgejo HTTP endpoint is ready."
            return 0
        fi

        log "Waiting for Forgejo HTTP endpoint... attempt $attempt/$max_attempts"
        sleep 2
        attempt=$((attempt + 1))
    done

    warn "Forgejo HTTP endpoint did not become ready in time."
    return 1
}

# Fixes Forgejo runtime ownership after the first rebuild so the daemon can update app.ini on first boot.
repair_forgejo_runtime_permissions() {
    log "Repairing Forgejo runtime permissions..."

    sudo install -d -o forgejo -g forgejo -m 0750 /var/lib/forgejo/custom/conf
    sudo install -d -o forgejo -g forgejo -m 0750 /var/lib/forgejo/data
    sudo install -d -o forgejo -g forgejo -m 0750 /var/lib/forgejo/log
    sudo install -d -o forgejo -g forgejo -m 0750 /var/lib/forgejo/repositories
    sudo install -d -o forgejo -g forgejo -m 0750 /var/lib/forgejo/dump

    if [ -f /var/lib/forgejo/custom/conf/app.ini ]; then
        sudo chown forgejo:forgejo /var/lib/forgejo/custom/conf/app.ini
        sudo chmod 0640 /var/lib/forgejo/custom/conf/app.ini
    fi

    sudo chown -R forgejo:forgejo /var/lib/forgejo/custom /var/lib/forgejo/data /var/lib/forgejo/log /var/lib/forgejo/repositories /var/lib/forgejo/dump
    sudo chmod 0400 /var/lib/forgejo/custom/conf/secret_key 2>/dev/null || true
    sudo chmod 0400 /var/lib/forgejo/custom/conf/internal_token 2>/dev/null || true
    sudo chmod 0400 /var/lib/forgejo/custom/conf/oauth2_jwt_secret 2>/dev/null || true

    sudo systemctl reset-failed forgejo 2>/dev/null || true
    sudo systemctl restart forgejo 2>/dev/null || true
}

# Recreates the minimum Forgejo runtime state required for systemd credentials after a clean wipe.
prepare_forgejo_state() {
    log "Preparing Forgejo bootstrap state..."

    local forgejo_user="root"
    local forgejo_group="root"

    if id forgejo >/dev/null 2>&1; then
        forgejo_user="forgejo"
        forgejo_group="forgejo"
    else
        warn "Forgejo user is not present yet. Preparing bootstrap state as root until the first rebuild creates the service account."
    fi

    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/custom
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/custom/conf
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/data
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/data/tmp
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/data/tmp/package-upload
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/repositories
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/log
    sudo install -d -o "$forgejo_user" -g "$forgejo_group" -m 0750 /var/lib/forgejo/dump

    if [ ! -f /var/lib/forgejo/custom/conf/secret_key ]; then
        sudo sh -c 'umask 077; tr -dc "A-Za-z0-9" </dev/urandom | head -c 64 > /var/lib/forgejo/custom/conf/secret_key'
    fi
    if [ ! -f /var/lib/forgejo/custom/conf/internal_token ]; then
        sudo sh -c 'umask 077; tr -dc "A-Za-z0-9" </dev/urandom | head -c 64 > /var/lib/forgejo/custom/conf/internal_token'
    fi
    if [ ! -f /var/lib/forgejo/custom/conf/oauth2_jwt_secret ]; then
        sudo sh -c 'umask 077; tr -dc "A-Za-z0-9" </dev/urandom | head -c 64 > /var/lib/forgejo/custom/conf/oauth2_jwt_secret'
    fi

    sudo chown -R "$forgejo_user:$forgejo_group" /var/lib/forgejo
    sudo chmod 0750 /var/lib/forgejo/custom/conf
    sudo chmod 0400 /var/lib/forgejo/custom/conf/secret_key
    sudo chmod 0400 /var/lib/forgejo/custom/conf/internal_token
    sudo chmod 0400 /var/lib/forgejo/custom/conf/oauth2_jwt_secret
}

# Runs the built-in Cloudflare Terraform flow and commits the tunnel token back into SOPS.
run_cloudflare_provisioning() {
    local repo_dir="$1"

    if [ "${CF_TUNNEL:-false}" != "true" ] || [ "${IS_CONTROLLER:-false}" != "true" ] || [ ! -d "$repo_dir/modules/terraform" ]; then
        return 0
    fi

    log "Running immediate Cloudflare provisioning..."

    (
        set -e
        cd "$repo_dir"

        TF_VAR_cloudflare_api_token=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_api_token"]' secrets/secrets.yaml)
        TF_VAR_tunnel_name=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_name"]' secrets/secrets.yaml)
        TF_VAR_tunnel_domain=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_domain"]' secrets/secrets.yaml)
        TF_VAR_cloudflare_account_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_account_id"]' secrets/secrets.yaml)
        TF_VAR_cloudflare_zone_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_zone_id"]' secrets/secrets.yaml)
        export TF_VAR_cloudflare_api_token TF_VAR_tunnel_name TF_VAR_tunnel_domain TF_VAR_cloudflare_account_id TF_VAR_cloudflare_zone_id

        cd modules/terraform
        log "Running terraform init in $repo_dir/modules/terraform..."
        terraform init -input=false
        log "Running terraform plan for Cloudflare tunnel..."
        terraform plan -input=false -out=tfplan
        log "Running terraform apply for Cloudflare tunnel..."
        if ! terraform apply -input=false tfplan; then
            warn "Terraform apply failed. Attempting to reuse an existing Cloudflare tunnel with the requested name..."
            cd ../..
            reuse_existing_cloudflare_tunnel "$repo_dir" || return 1
            return 0
        fi
        rm -f tfplan

        TOKEN=$(terraform output -raw tunnel_token)
        TUNNEL_ID=$(terraform output -raw tunnel_id 2>/dev/null || true)
        TUNNEL_NAME=$(terraform output -raw tunnel_name 2>/dev/null || true)
        cd ../..

        log "Cloudflare provisioning complete. Tunnel ID: ${TUNNEL_ID:-unknown}, Tunnel Name: ${TUNNEL_NAME:-unknown}"

        if [ -n "$TOKEN" ] && [[ "$TOKEN" != *"No outputs found"* ]] && ! sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d secrets/secrets.yaml | grep -q "$TOKEN"; then
            log "Cloudflare tunnel token changed. Updating encrypted secrets..."
            set_sops_string_secret "cloudflare_tunnel_token" "$TOKEN" "secrets/secrets.yaml"
            git add secrets/secrets.yaml
            git commit -m "chore: update CF tunnel token [skip nops]" || true
            log "Pushing updated tunnel token back to origin..."
            git push origin main || warn "Could not push tunnel token update immediately; it will be included in the final bootstrap push."
        fi
    )
}

log "Initializing nops Fleet Enrollment for $HOSTNAME..."

# Wipes the nops user, home directory, and age key to allow a clean re-enrollment.
if [ "$CLEAN" = true ]; then
    log "--clean flag detected. Wiping previous nops state..."
    if id "nops" &>/dev/null; then
        sudo userdel -r nops 2>/dev/null || true
        sudo groupdel nops 2>/dev/null || true
    fi
    sudo rm -rf /home/nops
    sudo rm -f /var/lib/sops-nix/key.txt
    sudo git config --global --unset-all safe.directory 2>/dev/null || true
    log "Clean complete."
fi

# Creates the nops service user and group if absent; ensures correct home directory ownership.
if ! id "nops" &>/dev/null; then
    log "User 'nops' does not exist. Creating temporary service user..."
    sudo groupadd nops || true
    sudo useradd -m -g nops -s /run/current-system/sw/bin/bash nops
fi
sudo mkdir -p /home/nops
sudo chown -R nops:nops /home/nops
sudo -u nops mkdir -p /home/nops/.ssh
sudo chmod 700 /home/nops/.ssh

if [ ! -f /home/nops/.ssh/id_ed25519 ]; then
    log "Generating controller SSH key for automated provisioning..."
    sudo -u nops ssh-keygen -t ed25519 -f /home/nops/.ssh/id_ed25519 -N ""
fi

CONTROLLER_NODE_SSH_PUB_KEY=$(sudo -u nops cat /home/nops/.ssh/id_ed25519.pub)

# Reads git credentials, repo URL, group, admin user, trigger mode, and secrets from a JSON config file or interactive prompts.
if [ "$NON_INTERACTIVE" = true ]; then
    log "Non-interactive mode enabled. Reading from $CONFIG_FILE..."
    IS_BOOTSTRAP=$(jq -r '.bootstrap_mode // "false"' "$CONFIG_FILE")
    GIT_USER=$(jq -r '.git_user // empty' "$CONFIG_FILE")
    GIT_TOKEN=$(jq -r '.git_token // empty' "$CONFIG_FILE")
    REPO_URL=$(jq -r '.repo_url // empty' "$CONFIG_FILE")
    REPO_HOST_IP=$(jq -r '.repo_host_ip // empty' "$CONFIG_FILE")
    NOPS_REPO_URL=$(jq -r '.nops_repo_url // empty' "$CONFIG_FILE")
    NIXOS_INSTALL_REPO_URL=$(jq -r '.nixos_install_repo_url // empty' "$CONFIG_FILE")
    NODE_GROUP=$(jq -r '.node_group // "default"' "$CONFIG_FILE")
    NODE_ADMIN=$(jq -r '.node_admin // empty' "$CONFIG_FILE")
    NODE_ADMIN_PASS=$(jq -r '.node_admin_pass // empty' "$CONFIG_FILE")
    NODE_SSH_PUB_KEY=$(jq -r '.node_ssh_pub_key // empty' "$CONFIG_FILE")
    INSTALLER_AUTH_MODE=$(jq -r '.installer_auth_mode // "auto"' "$CONFIG_FILE")
    INSTALLER_SSH_PUB_KEY=$(jq -r '.installer_ssh_pub_key // empty' "$CONFIG_FILE")
    NODE_ROLE=$(jq -r '.node_role // "worker"' "$CONFIG_FILE")
    KEEPALIVED_ROLE=$(jq -r '.keepalived_role // "backup"' "$CONFIG_FILE")
    TRIGGER_CHOICE=$(jq -r '.trigger_choice // "2"' "$CONFIG_FILE")
    FLEET_PRIVATE_KEY=$(jq -r '.fleet_private_key // empty' "$CONFIG_FILE")
    
    MATRIX_BOT_TOKEN=$(jq -r '.matrix_bot_token // ""' "$CONFIG_FILE")
    MATRIX_ROOM_ID=$(jq -r '.matrix_room_id // ""' "$CONFIG_FILE")
    MATRIX_HOMESERVER=$(jq -r '.matrix_homeserver // ""' "$CONFIG_FILE")
    WEBHOOK_SECRET=$(jq -r '.webhook_secret // ""' "$CONFIG_FILE")
    CF_API_TOKEN=$(jq -r '.cloudflare_api_token // ""' "$CONFIG_FILE")
    CADDY_ENABLE=$(jq -r '.modules.caddy.enable // .caddy_enable // "false"' "$CONFIG_FILE")
    FORGEJO_PUBLIC_HOST=$(jq -r '.forgejo_public_host // ""' "$CONFIG_FILE")
    KEEPALIVED_ENABLE=$(jq -r '.modules.keepalived.enable // .keepalived_enable // "false"' "$CONFIG_FILE")
    KEEPALIVED_INTERFACE=$(jq -r '.modules.keepalived.interface // .keepalived_interface // ""' "$CONFIG_FILE")
    KEEPALIVED_ROUTER_ID=$(jq -r '.modules.keepalived.virtual_router_id // .keepalived_virtual_router_id // "51"' "$CONFIG_FILE")
    KEEPALIVED_PRIORITY=$(jq -r '.modules.keepalived.priority // .keepalived_priority // "150"' "$CONFIG_FILE")
    KEEPALIVED_VIP_CIDR=$(jq -r '.modules.keepalived.vip_cidr // .keepalived_vip_cidr // ""' "$CONFIG_FILE")
    CF_TUNNEL=$(jq -r '.modules.cloudflare.enable // .cloudflare_tunnel // "false"' "$CONFIG_FILE")
    CF_TUNNEL_NAME=$(jq -r '.modules.cloudflare.tunnel_name // .cloudflare_tunnel_name // ""' "$CONFIG_FILE")
    CF_TUNNEL_DOMAIN=$(jq -r '.modules.cloudflare.tunnel_domain // .cloudflare_tunnel_domain // ""' "$CONFIG_FILE")
    CF_TUNNEL_VIP=$(jq -r '.modules.cloudflare.tunnel_vip // .cloudflare_tunnel_vip // ""' "$CONFIG_FILE")
    CF_ZONE_ID=$(jq -r '.modules.cloudflare.zone_id // .cloudflare_zone_id // ""' "$CONFIG_FILE")
    CF_ACCOUNT_ID=$(jq -r '.modules.cloudflare.account_id // .cloudflare_account_id // ""' "$CONFIG_FILE")
    PXE_ENABLE=$(jq -r '.modules.pxe.enable // .pxe_enable // "false"' "$CONFIG_FILE")
    PXE_DHCP_ENABLE=$(jq -r '.modules.pxe.dhcp_enable // .pxe_dhcp_enable // "false"' "$CONFIG_FILE")
    PXE_INTERFACE=$(jq -r '.modules.pxe.interface // .pxe_interface // ""' "$CONFIG_FILE")
    PXE_HTTP_PORT=$(jq -r '.modules.pxe.http_port // .pxe_http_port // "8081"' "$CONFIG_FILE")
    PXE_BOOT_URL=$(jq -r '.modules.pxe.boot_url // .pxe_boot_url // ""' "$CONFIG_FILE")
    POSTGRES_BACKUP_ENABLE=$(jq -r '.modules.postgres_backup.enable // .postgres_backup_enable // "false"' "$CONFIG_FILE")
    IS_CONTROLLER=$(jq -r '.is_controller // "false"' "$CONFIG_FILE")

    CUSTOM_GROUP_CONFIG=$(jq -r '.custom_group_config // ""' "$CONFIG_FILE")
    CUSTOM_GROUP_IMPORTS=$(jq -r '.custom_group_imports // ""' "$CONFIG_FILE")
    CUSTOM_NODE_CONFIG=$(jq -r '.custom_node_config // ""' "$CONFIG_FILE")
    CUSTOM_NODE_IMPORTS=$(jq -r '.custom_node_imports // ""' "$CONFIG_FILE")

    if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ] || [ -z "$REPO_URL" ] || [ -z "$NODE_ADMIN" ] || [ -z "$NODE_ADMIN_PASS" ]; then
        echo "Error: Missing required fields in config file."
        exit 1
    fi
else
    read -p "Is this the FIRST node (Bootstrap Mode - will install local Forgejo)? (y/N): " BOOTSTRAP_PROMPT
    if [[ "$BOOTSTRAP_PROMPT" =~ ^[Yy]$ ]]; then
        IS_BOOTSTRAP="true"
    else
        IS_BOOTSTRAP="false"
    fi
    echo ""

    read -p "Enter Git Host Admin/Deploy Username: " GIT_USER
    read -s -p "Enter Git Access Token: " GIT_TOKEN
    echo ""
    read -p "Enter Fleet Repository URL (HTTPS): " REPO_URL
    read -p "Optional internal IP for the repo hostname (writes /etc/hosts on this node): " REPO_HOST_IP
    read -p "Optional nops repo URL for generated fleet flakes (blank to leave placeholder): " NOPS_REPO_URL
    read -p "Optional nixos-install repo URL for controller provisioning (blank to leave placeholder): " NIXOS_INSTALL_REPO_URL

    read -p "Enter the group/tier for this node (e.g., media, signaling, db) [default]: " NODE_GROUP
    NODE_GROUP=${NODE_GROUP:-default}

    read -p "SETUP ADMIN USERNAME (for this node): " NODE_ADMIN
    read -s -p "SETUP PASSWORD FOR $NODE_ADMIN: " NODE_ADMIN_PASS
    echo ""
    read -p "Optional: Enter SSH Public Key for $NODE_ADMIN (Leave blank to skip): " NODE_SSH_PUB_KEY
    echo ""
    read -p "Node role [controller/worker/service/backup] [worker]: " NODE_ROLE
    NODE_ROLE=${NODE_ROLE:-worker}
    if [ "$NODE_ROLE" = "controller" ]; then
        KEEPALIVED_ROLE="master"
    elif [ "$NODE_ROLE" = "backup" ]; then
        KEEPALIVED_ROLE="backup"
    else
        KEEPALIVED_ROLE="backup"
    fi
    read -p "Installer auth mode for live-USB/netboot deployments [auto/password/ssh_key] [auto]: " INSTALLER_AUTH_MODE
    INSTALLER_AUTH_MODE=${INSTALLER_AUTH_MODE:-auto}
    read -p "Installer SSH public key for live-USB/netboot access (optional): " INSTALLER_SSH_PUB_KEY
    echo ""
    read -s -p "Enter Shared Fleet Private Age Key (Leave blank to generate a new unique key): " FLEET_PRIVATE_KEY
    echo ""
    echo "Select Update Trigger Method:"
    echo "1) Matrix Pub/Sub"
    echo "2) Webhook (Forgejo/GitLab/GitHub) (Default)"
    read -p "Enter choice [1 or 2]: " TRIGGER_CHOICE
    if [ "$TRIGGER_CHOICE" != "1" ]; then
        TRIGGER_CHOICE="2"
    fi
    echo ""

    echo "Base Reverse Proxy:"
    read -p "Enable base Caddy reverse proxy? (y/N): " CADDY_ENABLE_PROMPT
    if [[ "$CADDY_ENABLE_PROMPT" =~ ^[Yy]$ ]]; then
        CADDY_ENABLE="true"
        if [ "$IS_BOOTSTRAP" = "true" ]; then
            read -p "Public Forgejo host for Caddy (e.g., git.example.com): " FORGEJO_PUBLIC_HOST
            read -p "Enable keepalived VIP for ingress on the first node? (y/N): " KEEPALIVED_ENABLE_PROMPT
            if [[ "$KEEPALIVED_ENABLE_PROMPT" =~ ^[Yy]$ ]]; then
                KEEPALIVED_ENABLE="true"
                read -p "Keepalived interface (blank to auto-detect): " KEEPALIVED_INTERFACE
                read -p "Keepalived virtual router id [51]: " KEEPALIVED_ROUTER_ID
                KEEPALIVED_ROUTER_ID=${KEEPALIVED_ROUTER_ID:-51}
                read -p "Keepalived priority [150]: " KEEPALIVED_PRIORITY
                KEEPALIVED_PRIORITY=${KEEPALIVED_PRIORITY:-150}
                read -p "Keepalived VIP CIDR (blank to derive from tunnel VIP and interface prefix): " KEEPALIVED_VIP_CIDR
                KEEPALIVED_ROLE="master"
            else
                KEEPALIVED_ENABLE="false"
                KEEPALIVED_ROLE="backup"
            fi
        fi
    else
        CADDY_ENABLE="false"
    fi

    echo ""
    echo "Cloudflare Tunnel Integration:"
    read -p "Enable Cloudflare Tunnel? (y/N): " CF_TUNNEL_PROMPT
    if [[ "$CF_TUNNEL_PROMPT" =~ ^[Yy]$ ]]; then
        CF_TUNNEL="true"
        read -p "Tunnel name (e.g., homelab-ha-ingress): " CF_TUNNEL_NAME
        read -p "Domain to route through tunnel (e.g., example.com): " CF_TUNNEL_DOMAIN
        read -p "Internal VIP or IP for tunnel traffic (e.g., 192.168.2.200): " CF_TUNNEL_VIP
    else
        CF_TUNNEL="false"
    fi

    echo ""
    echo "PXE/iPXE Bootstrap Stack:"
    read -p "Enable controller-hosted PXE assets? (y/N): " PXE_ENABLE_PROMPT
    if [[ "$PXE_ENABLE_PROMPT" =~ ^[Yy]$ ]]; then
        PXE_ENABLE="true"
        read -p "Enable dnsmasq DHCP/TFTP on the controller too? (y/N): " PXE_DHCP_ENABLE_PROMPT
        if [[ "$PXE_DHCP_ENABLE_PROMPT" =~ ^[Yy]$ ]]; then
            PXE_DHCP_ENABLE="true"
        else
            PXE_DHCP_ENABLE="false"
        fi
        read -p "PXE interface (leave blank to use the default controller uplink): " PXE_INTERFACE
        read -p "PXE HTTP port [8081]: " PXE_HTTP_PORT
        PXE_HTTP_PORT=${PXE_HTTP_PORT:-8081}
        read -p "iPXE boot target URL (what chainload should boot next): " PXE_BOOT_URL
    else
        PXE_ENABLE="false"
        PXE_DHCP_ENABLE="false"
    fi

    read -p "Enable PostgreSQL backups for Forgejo on this node? (y/N): " POSTGRES_BACKUP_PROMPT
    if [[ "$POSTGRES_BACKUP_PROMPT" =~ ^[Yy]$ ]]; then
        POSTGRES_BACKUP_ENABLE="true"
    else
        POSTGRES_BACKUP_ENABLE="false"
    fi

    if [ "$IS_BOOTSTRAP" = "true" ]; then
        NODE_ROLE="controller"
        KEEPALIVED_ROLE="master"
    fi

    echo ""
    echo "Custom configuration files (leave blank to use defaults):"
    read -p "Path to custom group configuration.nix: " CUSTOM_GROUP_CONFIG
    read -p "Path to custom group imports.nix: " CUSTOM_GROUP_IMPORTS
    read -p "Path to custom node configuration.nix: " CUSTOM_NODE_CONFIG
    read -p "Path to custom node imports.nix: " CUSTOM_NODE_IMPORTS
fi

if [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    IS_CONTROLLER="true"
    NODE_ROLE="controller"
    KEEPALIVED_ROLE="master"
    POSTGRES_BACKUP_ENABLE="true"
fi

if [ "${NODE_ROLE:-worker}" = "controller" ]; then
    IS_CONTROLLER="true"
fi

if [ "${IS_CONTROLLER:-false}" = "true" ] && { [ -z "${NOPS_REPO_URL:-}" ] || [ -z "${NIXOS_INSTALL_REPO_URL:-}" ]; }; then
    echo "Error: nops_repo_url and nixos_install_repo_url must be set for controller/bootstrap installs."
    exit 1
fi

if [ "$CLEAN" = true ] && [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    log "Bootstrap clean requested. Wiping local Forgejo and tunnel runtime state..."
    sudo systemctl stop nops 2>/dev/null || true
    sudo systemctl stop cloudflared 2>/dev/null || true
    sudo systemctl stop forgejo 2>/dev/null || true
    sudo systemctl stop docker 2>/dev/null || true
    sudo docker rm -f cloudflared-tunnel 2>/dev/null || true
    sudo rm -rf /var/lib/forgejo
    log "Bootstrap-specific clean complete."
fi

if [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    prepare_forgejo_state
fi

REPO_NAME=$(basename "$REPO_URL" .git)
REPO_HOST=$(extract_repo_host "$REPO_URL")

if [ -z "${REPO_HOST_IP:-}" ] && [ "${IS_BOOTSTRAP:-false}" = "true" ] && [ -n "${FORGEJO_PUBLIC_HOST:-}" ] && [ -n "${CF_TUNNEL_VIP:-}" ] && [ "${REPO_HOST:-}" = "${FORGEJO_PUBLIC_HOST}" ]; then
    REPO_HOST_IP="$CF_TUNNEL_VIP"
    log "repo_host_ip not set. Defaulting ${REPO_HOST} to ${REPO_HOST_IP} because repo_url matches forgejo_public_host during bootstrap."
fi

if [ -n "${REPO_HOST_IP:-}" ] && [ -n "${REPO_HOST:-}" ]; then
    log "Pinning ${REPO_HOST} to ${REPO_HOST_IP} in /etc/hosts for this install..."
    set_hosts_entry "$REPO_HOST" "$REPO_HOST_IP"
elif [ -n "${REPO_HOST:-}" ]; then
    warn_if_repo_host_resolves_publicly "$REPO_HOST"
fi

if [ "${KEEPALIVED_ENABLE:-false}" = "true" ]; then
    require_integer_in_range "keepalived_virtual_router_id" "$KEEPALIVED_ROUTER_ID" 1 255
    require_integer_in_range "keepalived_priority" "$KEEPALIVED_PRIORITY" 1 255
fi

if [ "${IS_BOOTSTRAP:-false}" = "true" ] && echo "$REPO_URL" | grep -Eq '^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?/'; then
    warn "repo_url points at localhost. Bootstrap can hand off through the local Forgejo instance, but worker nodes and future pulls should use the final shared Git URL instead."
    if [ -n "${FORGEJO_PUBLIC_HOST:-}" ]; then
        warn "With forgejo_public_host set, repo_url should usually be the shared Git host, for example: https://${FORGEJO_PUBLIC_HOST}/${GIT_USER}/${REPO_NAME}.git"
    fi
fi
TARGET_DIR="/home/nops/$REPO_NAME"

# Installs a shared fleet age key if provided, or generates a unique node key if none exists at /var/lib/sops-nix/key.txt.
KEY_FILE="/var/lib/sops-nix/key.txt"
sudo mkdir -p "$(dirname "$KEY_FILE")"

if [ -n "$FLEET_PRIVATE_KEY" ]; then
    log "FLEET_PRIVATE_KEY environment variable detected. Using shared fleet key..."
    echo "$FLEET_PRIVATE_KEY" | sudo tee "$KEY_FILE" > /dev/null
    sudo chmod 600 "$KEY_FILE"
    sudo chown root:root "$KEY_FILE"
elif [ ! -f "$KEY_FILE" ]; then
    log "No shared key provided. Generating new Age key..."
    sudo age-keygen -o "$KEY_FILE"
    sudo chmod 600 "$KEY_FILE"
    sudo chown root:root "$KEY_FILE"
    warn "A unique key was generated. Manual SOPS authorization will be required on another node."
fi

PUB_KEY=$(sudo age-keygen -y "$KEY_FILE")
log "Active Public Key: $PUB_KEY"

# Clones the fleet repository with URL-encoded credentials into /home/nops/<repo-name>. Marks the directory safe for root rebuilds.
if [ -d "$TARGET_DIR" ]; then
    log "Cleaning existing fleet directory..."
    sudo rm -rf "$TARGET_DIR"
fi

if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Bootstrap Mode: Initializing local fleet repository..."
    sudo -u nops mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR"
    sudo -u nops git init
    sudo -u nops git checkout -b main
    ENCODED_TOKEN=$(jq -nr --arg v "$GIT_TOKEN" '$v | @uri')
    CLEAN_REPO_URL=$(echo "$REPO_URL" | sed 's|^https\?://||')
    sudo -u nops git remote add origin "http://$GIT_USER:$ENCODED_TOKEN@$CLEAN_REPO_URL"
else
    log "Worker Mode: Cloning Fleet Repository into $TARGET_DIR..."
    ENCODED_TOKEN=$(jq -nr --arg v "$GIT_TOKEN" '$v | @uri')
    CLEAN_REPO_URL=$(echo "$REPO_URL" | sed 's|^https\?://||')
    sudo env GIT_CONFIG_NOSYSTEM=1 git clone "https://$GIT_USER:$ENCODED_TOKEN@$CLEAN_REPO_URL" "$TARGET_DIR"
    sudo chown -R nops:nops "$TARGET_DIR"
    cd "$TARGET_DIR"
fi

sudo git config --global --add safe.directory "$TARGET_DIR"
sudo -u nops git config --global --add safe.directory "$TARGET_DIR"

# Ensures the standard fleet directory structure exists and bootstraps a base flake.nix if the repo is empty.
log "Ensuring fleet root directory structure..."
sudo -u nops mkdir -p modules secrets scripts groups nodes
sudo -u nops touch modules/.keep secrets/.keep scripts/.keep groups/.keep nodes/.keep

normalize_git_flake_url() {
    local url="$1"

    if [[ "$url" =~ ^git\+ ]]; then
        printf '%s\n' "$url"
        return 0
    fi

    if [[ "$url" =~ ^https?:// ]]; then
        printf 'git+%s\n' "$url"
        return 0
    fi

    printf '%s\n' "$url"
}

if [ ! -f "flake.nix" ]; then
    log "Empty fleet repository detected. Initializing base flake..."
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/flake.nix" "$TARGET_DIR/flake.nix"
    sudo -u nops chmod u+w "$TARGET_DIR/flake.nix"
    if [ -n "${NOPS_REPO_URL:-}" ]; then
        NOPS_FLAKE_URL="$(normalize_git_flake_url "$NOPS_REPO_URL")"
        sudo -u nops sed -i "s|NOPS_FLAKE_URL_PLACEHOLDER|${NOPS_FLAKE_URL}|" "$TARGET_DIR/flake.nix"
    fi
fi

if [ ! -f "$TARGET_DIR/deployments.json" ]; then
    log "Initializing deployments.json template..."
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/deployments.json" "$TARGET_DIR/deployments.json"
    sudo -u nops chmod u+w "$TARGET_DIR/deployments.json"
fi

if [ ! -f "$TARGET_DIR/nops-config-template.json" ]; then
    log "Initializing nops-config-template.json template..."
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/nops-config-template.json" "$TARGET_DIR/nops-config-template.json"
    sudo -u nops chmod u+w "$TARGET_DIR/nops-config-template.json"
fi

if [ "${IS_CONTROLLER:-false}" = "true" ]; then
    log "Hydrating repository-level install templates..."
    NOPS_CONFIG_TEMPLATE_SRC=$(mktemp)
    NOPS_CONFIG_TEMPLATE_TMP=$(mktemp)
    prepare_json_for_edit "$TARGET_DIR/nops-config-template.json" "$NOPS_CONFIG_TEMPLATE_SRC"
    jq \
        --arg git_user "$GIT_USER" \
        --arg git_token "$GIT_TOKEN" \
        --arg repo_url "$REPO_URL" \
        --arg repo_host_ip "$REPO_HOST_IP" \
        --arg node_group "$NODE_GROUP" \
        --arg node_admin "$NODE_ADMIN" \
        --arg node_ssh_pub_key "$CONTROLLER_NODE_SSH_PUB_KEY" \
        --arg node_role "${NODE_ROLE:-worker}" \
        --arg keepalived_role "${KEEPALIVED_ROLE:-backup}" \
        --arg installer_auth_mode "${INSTALLER_AUTH_MODE:-auto}" \
        --arg installer_ssh_pub_key "${INSTALLER_SSH_PUB_KEY:-}" \
        --arg trigger_choice "$TRIGGER_CHOICE" \
        --arg webhook_secret "$WEBHOOK_SECRET" \
        --arg cloudflare_api_token "$CF_API_TOKEN" \
        --arg forgejo_public_host "$FORGEJO_PUBLIC_HOST" \
        --arg keepalived_interface "$KEEPALIVED_INTERFACE" \
        --arg keepalived_vip_cidr "$KEEPALIVED_VIP_CIDR" \
        --arg cloudflare_tunnel_name "$CF_TUNNEL_NAME" \
        --arg cloudflare_tunnel_domain "$CF_TUNNEL_DOMAIN" \
        --arg cloudflare_tunnel_vip "$CF_TUNNEL_VIP" \
        --arg cloudflare_zone_id "$CF_ZONE_ID" \
        --arg cloudflare_account_id "$CF_ACCOUNT_ID" \
        --arg pxe_enable "${PXE_ENABLE:-false}" \
        --arg pxe_dhcp_enable "${PXE_DHCP_ENABLE:-false}" \
        --arg pxe_interface "${PXE_INTERFACE:-}" \
        --arg pxe_http_port "${PXE_HTTP_PORT:-8081}" \
        --arg pxe_boot_url "${PXE_BOOT_URL:-}" \
        --argjson postgres_backup_enable "${POSTGRES_BACKUP_ENABLE:-false}" \
        --argjson caddy_enable "${CADDY_ENABLE:-false}" \
        --argjson keepalived_enable "${KEEPALIVED_ENABLE:-false}" \
        --argjson keepalived_virtual_router_id "$KEEPALIVED_ROUTER_ID" \
        --argjson keepalived_priority "$KEEPALIVED_PRIORITY" \
        --argjson cloudflare_tunnel "${CF_TUNNEL:-false}" \
        '.git_user = $git_user |
         .git_token = $git_token |
         .repo_url = $repo_url |
         .repo_host_ip = $repo_host_ip |
         .node_group = $node_group |
         .node_admin = $node_admin |
         .node_ssh_pub_key = $node_ssh_pub_key |
         .node_role = $node_role |
         .keepalived_role = $keepalived_role |
         .installer_auth_mode = $installer_auth_mode |
         .installer_ssh_pub_key = $installer_ssh_pub_key |
         .trigger_choice = $trigger_choice |
         .webhook_secret = $webhook_secret |
         .cloudflare_api_token = $cloudflare_api_token |
         .caddy_enable = $caddy_enable |
         .forgejo_public_host = $forgejo_public_host |
         .keepalived_enable = $keepalived_enable |
         .keepalived_interface = $keepalived_interface |
         .keepalived_virtual_router_id = $keepalived_virtual_router_id |
         .keepalived_priority = $keepalived_priority |
         .keepalived_vip_cidr = $keepalived_vip_cidr |
         .cloudflare_tunnel = $cloudflare_tunnel |
         .cloudflare_tunnel_name = $cloudflare_tunnel_name |
         .cloudflare_tunnel_domain = $cloudflare_tunnel_domain |
         .cloudflare_tunnel_vip = $cloudflare_tunnel_vip |
         .cloudflare_zone_id = $cloudflare_zone_id |
         .cloudflare_account_id = $cloudflare_account_id |
         .pxe_enable = ($pxe_enable == "true") |
         .pxe_dhcp_enable = ($pxe_dhcp_enable == "true") |
         .pxe_interface = $pxe_interface |
         .pxe_http_port = ($pxe_http_port | tonumber) |
         .pxe_boot_url = $pxe_boot_url |
         .postgres_backup_enable = $postgres_backup_enable' \
        "$NOPS_CONFIG_TEMPLATE_SRC" > "$NOPS_CONFIG_TEMPLATE_TMP"
    rm -f "$NOPS_CONFIG_TEMPLATE_SRC"
    sudo mv "$NOPS_CONFIG_TEMPLATE_TMP" "$TARGET_DIR/nops-config-template.json"
    sudo chown nops:nops "$TARGET_DIR/nops-config-template.json"
    sudo chmod 0644 "$TARGET_DIR/nops-config-template.json"

        log "Ensuring deployments.json contains the controller inventory entry..."
        CONTROLLER_DEPLOYMENTS_SRC=$(mktemp)
        CONTROLLER_DEPLOYMENTS_TMP=$(mktemp)
        CONTROLLER_PRIMARY_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
        if [ -z "$CONTROLLER_PRIMARY_IP" ]; then
            CONTROLLER_PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
        fi
        CONTROLLER_ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
        prepare_json_for_edit "$TARGET_DIR/deployments.json" "$CONTROLLER_DEPLOYMENTS_SRC"

        jq \
                --arg hostname "$HOSTNAME" \
                --arg installer_ip "$CONTROLLER_PRIMARY_IP" \
                --arg node_group "$NODE_GROUP" \
                --arg node_admin "$NODE_ADMIN" \
                --arg node_admin_pass "$NODE_ADMIN_PASS" \
                --arg fs "$CONTROLLER_ROOT_FS" \
                --arg installer_auth_mode "${INSTALLER_AUTH_MODE:-auto}" \
                --arg installer_ssh_pub_key "${INSTALLER_SSH_PUB_KEY:-}" \
                --arg node_role "${NODE_ROLE:-controller}" \
                --arg keepalived_role "${KEEPALIVED_ROLE:-master}" \
                'if any(.[]; .hostname == $hostname) then
                     .
                 else
                     . + [{
                         hostname: $hostname,
                         installer_ip: $installer_ip,
                         installer_user: "nixos",
                         installer_auth_mode: $installer_auth_mode,
                         installer_ssh_pub_key: $installer_ssh_pub_key,
                         installer_password: "",
                         disk: "",
                         fs: $fs,
                         node_group: $node_group,
                         node_role: $node_role,
                         keepalived_role: $keepalived_role,
                         node_admin: $node_admin,
                         node_admin_pass: $node_admin_pass
                     }]
                 end' \
                "$CONTROLLER_DEPLOYMENTS_SRC" > "$CONTROLLER_DEPLOYMENTS_TMP"

        rm -f "$CONTROLLER_DEPLOYMENTS_SRC"
        sudo mv "$CONTROLLER_DEPLOYMENTS_TMP" "$TARGET_DIR/deployments.json"
        sudo chown nops:nops "$TARGET_DIR/deployments.json"
        sudo chmod 0644 "$TARGET_DIR/deployments.json"
    else
        log "Preserving controller-owned install templates from the existing repo."
fi

# Creates the group and node config directories from templates if they don't already exist.
# Validates that a custom config file path exists; exits with an error if the file is missing.
validate_custom_file() {
    local filepath="$1"
    local label="$2"
    if [ -n "$filepath" ] && [ ! -f "$filepath" ]; then
        echo "Error: Custom $label file not found: $filepath"
        exit 1
    fi
}

validate_custom_file "$CUSTOM_GROUP_CONFIG" "group configuration.nix"
validate_custom_file "$CUSTOM_GROUP_IMPORTS" "group imports.nix"
validate_custom_file "$CUSTOM_NODE_CONFIG" "node configuration.nix"
validate_custom_file "$CUSTOM_NODE_IMPORTS" "node imports.nix"

GROUP_DIR="$TARGET_DIR/groups/$NODE_GROUP"
if [ ! -d "$GROUP_DIR" ]; then
    log "Group '$NODE_GROUP' not found. Initializing group templates..."
    sudo -u nops mkdir -p "$GROUP_DIR"

    if [ -n "$CUSTOM_GROUP_CONFIG" ]; then
        log "Using custom group configuration.nix from $CUSTOM_GROUP_CONFIG"
        sudo -u nops cp --no-preserve=mode "$CUSTOM_GROUP_CONFIG" "$GROUP_DIR/configuration.nix"
    else
        echo "{ config, pkgs, ... }: {
  # Group-level NixOS options for the $NODE_GROUP tier.
}" | sudo -u nops tee "$GROUP_DIR/configuration.nix" > /dev/null
    fi

    if [ -n "$CUSTOM_GROUP_IMPORTS" ]; then
        log "Using custom group imports.nix from $CUSTOM_GROUP_IMPORTS"
        sudo -u nops cp --no-preserve=mode "$CUSTOM_GROUP_IMPORTS" "$GROUP_DIR/imports.nix"
    else
        sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/imports.nix" "$GROUP_DIR/imports.nix"
    fi
    sudo -u nops chmod -R u+w "$GROUP_DIR"
fi

# Scaffolds a base Caddy module when enabled so generated fleets have a shared reverse proxy layer.
if [ "${CADDY_ENABLE:-false}" = "true" ]; then
    log "Base Caddy reverse proxy enabled. Scaffolding module..."

    CADDY_MODULE_DIR="$TARGET_DIR/modules/caddy"
    if [ ! -d "$CADDY_MODULE_DIR" ]; then
        sudo -u nops mkdir -p "$CADDY_MODULE_DIR"
        sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/caddy.nix" "$CADDY_MODULE_DIR/caddy.nix"
        sudo -u nops chmod u+w "$CADDY_MODULE_DIR/caddy.nix"
        log "Created modules/caddy/caddy.nix"
    fi

    GROUP_IMPORTS="$TARGET_DIR/groups/$NODE_GROUP/imports.nix"
    if [ -f "$GROUP_IMPORTS" ] && ! grep -q "caddy.nix" "$GROUP_IMPORTS"; then
        sudo -u nops sed -i 's|CADDY_MODULE_PLACEHOLDER|../../modules/caddy/caddy.nix|' "$GROUP_IMPORTS"
        sudo -u nops sed -i '/# Add module paths here/a\    ../../modules/caddy/caddy.nix' "$GROUP_IMPORTS"
        log "Added caddy module to group imports"
    fi
fi

# Scaffolds a keepalived VIP module for any node that participates in HA.
if [ "${KEEPALIVED_ENABLE:-false}" = "true" ]; then
    log "Keepalived VIP enabled. Scaffolding module..."

    if [ -z "${KEEPALIVED_INTERFACE:-}" ]; then
        KEEPALIVED_INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ { print $5; exit }')
    fi

    if [ -z "${KEEPALIVED_VIP_CIDR:-}" ]; then
        INTERFACE_PREFIX=$(ip -o -f inet addr show dev "$KEEPALIVED_INTERFACE" 2>/dev/null | awk '{ print $4; exit }' | cut -d/ -f2)
        if [ -n "$INTERFACE_PREFIX" ] && [ -n "${CF_TUNNEL_VIP:-}" ]; then
            KEEPALIVED_VIP_CIDR="${CF_TUNNEL_VIP}/${INTERFACE_PREFIX}"
        fi
    fi

    if [ -z "${KEEPALIVED_INTERFACE:-}" ] || [ -z "${KEEPALIVED_VIP_CIDR:-}" ]; then
        echo "Error: keepalived bootstrap requires a network interface and VIP CIDR."
        exit 1
    fi

    KEEPALIVED_MODULE_DIR="$TARGET_DIR/modules/ingress"
    if [ ! -d "$KEEPALIVED_MODULE_DIR" ]; then
        sudo -u nops mkdir -p "$KEEPALIVED_MODULE_DIR"
    fi
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/keepalived.nix" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    sudo -u nops chmod u+w "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    sudo -u nops sed -i "s|KEEPALIVED_INTERFACE_PLACEHOLDER|${KEEPALIVED_INTERFACE}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    if [ "${KEEPALIVED_ROLE:-backup}" = "master" ] || [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
        KEEPALIVED_STATE="MASTER"
    else
        KEEPALIVED_STATE="BACKUP"
    fi
    sudo -u nops sed -i "s|KEEPALIVED_STATE_PLACEHOLDER|${KEEPALIVED_STATE}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    sudo -u nops sed -i "s|KEEPALIVED_ROUTER_ID_PLACEHOLDER|${KEEPALIVED_ROUTER_ID}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    sudo -u nops sed -i "s|KEEPALIVED_PRIORITY_PLACEHOLDER|${KEEPALIVED_PRIORITY}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    sudo -u nops sed -i "s|KEEPALIVED_VIP_CIDR_PLACEHOLDER|${KEEPALIVED_VIP_CIDR}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
    log "Created modules/ingress/keepalived.nix (interface: $KEEPALIVED_INTERFACE, vip: $KEEPALIVED_VIP_CIDR)"

    GROUP_IMPORTS="$TARGET_DIR/groups/$NODE_GROUP/imports.nix"
    if [ -f "$GROUP_IMPORTS" ] && ! grep -q "keepalived.nix" "$GROUP_IMPORTS"; then
        sudo -u nops sed -i 's|KEEPALIVED_MODULE_PLACEHOLDER|../../modules/ingress/keepalived.nix|' "$GROUP_IMPORTS"
        sudo -u nops sed -i '/# Add module paths here/a\    ../../modules/ingress/keepalived.nix' "$GROUP_IMPORTS"
        log "Added keepalived module to group imports"
    fi
fi

# Scaffolds a PostgreSQL backup module for the controller bootstrap node.
if [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    log "PostgreSQL backup support enabled. Scaffolding module..."

    POSTGRES_BACKUP_MODULE_DIR="$TARGET_DIR/modules/backup"
    if [ ! -d "$POSTGRES_BACKUP_MODULE_DIR" ]; then
        sudo -u nops mkdir -p "$POSTGRES_BACKUP_MODULE_DIR"
    fi
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/postgres-backup.nix" "$POSTGRES_BACKUP_MODULE_DIR/postgres.nix"
    sudo -u nops chmod u+w "$POSTGRES_BACKUP_MODULE_DIR/postgres.nix"

fi

# Scaffolds Cloudflare tunnel module and Terraform config when the tunnel option is enabled.
if [ "${CF_TUNNEL:-false}" = "true" ]; then
    log "Cloudflare Tunnel enabled. Scaffolding modules..."

    # Create cloudflared NixOS module
    CF_MODULE_DIR="$TARGET_DIR/modules/cloudflare"
    if [ ! -d "$CF_MODULE_DIR" ]; then
        sudo -u nops mkdir -p "$CF_MODULE_DIR"
        sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/cloudflared.nix" "$CF_MODULE_DIR/cloudflared.nix"
        sudo -u nops chmod u+w "$CF_MODULE_DIR/cloudflared.nix"
        log "Created modules/cloudflare/cloudflared.nix"
    fi

    # Create Terraform config with substituted values
    TF_MODULE_DIR="$TARGET_DIR/modules/terraform"
    if [ ! -d "$TF_MODULE_DIR" ]; then
        sudo -u nops mkdir -p "$TF_MODULE_DIR"
        sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/main.tf" "$TF_MODULE_DIR/main.tf"
        sudo -u nops chmod u+w "$TF_MODULE_DIR/main.tf"
        sudo -u nops sed -i "s|TUNNEL_NAME_PLACEHOLDER|${CF_TUNNEL_NAME}|" "$TF_MODULE_DIR/main.tf"
        sudo -u nops sed -i "s|TUNNEL_DOMAIN_PLACEHOLDER|${CF_TUNNEL_DOMAIN}|" "$TF_MODULE_DIR/main.tf"
        sudo -u nops sed -i "s|VIP_ADDRESS_PLACEHOLDER|${CF_TUNNEL_VIP}|" "$TF_MODULE_DIR/main.tf"
        log "Created modules/terraform/main.tf (tunnel: $CF_TUNNEL_NAME, domain: $CF_TUNNEL_DOMAIN, vip: $CF_TUNNEL_VIP)"
    fi

    # Add cloudflared import to group imports.nix if not already present
    GROUP_IMPORTS="$TARGET_DIR/groups/$NODE_GROUP/imports.nix"
    if [ -f "$GROUP_IMPORTS" ] && ! grep -q "cloudflared.nix" "$GROUP_IMPORTS"; then
        sudo -u nops sed -i 's|CLOUDFLARED_MODULE_PLACEHOLDER|../../modules/cloudflare/cloudflared.nix|' "$GROUP_IMPORTS"
        sudo -u nops sed -i '/# Add module paths here/a\    ../../modules/cloudflare/cloudflared.nix' "$GROUP_IMPORTS"
        log "Added cloudflared module to group imports"
    fi
fi

# Clean up any unused placeholders in the group imports file
if [ -f "$TARGET_DIR/groups/$NODE_GROUP/imports.nix" ]; then
    sudo -u nops sed -i '/_MODULE_PLACEHOLDER/d' "$TARGET_DIR/groups/$NODE_GROUP/imports.nix"
fi

NODE_DIR="$TARGET_DIR/nodes/$HOSTNAME"
log "Creating node directory at $NODE_DIR linked to group '$NODE_GROUP'..."
sudo -u nops mkdir -p "$NODE_DIR"

if [ -n "$CUSTOM_NODE_CONFIG" ]; then
    log "Using custom node configuration.nix from $CUSTOM_NODE_CONFIG"
    sudo -u nops cp --no-preserve=mode "$CUSTOM_NODE_CONFIG" "$NODE_DIR/configuration.nix"
else
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/configuration.nix" "$NODE_DIR/configuration.nix"
fi

sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/controllerScript-autoprovision.sh" "$NODE_DIR/controllerScript-autoprovision.sh"
sudo -u nops chmod u+w "$NODE_DIR/controllerScript-autoprovision.sh"
    if [ -n "${NIXOS_INSTALL_REPO_URL:-}" ]; then
        sudo -u nops sed -i "s|NIXOS_INSTALL_REPO_URL_PLACEHOLDER|${NIXOS_INSTALL_REPO_URL}|" "$NODE_DIR/controllerScript-autoprovision.sh"
    fi
    if [ -n "${NOPS_REPO_URL:-}" ]; then
        sudo -u nops sed -i "s|NOPS_INSTALL_REPO_URL_PLACEHOLDER|${NOPS_REPO_URL}|" "$NODE_DIR/controllerScript-autoprovision.sh"
    fi


# Generate the node's imports.nix with conditional module imports
IMPORTS_FILE="$NODE_DIR/imports.nix"
echo "{ config, pkgs, ... }: { imports = [" > "$IMPORTS_FILE"
echo "  ../../groups/$NODE_GROUP/configuration.nix" >> "$IMPORTS_FILE"
echo "  ../../groups/$NODE_GROUP/imports.nix" >> "$IMPORTS_FILE"
if [ "${CADDY_ENABLE:-false}" = "true" ]; then
    echo "  ../../modules/caddy/caddy.nix" >> "$IMPORTS_FILE"
fi
if [ "${CF_TUNNEL:-false}" = "true" ]; then
    echo "  ../../modules/cloudflare/cloudflared.nix" >> "$IMPORTS_FILE"
fi
if [ "${KEEPALIVED_ENABLE:-false}" = "true" ]; then
    echo "  ../../modules/ingress/keepalived.nix" >> "$IMPORTS_FILE"
fi
if [ "${PXE_ENABLE:-false}" = "true" ] && [ "${IS_CONTROLLER:-false}" = "true" ]; then
    echo "  ../../modules/pxe/pxe.nix" >> "$IMPORTS_FILE"
fi
if [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    echo "  ../../modules/backup/postgres.nix" >> "$IMPORTS_FILE"
fi
if [ "$IS_BOOTSTRAP" = "true" ]; then
    echo "  ../../modules/forgejo/forgejo.nix" >> "$IMPORTS_FILE"
fi
echo "];}" >> "$IMPORTS_FILE"
sudo chown nops:nops "$IMPORTS_FILE"
sudo chmod u+w "$IMPORTS_FILE"

if [ -f "/etc/nixos/hardware-configuration.nix" ]; then
    sudo cp /etc/nixos/hardware-configuration.nix "$NODE_DIR/hardware-configuration.nix"
    sudo chown nops:nops "$NODE_DIR/hardware-configuration.nix"
elif command -v nixos-generate-config >/dev/null 2>&1; then
    log "Generating hardware-configuration.nix from the current system..."
    sudo nixos-generate-config --show-hardware-config > "$NODE_DIR/hardware-configuration.nix"
    sudo chown nops:nops "$NODE_DIR/hardware-configuration.nix"
fi

# Substitutes installer-collected values into the node config: hostname, admin user, repo path, and trigger mode.
log "Hydrating node configuration..."
HOST_ID=$(head -c 4 /dev/urandom | od -A n -t x4 | tr -d ' ' | cut -c 1-8)
sudo -u nops sed -i "s|HOST_ID_PLACEHOLDER|$HOST_ID|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|networking.hostName = \".*\";|networking.hostName = \"$HOSTNAME\";|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|users.users.tdavis|users.users.$NODE_ADMIN|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|initialPassword = \".*\";|initialPassword = \"$NODE_ADMIN_PASS\";|" "$NODE_DIR/configuration.nix"
sudo -u nops sed -i "s|repoPath = \".*\";|repoPath = \"$TARGET_DIR\";|" "$NODE_DIR/configuration.nix"

if [ -n "$NODE_SSH_PUB_KEY" ]; then
    # Safely escape slashes in the key string just in case
    SAFE_SSH_KEY=$(echo "$NODE_SSH_PUB_KEY" | sed 's|/|\\/|g')
    sudo -u nops sed -i "s|SSH_PUB_KEY_PLACEHOLDER|openssh.authorizedKeys.keys = [ \"$SAFE_SSH_KEY\" ];|" "$NODE_DIR/configuration.nix"
else
    sudo -u nops sed -i "/SSH_PUB_KEY_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
fi

if [ "$TRIGGER_CHOICE" == "2" ]; then
    sudo -u nops sed -i "s|MATRIX_ENABLE_PLACEHOLDER|false|" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|WEBHOOK_ENABLE_PLACEHOLDER|true|" "$NODE_DIR/configuration.nix"
else
    sudo -u nops sed -i "s|MATRIX_ENABLE_PLACEHOLDER|true|" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|WEBHOOK_ENABLE_PLACEHOLDER|false|" "$NODE_DIR/configuration.nix"
fi

sudo -u nops sed -i "s|IS_CONTROLLER_PLACEHOLDER|${IS_CONTROLLER:-false}|" "$NODE_DIR/configuration.nix"

# Dynamically scaffold Forgejo module if this is the bootstrap node
if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Scaffolding Forgejo module..."
    FORGEJO_MODULE_DIR="$TARGET_DIR/modules/forgejo"
    sudo -u nops mkdir -p "$FORGEJO_MODULE_DIR"
    FORGEJO_FILE="$FORGEJO_MODULE_DIR/forgejo.nix"
    
    cat > /tmp/forgejo.nix <<EOF
{ config, pkgs, lib, ... }:
{
  services.forgejo = {
      enable = true;
      database.type = "postgres";
      database.createDatabase = true;
      settings.server = {
          HTTP_PORT = 3000;
          DOMAIN = "${FORGEJO_PUBLIC_HOST:-localhost}";
          ROOT_URL = "https://${FORGEJO_PUBLIC_HOST:-localhost}/";
      };
  };
EOF
    cat >> /tmp/forgejo.nix <<'EOF'

  systemd.tmpfiles.rules = [
      "d /var/lib/forgejo/custom/conf 0750 forgejo forgejo -"
      "Z /var/lib/forgejo - forgejo forgejo -"
  ];

  systemd.services.forgejo.preStart = lib.mkAfter ''
      if [ -f /var/lib/forgejo/custom/conf/app.ini ]; then
          chmod 0640 /var/lib/forgejo/custom/conf/app.ini
      fi
  '';
EOF
    if [ "${CADDY_ENABLE:-false}" = "true" ] && [ -n "${FORGEJO_PUBLIC_HOST:-}" ]; then
            cat >> /tmp/forgejo.nix <<EOF

  services.caddy.virtualHosts."http://${FORGEJO_PUBLIC_HOST}:80" = {
      extraConfig = ''
          bind 0.0.0.0
          reverse_proxy 127.0.0.1:3000
      '';
  };
EOF
    fi
    echo "}" >> /tmp/forgejo.nix
    sudo cp /tmp/forgejo.nix "$FORGEJO_FILE"
    sudo chown nops:nops "$FORGEJO_FILE"
    sudo chmod 0644 "$FORGEJO_FILE"
    rm -f /tmp/forgejo.nix
    
    sudo -u nops sed -i "/FORGEJO_CONFIG_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|FIREWALL_FORGEJO_PLACEHOLDER|3000|" "$NODE_DIR/configuration.nix"
    # Prepend forgejo into the existing package array so there's no duplicate systemPackages block.
    sudo -u nops sed -i "s|CONTROLLER_PACKAGES_PLACEHOLDER|forgejo CONTROLLER_PACKAGES_PLACEHOLDER|" "$NODE_DIR/configuration.nix"
else
    # Delete the Forgejo placeholder line entirely so Nix doesn't crash
    sudo -u nops sed -i "/FORGEJO_CONFIG_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
    # Cleanly strip the firewall placeholder (including the leading space)
    sudo -u nops sed -i "s| FIREWALL_FORGEJO_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
    # Fallback strip just in case
    sudo -u nops sed -i "s|FIREWALL_FORGEJO_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
fi

# Inject allowUnfree and Terraform on controller nodes; cleanly remove placeholders on agents.
if [ "${IS_CONTROLLER:-false}" = "true" ]; then
    sudo -u nops sed -i "s|ALLOW_UNFREE_PLACEHOLDER|nixpkgs.config.allowUnfree = true;|" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|CONTROLLER_PACKAGES_PLACEHOLDER|terraform|" "$NODE_DIR/configuration.nix"
else
    sudo -u nops sed -i "/ALLOW_UNFREE_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s| CONTROLLER_PACKAGES_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
    sudo -u nops sed -i "s|CONTROLLER_PACKAGES_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
fi

# Inject Cloudflare tunnel Terraform provisioning into the controller script when enabled.
if [ "${CF_TUNNEL:-false}" = "true" ] && [ "${IS_CONTROLLER:-false}" = "true" ]; then
    log "Injecting Cloudflare tunnel provisioning into controller script..."
    CF_SCRIPT=$(cat <<'CFEOF'
      if [ -d "modules/terraform" ]; then
          echo "[NOPS] === Cloudflare Tunnel Provisioning ==="
          export TF_VAR_cloudflare_api_token=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_api_token"]' secrets/secrets.yaml)
          export TF_VAR_tunnel_name=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_name"]' secrets/secrets.yaml)
          export TF_VAR_tunnel_domain=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_domain"]' secrets/secrets.yaml)
          export TF_VAR_cloudflare_account_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_account_id"]' secrets/secrets.yaml)
          export TF_VAR_cloudflare_zone_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_zone_id"]' secrets/secrets.yaml)
          echo "[NOPS] Tunnel name: $TF_VAR_tunnel_name"
          echo "[NOPS] Tunnel domain: $TF_VAR_tunnel_domain"
          cd modules/terraform
          echo "[NOPS] Running terraform init..."
          terraform init -input=false
          echo "[NOPS] Running terraform plan..."
          terraform plan -input=false -out=tfplan 2>&1 | tee /tmp/tf-plan.log
          PLAN_EXIT=$?
          if [ $PLAN_EXIT -ne 0 ]; then
              echo "[NOPS] ERROR: terraform plan failed (exit $PLAN_EXIT)."
              cd ../..
          else
              echo "[NOPS] Running terraform apply..."
              terraform apply -input=false tfplan 2>&1 | tee /tmp/tf-apply.log
              APPLY_EXIT=$?
              rm -f tfplan
              if [ $APPLY_EXIT -ne 0 ]; then
                  echo "[NOPS] ERROR: terraform apply failed (exit $APPLY_EXIT)."
                  cd ../..
              else
                  echo "[NOPS] Terraform apply succeeded."
                  echo "[NOPS] Tunnel ID: $(terraform output -raw tunnel_id 2>/dev/null || echo 'N/A')"
                  echo "[NOPS] Tunnel Name: $(terraform output -raw tunnel_name 2>/dev/null || echo 'N/A')"
                  TOKEN=$(terraform output -raw tunnel_token)
                  cd ../..
                  if [ -n "$TOKEN" ] && [[ "$TOKEN" != *"No outputs found" ]] && ! sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d secrets/secrets.yaml | grep -q "$TOKEN"; then
                      echo "[NOPS] Tunnel token changed — updating SOPS..."
                      JSON_TOKEN=$(jq -Rn --arg value "$TOKEN" '$value')
                      sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set "[\"cloudflare_tunnel_token\"] $JSON_TOKEN" secrets/secrets.yaml
                      git add secrets/secrets.yaml
                      git commit -m "chore: update CF tunnel token [skip nops]"
                      git push
                  else
                      echo "[NOPS] Tunnel token unchanged — no update needed."
                  fi
              fi
          fi
      else
          echo "[NOPS] Terraform directory not present. Skipping tunnel provisioning."
      fi
CFEOF
)
    # Write the controller script block to a temp file and use sed to replace the placeholder
    CF_SCRIPT_FILE=$(mktemp)
    echo "$CF_SCRIPT" > "$CF_SCRIPT_FILE"
    sudo chown nops:nops "$CF_SCRIPT_FILE"
    sudo chmod 0644 "$CF_SCRIPT_FILE"
    sudo -u nops sed -i "/CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER/{
        r $CF_SCRIPT_FILE
        d
    }" "$NODE_DIR/configuration.nix"
    rm -f "$CF_SCRIPT_FILE"
else
    sudo -u nops sed -i "/CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
fi

# Adds this node's age public key to .sops.yaml and injects its nixosConfiguration into flake.nix via NODES_MARKER.
SOPS_CONFIG="$TARGET_DIR/.sops.yaml"
SECRETS_FILE="$TARGET_DIR/secrets/secrets.yaml"

log "Updating Fleet SOPS configuration..."
if [ ! -f "$SOPS_CONFIG" ]; then
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/.sops.yaml" "$SOPS_CONFIG"
    sudo -u nops chmod u+w "$SOPS_CONFIG"
fi

if ! grep -q "$PUB_KEY" "$SOPS_CONFIG"; then
    log "Adding public key to SOPS config..."
    sudo -u nops sed -i "s|AGE_PUBLIC_KEY_PLACEHOLDER|$PUB_KEY|g" "$SOPS_CONFIG"
fi

log "Adding node to Fleet flake.nix..."
if ! grep -q "nixosConfigurations.$HOSTNAME" "$TARGET_DIR/flake.nix"; then
    sudo -u nops sed -i "/# NODES_MARKER/a \    nixosConfigurations.$HOSTNAME = nixpkgs.lib.nixosSystem { system = \"x86_64-linux\"; modules = [ ./nodes/$HOSTNAME/configuration.nix nops.nixosModules.default ]; };" "$TARGET_DIR/flake.nix"
else
    log "Node $HOSTNAME already exists in flake.nix. Skipping insertion."
fi

# Creates and SOPS-encrypts secrets.yaml on first enrollment; updates SOPS keys on subsequent runs.
if [ ! -f "$SECRETS_FILE" ]; then
    log "Initializing global secrets file..."
    sudo -u nops mkdir -p "$(dirname "$SECRETS_FILE")"
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/secrets.yaml" "$SECRETS_FILE"

    # Escapes &, /, and \ so they are treated as literals in sed replacement strings.
    escape_sed() { echo "$1" | sed 's/[&/\]/\\&/g'; }

    sudo -u nops sed -i "s|git_username:.*|git_username: \"$(escape_sed "$GIT_USER")\"|" "$SECRETS_FILE"
    sudo -u nops sed -i "s|git_password:.*|git_password: \"$(escape_sed "$GIT_TOKEN")\"|" "$SECRETS_FILE"

    # Pre-populate CF tunnel fields collected during prompts so they appear in the editor
    if [ "${CF_TUNNEL:-false}" = "true" ]; then
        sudo -u nops sed -i "s|cloudflare_tunnel_name:.*|cloudflare_tunnel_name: \"$(escape_sed "$CF_TUNNEL_NAME")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|cloudflare_tunnel_domain:.*|cloudflare_tunnel_domain: \"$(escape_sed "$CF_TUNNEL_DOMAIN")\"|" "$SECRETS_FILE"
    fi

    if [ "$NON_INTERACTIVE" = true ]; then
        log "Injecting secrets from config file..."
        sudo -u nops sed -i "s|matrix_bot_token:.*|matrix_bot_token: \"$(escape_sed "$MATRIX_BOT_TOKEN")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|matrix_room_id:.*|matrix_room_id: \"$(escape_sed "$MATRIX_ROOM_ID")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|matrix_homeserver:.*|matrix_homeserver: \"$(escape_sed "$MATRIX_HOMESERVER")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|webhook_secret:.*|webhook_secret: \"$(escape_sed "$WEBHOOK_SECRET")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|cloudflare_api_token:.*|cloudflare_api_token: \"$(escape_sed "$CF_API_TOKEN")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|cloudflare_tunnel_name:.*|cloudflare_tunnel_name: \"$(escape_sed "$CF_TUNNEL_NAME")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|cloudflare_tunnel_domain:.*|cloudflare_tunnel_domain: \"$(escape_sed "$CF_TUNNEL_DOMAIN")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|cloudflare_zone_id:.*|cloudflare_zone_id: \"$(escape_sed "$CF_ZONE_ID")\"|" "$SECRETS_FILE"
        sudo -u nops sed -i "s|cloudflare_account_id:.*|cloudflare_account_id: \"$(escape_sed "$CF_ACCOUNT_ID")\"|" "$SECRETS_FILE"
    else
        log "Opening secrets/secrets.yaml for Matrix setup..."
        read -p "Press Enter to open editor (Ensure Matrix credentials are set)..."
        sudo -u nops vim "$SECRETS_FILE"
    fi

    sudo -u nops sops --config "$SOPS_CONFIG" --encrypt --in-place "$SECRETS_FILE"
else
    log "Global secrets file exists. Attempting key update..."
    if ! sudo -u nops sops updatekeys -y "$SECRETS_FILE" 2>/dev/null; then
        warn "Manual authorization required on another node for this key."
    fi

    # Inject CF tunnel secrets into existing encrypted secrets when tunnel is enabled and fields are missing.
    if [ "${CF_TUNNEL:-false}" = "true" ]; then
        EXISTING=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d "$SECRETS_FILE" 2>/dev/null || true)
        if ! echo "$EXISTING" | grep -q "cloudflare_tunnel_name"; then
            log "Adding Cloudflare tunnel fields to existing secrets..."
            sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set '["cloudflare_tunnel_name"] '"$CF_TUNNEL_NAME"'"' "$SECRETS_FILE"
            sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set '["cloudflare_tunnel_domain"] '"$CF_TUNNEL_DOMAIN"'"' "$SECRETS_FILE"
            log "CF tunnel fields injected into secrets."
        fi
        if [ -n "$CF_API_TOKEN" ] && ! echo "$EXISTING" | grep -q "cloudflare_api_token"; then
            sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set '["cloudflare_api_token"] '"$CF_API_TOKEN"'"' "$SECRETS_FILE"
        fi
        if [ -n "$CF_ZONE_ID" ] && ! echo "$EXISTING" | grep -q "cloudflare_zone_id"; then
            sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set '["cloudflare_zone_id"] '"$CF_ZONE_ID"'"' "$SECRETS_FILE"
        fi
        if [ -n "$CF_ACCOUNT_ID" ] && ! echo "$EXISTING" | grep -q "cloudflare_account_id"; then
            sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set '["cloudflare_account_id"] '"$CF_ACCOUNT_ID"'"' "$SECRETS_FILE"
        fi
    fi
fi

if [ "${PXE_ENABLE:-false}" = "true" ]; then
    log "PXE bootstrap enabled. Scaffolding module..."

    PXE_MODULE_DIR="$TARGET_DIR/modules/pxe"
    if [ ! -d "$PXE_MODULE_DIR" ]; then
        sudo -u nops mkdir -p "$PXE_MODULE_DIR"
    fi
    sudo -u nops cp --no-preserve=mode "$TEMPLATES_DIR/pxe.nix" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u nops chmod u+w "$PXE_MODULE_DIR/pxe.nix"
    sudo -u nops sed -i "s|PXE_INTERFACE_PLACEHOLDER|${PXE_INTERFACE:-}|" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u nops sed -i "s|PXE_HTTP_PORT_PLACEHOLDER|${PXE_HTTP_PORT:-8081}|" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u nops sed -i "s|PXE_BOOT_URL_PLACEHOLDER|${PXE_BOOT_URL:-}|" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u nops sed -i "s|PXE_DHCP_ENABLE_PLACEHOLDER|${PXE_DHCP_ENABLE:-false}|" "$PXE_MODULE_DIR/pxe.nix"
fi

log "Ensuring encrypted repository provisioning metadata..."
sync_encrypted_json_file "$TARGET_DIR/deployments.json"
sync_encrypted_json_file "$TARGET_DIR/nops-config-template.json"

# Opens the node config in an editor before committing, allowing manual adjustments such as static IP.
if [ "$NON_INTERACTIVE" != true ]; then
    log "Opening node configuration for manual adjustments (e.g., networking, static IP)..."
    read -p "Press Enter to open editor ($NODE_DIR/configuration.nix)..."
    sudo -u nops vim "$NODE_DIR/configuration.nix"
else
    log "Skipping manual node configuration (Non-interactive mode)."
fi


# Commits all scaffolded files. Defers push if running in bootstrap mode.
log "Committing enrollment to Fleet repository..."
sudo -u nops git config user.email "nops-installer@$HOSTNAME"
sudo -u nops git config user.name "nops Installer"
sudo -u nops git add .
sudo -u nops git commit -m "Enrollment: $HOSTNAME (Group: $NODE_GROUP)" || log "No changes to commit."

if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Bootstrap mode: Deferring git push until Forgejo is online."
else
    log "Pushing enrollment to Fleet repository..."
    sudo -u nops env GIT_CONFIG_NOSYSTEM=1 git push origin main
    log "Hardening Git security..."
    sudo -u nops git remote set-url origin "$REPO_URL"
fi

# Triggers the initial nixos-rebuild to activate the enrolled configuration.
log "Executing initial system rebuild..."
export NIXPKGS_ALLOW_UNFREE=1
if ! sudo NIXPKGS_ALLOW_UNFREE=1 nixos-rebuild switch --flake "$TARGET_DIR#$HOSTNAME" --upgrade --impure; then
    log_rebuild_failure_details
    warn "Initial rebuild failed. Check secrets authorization or syntax errors and run activation manually."
    exit 1
fi

# Bootstrap Handoff: API integration with Forgejo
if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Bootstrap Handoff: Creating Forgejo Admin User ($GIT_USER)..."
    repair_forgejo_runtime_permissions
    # Wait for the Forgejo service to become reachable over HTTP before API calls.
    wait_for_forgejo_http 30 || log_unit_diagnostics forgejo
    
    # Use the local Forgejo CLI with absolute paths and explicit config so NixOS can locate the database.
    sudo -u forgejo env FORGEJO_WORK_DIR=/var/lib/forgejo /run/current-system/sw/bin/forgejo \
        --config /var/lib/forgejo/custom/conf/app.ini \
        admin user create --admin \
        --username "$GIT_USER" \
        --password "$GIT_TOKEN" \
        --email "admin@localhost" || log "User may already exist, continuing."
    
    log "Creating '$REPO_NAME' repository via Forgejo API..."
    # Forgejo runs on port 3000 by default locally
    set +e
    REPO_CREATE_STATUS=$(curl -sS --max-time 20 -o /tmp/nops-forgejo-create.log -w "%{http_code}" -X POST "http://localhost:3000/api/v1/user/repos" \
         -H "Content-Type: application/json" \
         -u "$GIT_USER:$GIT_TOKEN" \
         -d "{\"name\": \"$REPO_NAME\", \"private\": true}")
    REPO_CREATE_EXIT=$?
    set -e

    if [ "$REPO_CREATE_EXIT" -ne 0 ]; then
        warn "Forgejo repository API call failed with exit code $REPO_CREATE_EXIT."
        if [ -f /tmp/nops-forgejo-create.log ]; then
            log "Forgejo repository API response body:"
            cat /tmp/nops-forgejo-create.log || true
        fi
        log_unit_diagnostics forgejo
        exit 1
    fi

    log "Forgejo repository API response: HTTP $REPO_CREATE_STATUS"
    if [ -f /tmp/nops-forgejo-create.log ]; then
        log "Forgejo repository API response body:"
        cat /tmp/nops-forgejo-create.log || true
    fi

    if [ "$REPO_CREATE_STATUS" != "201" ] && [ "$REPO_CREATE_STATUS" != "409" ]; then
        warn "Unexpected Forgejo repository API status: HTTP $REPO_CREATE_STATUS"
        log_unit_diagnostics forgejo
        exit 1
    fi

    log "Creating nops automation webhook via Forgejo API..."
    WEBHOOK_PAYLOAD=$(jq -n \
        --arg url "http://${CF_TUNNEL_VIP:-localhost}:8080/webhook" \
        --arg secret "$WEBHOOK_SECRET" \
        '{
            type: "gitea",
            config: {
                url: $url,
                content_type: "json",
                secret: $secret
            },
            events: ["push"],
            active: true
        }')

    HOOK_STATUS=$(curl -sS --max-time 20 -o /tmp/nops-hook.log -w "%{http_code}" -X POST "http://localhost:3000/api/v1/repos/$GIT_USER/$REPO_NAME/hooks" \
         -H "Content-Type: application/json" \
         -u "$GIT_USER:$GIT_TOKEN" \
         -d "$WEBHOOK_PAYLOAD")

    if [ "$HOOK_STATUS" = "201" ]; then
        log "Automation webhook created successfully."
    elif [ "$HOOK_STATUS" = "409" ]; then
        log "Webhook already exists, skipping."
    else
        warn "Failed to create webhook (HTTP $HOOK_STATUS). You may need to add it manually in the UI."
    fi

    log "Preparing local Forgejo push remote with credentials..."
    ENCODED_TOKEN=$(jq -nr --arg v "$GIT_TOKEN" '$v | @uri')
    sudo -u nops git remote set-url origin "http://$GIT_USER:$ENCODED_TOKEN@localhost:3000/$GIT_USER/$REPO_NAME.git"

    log "Deferring repository push until after service provisioning..."

    if [ "${CF_TUNNEL:-false}" = "true" ] && [ "${IS_CONTROLLER:-false}" = "true" ]; then
        log "Starting immediate Cloudflare tunnel provisioning before the final repository push..."
        if run_cloudflare_provisioning "$TARGET_DIR"; then
            log "Running follow-up rebuild to materialize Cloudflare tunnel token..."
            sudo NIXPKGS_ALLOW_UNFREE=1 nixos-rebuild switch --flake "$TARGET_DIR#$HOSTNAME" --impure || warn "Follow-up rebuild failed after Cloudflare provisioning."
        else
            warn "Immediate Cloudflare provisioning failed during bootstrap handoff."
        fi
    fi

    log "Pushing bootstrap repository to local Forgejo as one of the final bootstrap steps..."
    sudo -u nops env GIT_CONFIG_NOSYSTEM=1 git push -u --force origin main
    log "Bootstrap repository push succeeded."

    if [ "${CF_TUNNEL:-false}" = "true" ] && [ "${IS_CONTROLLER:-false}" = "true" ]; then
        log "Running final rebuild to ensure cloudflared is active after the repo push..."
        sudo NIXPKGS_ALLOW_UNFREE=1 nixos-rebuild switch --flake "$TARGET_DIR#$HOSTNAME" --impure || warn "Final rebuild failed after bootstrap push."
    fi

    log "Restoring bootstrap repository remote to configured shared URL..."
    sudo -u nops git remote set-url origin "$REPO_URL"
    
    log "Bootstrap Complete. Fleet repository is now live at $REPO_URL"
fi

echo -e "${GREEN}[SUCCESS]${NC} Enrollment complete."