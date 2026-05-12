#!/usr/bin/env bash
# Enrolls a new node into the fleet: creates the nix-cluster user, clones the repo, scaffolds node config, configures SOPS, and pushes the enrollment commit.
set -e

# Ensure clean exit after git push (for Controller automation)
trap 'exit 0' EXIT

HOSTNAME=$(hostname)
TEMPLATES_DIR="${NIX_CLUSTER_TEMPLATES_DIR:-${NOPS_TEMPLATES_DIR:-../templates}}"
DEFAULT_NIX_CLUSTER_REPO_URL="https://git.smallguytech.org/SGT/nix-cluster.git"
DEFAULT_NIXOS_INSTALL_REPO_URL="https://git.example.com/example/nixos-install.git"
DEFAULT_APP_REGISTRY_URL="https://git.smallguytech.org/SGT/app-registry.git"
SERVICE_USER="nix-cluster"
SERVICE_GROUP="nix-cluster"
SERVICE_HOME="/home/${SERVICE_USER}"
LEGACY_SERVICE_USER="nops"
LEGACY_SERVICE_HOME="/home/${LEGACY_SERVICE_USER}"

HELPER_DIR="${NIX_CLUSTER_SRC_DIR:-${NOPS_SRC_DIR:-$(cd "$(dirname "$0")" && pwd)}}/lib"
if [ -f "$HELPER_DIR/install-config.sh" ]; then
    # shellcheck source=./lib/install-config.sh
    . "$HELPER_DIR/install-config.sh"
fi

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_FILE=""
NON_INTERACTIVE=false
CLEAN=false

parse_install_cli_args "$@"

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file $CONFIG_FILE not found!"
        exit 1
    fi
    NON_INTERACTIVE=true
fi

LOG_FILE="/var/log/nix-cluster-setup.log"
CONFIG_TEMPLATE_NAME="nix-cluster-config-template.json"
LEGACY_CONFIG_TEMPLATE_NAME="nops-config-template.json"

# Writes a timestamped INFO entry to both stdout and the log file.
log() { 
    echo -e "${BLUE}[nix-cluster-setup]${NC} $1"
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [nix-cluster-setup] [INFO] $1" | sudo tee -a "$LOG_FILE" > /dev/null
}

success_banner() {
    local message="$1"

    log "============================================================"
    log "$message"
    log "============================================================"
    if command -v logger >/dev/null 2>&1; then
        logger -t nix-cluster-setup -- "$message" || true
    fi
    printf '%b\n' "${GREEN}${message}${NC}"
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

    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$source_file" "$temp_file"
}

# Encrypts plaintext JSON files or rotates keys for already encrypted ones.
sync_encrypted_json_file() {
    local target_file="$1"

    if [ ! -f "$target_file" ]; then
        return 0
    fi

    if sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d "$target_file" >/dev/null 2>&1; then
        if ! sudo -u "$SERVICE_USER" sops updatekeys -y "$target_file" 2>/dev/null; then
            warn "Manual authorization required on another node for $(basename "$target_file") key rotation."
        fi
        return 0
    fi

    if ! sudo -u "$SERVICE_USER" sops --config "$SOPS_CONFIG" --encrypt --in-place "$target_file" 2>/dev/null; then
        warn "Could not encrypt $(basename "$target_file") during bootstrap; keeping the plaintext file for now."
        return 0
    fi
}

hydrate_deployments_from_runtime_workers() {
        local target_file="$1"
        local runtime_file="/etc/nix-cluster-runtime-config.json"
        local source_file
        local temp_file

        if [ ! -r "$runtime_file" ] || ! jq -e '.workers? | type == "object" and length > 0' "$runtime_file" >/dev/null 2>&1; then
                return 0
        fi

        source_file=$(mktemp)
        temp_file=$(mktemp)
        prepare_json_for_edit "$target_file" "$source_file"

        jq --slurpfile runtime "$runtime_file" '
            def normalized_existing:
                if type == "array" then . else [] end;
            def worker_entries($runtime):
                ($runtime[0].workers // {} | to_entries | map({
                    hostname: .key,
                    installer_ip: (.value.installer_ip // ""),
                    installer_user: (.value.installer_user // "nixos"),
                    installer_auth_mode: (.value.installer_auth_mode // "ssh_key"),
                    installer_ssh_pub_key: (.value.installer_ssh_pub_key // ""),
                    installer_password: (.value.installer_password // ""),
                    installer_mode: (.value.installer_mode // "default"),
                    installer_script: (.value.installer_script // ""),
                    installer_pre_script: (.value.installer_pre_script // ""),
                    installer_post_script: (.value.installer_post_script // ""),
                    reinstall: (.value.reinstall // false),
                    disk: (.value.disk // "/dev/sda"),
                    fs: (.value.fs // "zfs"),
                    node_group: (.value.node_group // "default"),
                    node_role: (.value.node_role // "worker"),
                    keepalived_role: (.value.keepalived_role // "backup"),
                    node_admin: (.value.node_admin // "admin"),
                    ssh_password_auth: (.value.ssh_password_auth // false),
                    node_admin_pass: (.value.node_admin_pass // ""),
                    node_admin_password_hash: (.value.node_admin_password_hash // ""),
                    node_directory: (.value.node_directory // ("nodes/" + .key))
                }));
            (normalized_existing) as $existing |
            (worker_entries($runtime)) as $workers |
            ($existing | map({ key: .hostname, value: . }) | from_entries) as $existing_map |
            reduce $workers[] as $worker ($existing_map; .[$worker.hostname] = ((.[$worker.hostname] // {}) + $worker)) |
            to_entries | map(.value) | sort_by(.hostname)
        ' "$source_file" > "$temp_file"

        rm -f "$source_file"
        sudo mv "$temp_file" "$target_file"
        sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$target_file"
        sudo chmod 0644 "$target_file"
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
    git commit -m "chore: reuse CF tunnel token [skip nix-cluster]" || true
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

    local terraform_dir=""

    if [ -d "$repo_dir/apps/terraform" ]; then
        terraform_dir="$repo_dir/apps/terraform"
    elif [ -d "$repo_dir/modules/terraform" ]; then
        terraform_dir="$repo_dir/modules/terraform"
    fi

    if [ "${CF_TUNNEL:-false}" != "true" ] || [ "${IS_CONTROLLER:-false}" != "true" ] || [ -z "$terraform_dir" ]; then
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

        cd "$terraform_dir"
        log "Running terraform init in $terraform_dir..."
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
            git commit -m "chore: update CF tunnel token [skip nix-cluster]" || true
            log "Pushing updated tunnel token back to origin..."
            git push origin main || warn "Could not push tunnel token update immediately; it will be included in the final bootstrap push."
        fi
    )
}

log "Initializing nix-cluster fleet enrollment for $HOSTNAME..."

# Wipes the nix-cluster user, home directory, and age key to allow a clean re-enrollment.
if [ "$CLEAN" = true ]; then
    log "--clean flag detected. Wiping previous nix-cluster state..."
    if id "$SERVICE_USER" &>/dev/null; then
        sudo userdel -r "$SERVICE_USER" 2>/dev/null || true
        sudo groupdel "$SERVICE_GROUP" 2>/dev/null || true
    fi
    if id "$LEGACY_SERVICE_USER" &>/dev/null; then
        sudo userdel -r "$LEGACY_SERVICE_USER" 2>/dev/null || true
        sudo groupdel "$LEGACY_SERVICE_USER" 2>/dev/null || true
    fi
    sudo rm -rf "$SERVICE_HOME" "$LEGACY_SERVICE_HOME"
    sudo rm -f /var/lib/sops-nix/key.txt
    sudo git config --global --unset-all safe.directory 2>/dev/null || true
    log "Clean complete."
fi

# Creates the nix-cluster service user and group if absent; ensures correct home directory ownership.
if ! id "$SERVICE_USER" &>/dev/null; then
    log "User '$SERVICE_USER' does not exist. Creating temporary service user..."
    sudo groupadd "$SERVICE_GROUP" || true
    sudo useradd -m -d "$SERVICE_HOME" -g "$SERVICE_GROUP" -s /run/current-system/sw/bin/bash "$SERVICE_USER"
fi
if [ -d "$LEGACY_SERVICE_HOME" ] && [ ! -L "$LEGACY_SERVICE_HOME" ]; then
    sudo mkdir -p "$SERVICE_HOME"
    sudo cp -a "$LEGACY_SERVICE_HOME/." "$SERVICE_HOME/" 2>/dev/null || true
fi
sudo mkdir -p "$SERVICE_HOME"
sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$SERVICE_HOME"
sudo -u "$SERVICE_USER" mkdir -p "$SERVICE_HOME/.ssh"
sudo chmod 700 "$SERVICE_HOME/.ssh"

if [ ! -f "$SERVICE_HOME/.ssh/id_ed25519" ]; then
    log "Generating controller SSH key for automated provisioning..."
    sudo -u "$SERVICE_USER" ssh-keygen -t ed25519 -f "$SERVICE_HOME/.ssh/id_ed25519" -N ""
fi

CONTROLLER_NODE_SSH_PUB_KEY=$(sudo -u "$SERVICE_USER" cat "$SERVICE_HOME/.ssh/id_ed25519.pub")

# Reads git credentials, repo URL, group, admin user, trigger mode, and secrets from a JSON config file or interactive prompts.
if [ "$NON_INTERACTIVE" = true ]; then
    log "Non-interactive mode enabled. Reading from $CONFIG_FILE..."
    IS_BOOTSTRAP=$(jq -r '.bootstrap_mode // "false"' "$CONFIG_FILE")
    GIT_USER=$(jq -r '.git_user // empty' "$CONFIG_FILE")
    GIT_TOKEN=$(jq -r '.git_token // empty' "$CONFIG_FILE")
    REPO_URL=$(jq -r '.repo_url // empty' "$CONFIG_FILE")
    REPO_HOST_IP=$(jq -r '.repo_host_ip // empty' "$CONFIG_FILE")
    NIX_CLUSTER_REPO_URL=$(jq -r --arg default_repo "$DEFAULT_NIX_CLUSTER_REPO_URL" '.nix_cluster_repo_url // .nops_repo_url // $default_repo' "$CONFIG_FILE")
    NIXOS_INSTALL_REPO_URL=$(jq -r --arg default_repo "$DEFAULT_NIXOS_INSTALL_REPO_URL" '.nixos_install_repo_url // .nops_repo_url // $default_repo' "$CONFIG_FILE")
    REGISTRY_MODE=$(jq -r '.registry_mode // "bundled"' "$CONFIG_FILE")
    APP_REGISTRY_URL=$(jq -r --arg default_repo "$DEFAULT_APP_REGISTRY_URL" '.app_registry_url // .module_registry_url // $default_repo' "$CONFIG_FILE")
    NODE_GROUP=$(jq -r '.node_group // "default"' "$CONFIG_FILE")
    NODE_ADMIN=$(jq -r '.node_admin // empty' "$CONFIG_FILE")
    NODE_ADMIN_PASS=$(jq -r '.node_admin_pass // empty' "$CONFIG_FILE")
    NODE_ADMIN_PASSWORD_HASH=$(jq -r '.node_admin_password_hash // empty' "$CONFIG_FILE")
    NODE_SSH_PUB_KEY=$(jq -r 'if (.node_ssh_pub_key // "") != "" then .node_ssh_pub_key elif ((.node_ssh_pub_keys // []) | length) > 0 then .node_ssh_pub_keys[0] else "" end' "$CONFIG_FILE")
    NODE_SSH_PUB_KEYS_JSON=$(jq -c '(.node_ssh_pub_keys // []) as $keys | if ($keys | length) > 0 then $keys elif (.node_ssh_pub_key // "") != "" then [ .node_ssh_pub_key ] else [] end' "$CONFIG_FILE")
    SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth // "false"' "$CONFIG_FILE")
    INSTALLER_AUTH_MODE=$(jq -r '.installer_auth_mode // "ssh_key"' "$CONFIG_FILE")
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
    CADDY_ENABLE=$(jq -r '.apps.caddy.enable // .modules.caddy.enable // .caddy_enable // "false"' "$CONFIG_FILE")
    FORGEJO_PUBLIC_HOST=$(jq -r '.forgejo_public_host // ""' "$CONFIG_FILE")
    KEEPALIVED_ENABLE=$(jq -r '.apps.keepalived.enable // .modules.keepalived.enable // .keepalived_enable // "false"' "$CONFIG_FILE")
    KEEPALIVED_INTERFACE=$(jq -r '.apps.keepalived.interface // .modules.keepalived.interface // .keepalived_interface // ""' "$CONFIG_FILE")
    KEEPALIVED_ROUTER_ID=$(jq -r '.apps.keepalived.virtual_router_id // .apps.keepalived.virtualRouterId // .modules.keepalived.virtual_router_id // .modules.keepalived.virtualRouterId // .keepalived_virtual_router_id // "51"' "$CONFIG_FILE")
    KEEPALIVED_PRIORITY=$(jq -r '.apps.keepalived.priority // .modules.keepalived.priority // .keepalived_priority // "150"' "$CONFIG_FILE")
    KEEPALIVED_VIP_CIDR=$(jq -r '.apps.keepalived.vip_cidr // .apps.keepalived.vipCidr // .modules.keepalived.vip_cidr // .modules.keepalived.vipCidr // .keepalived_vip_cidr // ""' "$CONFIG_FILE")
    CF_TUNNEL=$(jq -r '.apps.cloudflare.tunnel // .apps.cloudflare.enable // .modules.cloudflare.tunnel // .modules.cloudflare.enable // .cloudflare_tunnel // "false"' "$CONFIG_FILE")
    CF_TUNNEL_NAME=$(jq -r '.apps.cloudflare.tunnel_name // .apps.cloudflare.tunnelName // .modules.cloudflare.tunnel_name // .modules.cloudflare.tunnelName // .cloudflare_tunnel_name // ""' "$CONFIG_FILE")
    CF_TUNNEL_DOMAIN=$(jq -r '.apps.cloudflare.tunnel_domain // .apps.cloudflare.tunnelDomain // .modules.cloudflare.tunnel_domain // .modules.cloudflare.tunnelDomain // .cloudflare_tunnel_domain // ""' "$CONFIG_FILE")
    CF_TUNNEL_VIP=$(jq -r '.apps.cloudflare.tunnel_vip // .apps.cloudflare.vip // .modules.cloudflare.tunnel_vip // .modules.cloudflare.vip // .cloudflare_tunnel_vip // ""' "$CONFIG_FILE")
    CF_ZONE_ID=$(jq -r '.apps.cloudflare.zone_id // .apps.cloudflare.zoneId // .modules.cloudflare.zone_id // .modules.cloudflare.zoneId // .cloudflare_zone_id // ""' "$CONFIG_FILE")
    CF_ACCOUNT_ID=$(jq -r '.apps.cloudflare.account_id // .apps.cloudflare.accountId // .modules.cloudflare.account_id // .modules.cloudflare.accountId // .cloudflare_account_id // ""' "$CONFIG_FILE")
    PXE_ENABLE=$(jq -r '.apps.pxe.enable // .modules.pxe.enable // .pxe_enable // "false"' "$CONFIG_FILE")
    PXE_DHCP_ENABLE=$(jq -r '.apps.pxe.dhcp_enable // .apps.pxe.dhcpEnable // .modules.pxe.dhcp_enable // .modules.pxe.dhcpEnable // .pxe_dhcp_enable // "false"' "$CONFIG_FILE")
    PXE_INTERFACE=$(jq -r '.apps.pxe.interface // .modules.pxe.interface // .pxe_interface // ""' "$CONFIG_FILE")
    PXE_HTTP_PORT=$(jq -r '.apps.pxe.http_port // .apps.pxe.httpPort // .modules.pxe.http_port // .modules.pxe.httpPort // .pxe_http_port // "8081"' "$CONFIG_FILE")
    PXE_BOOT_URL=$(jq -r '.apps.pxe.boot_url // .apps.pxe.bootUrl // .modules.pxe.boot_url // .modules.pxe.bootUrl // .pxe_boot_url // ""' "$CONFIG_FILE")
    POSTGRES_BACKUP_ENABLE=$(jq -r '.apps.postgresBackup.enable // .apps.postgres_backup.enable // .modules.postgresBackup.enable // .modules.postgres_backup.enable // .postgres_backup_enable // "false"' "$CONFIG_FILE")
    IS_CONTROLLER=$(jq -r '.is_controller // "false"' "$CONFIG_FILE")

    CUSTOM_GROUP_CONFIG=$(jq -r '.custom_group_config // ""' "$CONFIG_FILE")
    CUSTOM_GROUP_IMPORTS=$(jq -r '.custom_group_imports // ""' "$CONFIG_FILE")
    CUSTOM_NODE_CONFIG=$(jq -r '.custom_node_config // ""' "$CONFIG_FILE")
    CUSTOM_NODE_IMPORTS=$(jq -r '.custom_node_imports // ""' "$CONFIG_FILE")
    PRESERVE_EXISTING_NODE_FILES=$(jq -r '.preserve_existing_node_files // "false"' "$CONFIG_FILE")

    if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ] || [ -z "$REPO_URL" ] || [ -z "$NODE_ADMIN" ]; then
        echo "Error: Missing required fields in config file."
        exit 1
    fi
    apply_install_overrides
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
    read -p "nix-cluster repo URL for generated fleet flakes [$DEFAULT_NIX_CLUSTER_REPO_URL]: " NIX_CLUSTER_REPO_URL
    NIX_CLUSTER_REPO_URL=${NIX_CLUSTER_REPO_URL:-$DEFAULT_NIX_CLUSTER_REPO_URL}
    read -p "nix-cluster install repo URL for controller provisioning [$DEFAULT_NIXOS_INSTALL_REPO_URL]: " NIXOS_INSTALL_REPO_URL
    NIXOS_INSTALL_REPO_URL=${NIXOS_INSTALL_REPO_URL:-$DEFAULT_NIXOS_INSTALL_REPO_URL}
    read -p "App source mode [bundled/registry] [bundled]: " REGISTRY_MODE
    REGISTRY_MODE=${REGISTRY_MODE:-bundled}
    if [ "$REGISTRY_MODE" = "registry" ]; then
        read -p "App registry URL [$DEFAULT_APP_REGISTRY_URL]: " APP_REGISTRY_URL
        APP_REGISTRY_URL=${APP_REGISTRY_URL:-$DEFAULT_APP_REGISTRY_URL}
    fi

    read -p "Enter the group/tier for this node (e.g., media, signaling, db) [default]: " NODE_GROUP
    NODE_GROUP=${NODE_GROUP:-default}

    read -p "SETUP ADMIN USERNAME (for this node): " NODE_ADMIN
    read -p "Optional: Enter SSH Public Key for $NODE_ADMIN (Leave blank to skip): " NODE_SSH_PUB_KEY
    if [ -n "$NODE_SSH_PUB_KEY" ]; then
        NODE_SSH_PUB_KEYS_JSON=$(jq -cn --arg key "$NODE_SSH_PUB_KEY" '[ $key ]')
    else
        NODE_SSH_PUB_KEYS_JSON='[]'
    fi
    echo ""
    read -p "Enable SSH password authentication for $NODE_ADMIN? (y/N): " SSH_PASSWORD_AUTH_PROMPT
    if [[ "$SSH_PASSWORD_AUTH_PROMPT" =~ ^[Yy]$ ]]; then
        SSH_PASSWORD_AUTH="true"
    else
        SSH_PASSWORD_AUTH="false"
    fi
    read -s -p "Optional password for $NODE_ADMIN (leave blank for key-only access): " NODE_ADMIN_PASS
    echo ""
    NODE_ADMIN_PASSWORD_HASH=""
    read -p "Node role [controller/worker/service/backup/spare] [worker]: " NODE_ROLE
    NODE_ROLE=${NODE_ROLE:-worker}
    if [ "$NODE_ROLE" = "controller" ]; then
        KEEPALIVED_ROLE="master"
    elif [ "$NODE_ROLE" = "backup" ]; then
        KEEPALIVED_ROLE="backup"
    else
        KEEPALIVED_ROLE="backup"
    fi
    read -p "Installer auth mode for live-USB/netboot deployments [ssh_key/auto/password] [ssh_key]: " INSTALLER_AUTH_MODE
    INSTALLER_AUTH_MODE=${INSTALLER_AUTH_MODE:-ssh_key}
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
    apply_install_overrides
fi

REGISTRY_MODE=${REGISTRY_MODE:-bundled}
APP_REGISTRY_URL=${APP_REGISTRY_URL:-${MODULE_REGISTRY_URL:-$DEFAULT_APP_REGISTRY_URL}}
PRESERVE_EXISTING_NODE_FILES=${PRESERVE_EXISTING_NODE_FILES:-false}

if [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    IS_CONTROLLER="true"
    NODE_ROLE="controller"
    KEEPALIVED_ROLE="master"
    POSTGRES_BACKUP_ENABLE="true"
fi

if [ "${NODE_ROLE:-worker}" = "controller" ]; then
    IS_CONTROLLER="true"
fi

if [ "${IS_CONTROLLER:-false}" = "true" ] && { [ -z "${NIX_CLUSTER_REPO_URL:-}" ] || [ -z "${NIXOS_INSTALL_REPO_URL:-}" ]; }; then
    echo "Error: nix_cluster_repo_url and nixos_install_repo_url must be set for controller/bootstrap installs."
    exit 1
fi

if [ -z "${SSH_PASSWORD_AUTH:-}" ]; then
    SSH_PASSWORD_AUTH="false"
fi

if [ -n "${NODE_ADMIN_PASS:-}" ] && [ -z "${NODE_ADMIN_PASSWORD_HASH:-}" ]; then
    NODE_ADMIN_PASSWORD_HASH=$(mkpasswd -m sha-512 -s <<< "$NODE_ADMIN_PASS")
fi

NODE_SSH_PUB_KEYS_JSON=${NODE_SSH_PUB_KEYS_JSON:-$(if [ -n "${NODE_SSH_PUB_KEY:-}" ]; then jq -cn --arg key "$NODE_SSH_PUB_KEY" '[ $key ]'; else printf '[]'; fi)}
NODE_SSH_PUB_KEY=$(jq -r '.[0] // ""' <<< "$NODE_SSH_PUB_KEYS_JSON")

if [ "${SSH_PASSWORD_AUTH:-false}" = "true" ] && [ -z "${NODE_ADMIN_PASSWORD_HASH:-}" ]; then
    echo "Error: ssh_password_auth=true requires node_admin_pass or node_admin_password_hash."
    exit 1
fi

if [ "$(jq -r 'length' <<< "$NODE_SSH_PUB_KEYS_JSON")" -eq 0 ] && [ -z "${NODE_ADMIN_PASSWORD_HASH:-}" ]; then
    echo "Error: Provide node_ssh_pub_key/node_ssh_pub_keys or an admin password/hash so the node remains accessible."
    exit 1
fi

if [ "$CLEAN" = true ] && [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    log "Bootstrap clean requested. Wiping local Forgejo and tunnel runtime state..."
    sudo systemctl stop nix-cluster 2>/dev/null || sudo systemctl stop nops 2>/dev/null || true
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
TARGET_DIR="$SERVICE_HOME/$REPO_NAME"

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

# Clones the fleet repository with URL-encoded credentials into /home/nix-cluster/<repo-name>. Marks the directory safe for root rebuilds.
if [ -d "$TARGET_DIR" ]; then
    log "Cleaning existing fleet directory..."
    sudo rm -rf "$TARGET_DIR"
fi

if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Bootstrap Mode: Initializing local fleet repository..."
    sudo -u "$SERVICE_USER" mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR"
    sudo -u "$SERVICE_USER" git init
    sudo -u "$SERVICE_USER" git checkout -b main
    ENCODED_TOKEN=$(jq -nr --arg v "$GIT_TOKEN" '$v | @uri')
    CLEAN_REPO_URL=$(echo "$REPO_URL" | sed 's|^https\?://||')
    sudo -u "$SERVICE_USER" git remote add origin "http://$GIT_USER:$ENCODED_TOKEN@$CLEAN_REPO_URL"
else
    log "Worker Mode: Cloning Fleet Repository into $TARGET_DIR..."
    ENCODED_TOKEN=$(jq -nr --arg v "$GIT_TOKEN" '$v | @uri')
    CLEAN_REPO_URL=$(echo "$REPO_URL" | sed 's|^https\?://||')
    sudo env GIT_CONFIG_NOSYSTEM=1 git clone "https://$GIT_USER:$ENCODED_TOKEN@$CLEAN_REPO_URL" "$TARGET_DIR"
    sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" "$TARGET_DIR"
    cd "$TARGET_DIR"
fi

sudo git config --global --add safe.directory "$TARGET_DIR"
sudo -u "$SERVICE_USER" git config --global --add safe.directory "$TARGET_DIR"

# Ensures the standard fleet directory structure exists and bootstraps a base flake.nix if the repo is empty.
log "Ensuring fleet root directory structure..."
sudo -u "$SERVICE_USER" mkdir -p apps secrets scripts groups nodes
sudo -u "$SERVICE_USER" touch apps/.keep secrets/.keep scripts/.keep groups/.keep nodes/.keep

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

normalize_tarball_flake_url() {
    local url="$1"

    if [[ "$url" =~ /archive/.*\.tar\.gz($|\?) ]]; then
        printf '%s\n' "$url"
        return 0
    fi

    if [[ "$url" =~ ^https?://[^[:space:]]+\.git$ ]]; then
        printf '%s\n' "${url%.git}/archive/main.tar.gz"
        return 0
    fi

    if [[ "$url" =~ ^https?://[^[:space:]]+$ ]]; then
        printf '%s\n' "${url%/}/archive/main.tar.gz"
        return 0
    fi

    printf '%s\n' "$url"
}

if [ ! -f "flake.nix" ]; then
    log "Empty fleet repository detected. Initializing base flake..."
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/flake.nix" "$TARGET_DIR/flake.nix"
    sudo -u "$SERVICE_USER" chmod u+w "$TARGET_DIR/flake.nix"
    if [ -n "${NIX_CLUSTER_REPO_URL:-}" ]; then
        NIX_CLUSTER_FLAKE_URL="$(normalize_git_flake_url "$NIX_CLUSTER_REPO_URL")"
        sudo -u "$SERVICE_USER" sed -i "s|git+https://git.smallguytech.org/SGT/nix-cluster.git|${NIX_CLUSTER_FLAKE_URL}|" "$TARGET_DIR/flake.nix"
    fi
    if [ "${REGISTRY_MODE:-bundled}" = "registry" ] && [ -n "${APP_REGISTRY_URL:-}" ]; then
        APP_REGISTRY_FLAKE_URL="$(normalize_git_flake_url "$APP_REGISTRY_URL")"
        sudo -u "$SERVICE_USER" sed -i "/APP_REGISTRY_INPUT_PLACEHOLDER/c\
    appRegistry.url = \"${APP_REGISTRY_FLAKE_URL}\";\
    appRegistry.inputs.nixpkgs.follows = \"nixpkgs\";" "$TARGET_DIR/flake.nix"
    else
        sudo -u "$SERVICE_USER" sed -i '/APP_REGISTRY_INPUT_PLACEHOLDER/d' "$TARGET_DIR/flake.nix"
    fi
fi

if [ ! -f "$TARGET_DIR/deployments.json" ]; then
    log "Initializing deployments.json template..."
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/deployments.json" "$TARGET_DIR/deployments.json"
    sudo -u "$SERVICE_USER" chmod u+w "$TARGET_DIR/deployments.json"
fi

CONFIG_TEMPLATE_PATH="$TARGET_DIR/$CONFIG_TEMPLATE_NAME"
if [ ! -f "$CONFIG_TEMPLATE_PATH" ]; then
    if [ -f "$TARGET_DIR/$LEGACY_CONFIG_TEMPLATE_NAME" ]; then
        CONFIG_TEMPLATE_PATH="$TARGET_DIR/$LEGACY_CONFIG_TEMPLATE_NAME"
        log "Using legacy $LEGACY_CONFIG_TEMPLATE_NAME template..."
    else
        log "Initializing $CONFIG_TEMPLATE_NAME template..."
        sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/$CONFIG_TEMPLATE_NAME" "$CONFIG_TEMPLATE_PATH"
        sudo -u "$SERVICE_USER" chmod u+w "$CONFIG_TEMPLATE_PATH"
    fi
fi

if [ "${IS_CONTROLLER:-false}" = "true" ]; then
    log "Hydrating repository-level install templates..."
    NIX_CLUSTER_CONFIG_TEMPLATE_SRC=$(mktemp)
    NIX_CLUSTER_CONFIG_TEMPLATE_TMP=$(mktemp)
    CONTROLLER_NODE_SSH_PUB_KEYS_JSON=$(jq -cn --arg key "$CONTROLLER_NODE_SSH_PUB_KEY" '[ $key ]')
    prepare_json_for_edit "$CONFIG_TEMPLATE_PATH" "$NIX_CLUSTER_CONFIG_TEMPLATE_SRC"
    jq \
        --arg git_user "$GIT_USER" \
        --arg git_token "$GIT_TOKEN" \
        --arg repo_url "$REPO_URL" \
        --arg repo_host_ip "$REPO_HOST_IP" \
        --arg registry_mode "${REGISTRY_MODE:-bundled}" \
        --arg app_registry_url "${APP_REGISTRY_URL:-$DEFAULT_APP_REGISTRY_URL}" \
        --arg node_group "$NODE_GROUP" \
        --arg node_admin "$NODE_ADMIN" \
        --arg node_admin_password_hash "${NODE_ADMIN_PASSWORD_HASH:-}" \
        --arg node_ssh_pub_key "$CONTROLLER_NODE_SSH_PUB_KEY" \
        --argjson node_ssh_pub_keys "$CONTROLLER_NODE_SSH_PUB_KEYS_JSON" \
        --arg node_role "${NODE_ROLE:-worker}" \
        --arg keepalived_role "${KEEPALIVED_ROLE:-backup}" \
        --arg installer_auth_mode "${INSTALLER_AUTH_MODE:-ssh_key}" \
        --arg installer_ssh_pub_key "${INSTALLER_SSH_PUB_KEY:-}" \
        --argjson ssh_password_auth "${SSH_PASSWORD_AUTH:-false}" \
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
         .registry_mode = $registry_mode |
         .app_registry_url = $app_registry_url |
         .module_registry_url = $app_registry_url |
         .node_group = $node_group |
         .node_admin = $node_admin |
         .node_admin_pass = "" |
         .node_admin_password_hash = $node_admin_password_hash |
         .node_ssh_pub_key = $node_ssh_pub_key |
         .node_ssh_pub_keys = $node_ssh_pub_keys |
         .ssh_password_auth = $ssh_password_auth |
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
        "$NIX_CLUSTER_CONFIG_TEMPLATE_SRC" > "$NIX_CLUSTER_CONFIG_TEMPLATE_TMP"
    rm -f "$NIX_CLUSTER_CONFIG_TEMPLATE_SRC"
    sudo mv "$NIX_CLUSTER_CONFIG_TEMPLATE_TMP" "$CONFIG_TEMPLATE_PATH"
    sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_TEMPLATE_PATH"
    sudo chmod 0644 "$CONFIG_TEMPLATE_PATH"

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
                --arg node_admin_password_hash "${NODE_ADMIN_PASSWORD_HASH:-}" \
                --arg fs "$CONTROLLER_ROOT_FS" \
                --arg installer_auth_mode "${INSTALLER_AUTH_MODE:-ssh_key}" \
                --arg installer_ssh_pub_key "${INSTALLER_SSH_PUB_KEY:-}" \
                --argjson ssh_password_auth "${SSH_PASSWORD_AUTH:-false}" \
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
                         installer_mode: "default",
                         installer_script: "",
                         installer_pre_script: "",
                         installer_post_script: "",
                         disk: "",
                         fs: $fs,
                         node_group: $node_group,
                         node_role: $node_role,
                         keepalived_role: $keepalived_role,
                         node_admin: $node_admin,
                         ssh_password_auth: $ssh_password_auth,
                         node_admin_pass: "",
                         node_admin_password_hash: $node_admin_password_hash
                     }]
                 end' \
                "$CONTROLLER_DEPLOYMENTS_SRC" > "$CONTROLLER_DEPLOYMENTS_TMP"

        rm -f "$CONTROLLER_DEPLOYMENTS_SRC"
        sudo mv "$CONTROLLER_DEPLOYMENTS_TMP" "$TARGET_DIR/deployments.json"
        sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$TARGET_DIR/deployments.json"
        sudo chmod 0644 "$TARGET_DIR/deployments.json"
        hydrate_deployments_from_runtime_workers "$TARGET_DIR/deployments.json"
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
    sudo -u "$SERVICE_USER" mkdir -p "$GROUP_DIR"

    if [ -n "$CUSTOM_GROUP_CONFIG" ]; then
        log "Using custom group configuration.nix from $CUSTOM_GROUP_CONFIG"
        sudo -u "$SERVICE_USER" cp --no-preserve=mode "$CUSTOM_GROUP_CONFIG" "$GROUP_DIR/configuration.nix"
    else
        echo "{ config, pkgs, ... }: {
  # Group-level NixOS options for the $NODE_GROUP tier.
}" | sudo -u "$SERVICE_USER" tee "$GROUP_DIR/configuration.nix" > /dev/null
    fi

    if [ -n "$CUSTOM_GROUP_IMPORTS" ]; then
        log "Using custom group imports.nix from $CUSTOM_GROUP_IMPORTS"
        sudo -u "$SERVICE_USER" cp --no-preserve=mode "$CUSTOM_GROUP_IMPORTS" "$GROUP_DIR/imports.nix"
    else
                if [ "${REGISTRY_MODE:-bundled}" = "registry" ]; then
            cat <<'EOF' | sudo -u "$SERVICE_USER" tee "$GROUP_DIR/imports.nix" > /dev/null
{ config, pkgs, inputs, ... }:

{
  imports = [
        inputs.appRegistry.nixosApps.official.caddy
        inputs.appRegistry.nixosApps.official.cloudflared
        inputs.appRegistry.nixosApps.official.postgresBackup
        inputs.appRegistry.nixosApps.official.keepalived
  ];
}
EOF
        else
            sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/imports.nix" "$GROUP_DIR/imports.nix"
        fi
    fi
    sudo -u "$SERVICE_USER" chmod -R u+w "$GROUP_DIR"
fi

if [ "${REGISTRY_MODE:-bundled}" != "registry" ]; then
    log "Ensuring standard app files exist..."
    sudo -u "$SERVICE_USER" mkdir -p "$TARGET_DIR/apps/caddy" "$TARGET_DIR/apps/cloudflare" "$TARGET_DIR/apps/backup" "$TARGET_DIR/apps/ingress" "$TARGET_DIR/apps/pxe"
    for module_spec in \
        "caddy/caddy.nix:caddy.nix" \
        "cloudflare/cloudflared.nix:cloudflared.nix" \
        "backup/postgres.nix:postgres-backup.nix" \
        "ingress/keepalived.nix:keepalived.nix" \
        "pxe/pxe.nix:pxe.nix"
    do
        module_target="${module_spec%%:*}"
        module_template="${module_spec##*:}"
        if [ ! -f "$TARGET_DIR/apps/$module_target" ]; then
            sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/$module_template" "$TARGET_DIR/apps/$module_target"
            sudo -u "$SERVICE_USER" chmod u+w "$TARGET_DIR/apps/$module_target"
        fi
    done
fi

# Scaffolds a base Caddy module when enabled so generated fleets have a shared reverse proxy layer.
if [ "${CADDY_ENABLE:-false}" = "true" ]; then
    log "Base Caddy reverse proxy enabled. Scaffolding module..."

    if [ "${REGISTRY_MODE:-bundled}" != "registry" ]; then
        CADDY_MODULE_DIR="$TARGET_DIR/apps/caddy"
        if [ ! -d "$CADDY_MODULE_DIR" ]; then
            sudo -u "$SERVICE_USER" mkdir -p "$CADDY_MODULE_DIR"
            sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/caddy.nix" "$CADDY_MODULE_DIR/caddy.nix"
            sudo -u "$SERVICE_USER" chmod u+w "$CADDY_MODULE_DIR/caddy.nix"
            log "Created apps/caddy/caddy.nix"
        fi
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

    if [ "${REGISTRY_MODE:-bundled}" != "registry" ]; then
        KEEPALIVED_MODULE_DIR="$TARGET_DIR/apps/ingress"
        if [ ! -d "$KEEPALIVED_MODULE_DIR" ]; then
            sudo -u "$SERVICE_USER" mkdir -p "$KEEPALIVED_MODULE_DIR"
        fi
        sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/keepalived.nix" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        sudo -u "$SERVICE_USER" chmod u+w "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_INTERFACE_PLACEHOLDER|${KEEPALIVED_INTERFACE}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        if [ "${KEEPALIVED_ROLE:-backup}" = "master" ] || [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
            KEEPALIVED_STATE="MASTER"
        else
            KEEPALIVED_STATE="BACKUP"
        fi
        sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_STATE_PLACEHOLDER|${KEEPALIVED_STATE}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_ROUTER_ID_PLACEHOLDER|${KEEPALIVED_ROUTER_ID}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_PRIORITY_PLACEHOLDER|${KEEPALIVED_PRIORITY}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_VIP_CIDR_PLACEHOLDER|${KEEPALIVED_VIP_CIDR}|" "$KEEPALIVED_MODULE_DIR/keepalived.nix"
        log "Created apps/ingress/keepalived.nix (interface: $KEEPALIVED_INTERFACE, vip: $KEEPALIVED_VIP_CIDR)"
    fi
fi

# Scaffolds a PostgreSQL backup module for the controller bootstrap node.
if [ "${IS_BOOTSTRAP:-false}" = "true" ]; then
    log "PostgreSQL backup support enabled. Scaffolding module..."

    if [ "${REGISTRY_MODE:-bundled}" != "registry" ]; then
        POSTGRES_BACKUP_MODULE_DIR="$TARGET_DIR/apps/backup"
        if [ ! -d "$POSTGRES_BACKUP_MODULE_DIR" ]; then
            sudo -u "$SERVICE_USER" mkdir -p "$POSTGRES_BACKUP_MODULE_DIR"
        fi
        sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/postgres-backup.nix" "$POSTGRES_BACKUP_MODULE_DIR/postgres.nix"
        sudo -u "$SERVICE_USER" chmod u+w "$POSTGRES_BACKUP_MODULE_DIR/postgres.nix"
    fi

fi

# Scaffolds Cloudflare tunnel module and Terraform config when the tunnel option is enabled.
if [ "${CF_TUNNEL:-false}" = "true" ]; then
    log "Cloudflare Tunnel enabled. Scaffolding modules..."

    if [ "${REGISTRY_MODE:-bundled}" != "registry" ]; then
        # Create cloudflared NixOS module
        CF_MODULE_DIR="$TARGET_DIR/apps/cloudflare"
        if [ ! -d "$CF_MODULE_DIR" ]; then
            sudo -u "$SERVICE_USER" mkdir -p "$CF_MODULE_DIR"
            sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/cloudflared.nix" "$CF_MODULE_DIR/cloudflared.nix"
            sudo -u "$SERVICE_USER" chmod u+w "$CF_MODULE_DIR/cloudflared.nix"
            log "Created apps/cloudflare/cloudflared.nix"
        fi
    fi

    # Create Terraform config with substituted values
    TF_MODULE_DIR="$TARGET_DIR/apps/terraform"
    if [ ! -d "$TF_MODULE_DIR" ]; then
        sudo -u "$SERVICE_USER" mkdir -p "$TF_MODULE_DIR"
        sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/main.tf" "$TF_MODULE_DIR/main.tf"
        sudo -u "$SERVICE_USER" chmod u+w "$TF_MODULE_DIR/main.tf"
        sudo -u "$SERVICE_USER" sed -i "s|TUNNEL_NAME_PLACEHOLDER|${CF_TUNNEL_NAME}|" "$TF_MODULE_DIR/main.tf"
        sudo -u "$SERVICE_USER" sed -i "s|TUNNEL_DOMAIN_PLACEHOLDER|${CF_TUNNEL_DOMAIN}|" "$TF_MODULE_DIR/main.tf"
        sudo -u "$SERVICE_USER" sed -i "s|VIP_ADDRESS_PLACEHOLDER|${CF_TUNNEL_VIP}|" "$TF_MODULE_DIR/main.tf"
        log "Created apps/terraform/main.tf (tunnel: $CF_TUNNEL_NAME, domain: $CF_TUNNEL_DOMAIN, vip: $CF_TUNNEL_VIP)"
    fi

fi

NODE_DIR="$TARGET_DIR/nodes/$HOSTNAME"
log "Creating node directory at $NODE_DIR linked to group '$NODE_GROUP'..."
sudo -u "$SERVICE_USER" mkdir -p "$NODE_DIR"

PRESERVE_PREFAB_NODE_DIR="false"
if [ "${PRESERVE_EXISTING_NODE_FILES:-false}" = "true" ] && [ -d "$NODE_DIR" ]; then
    PRESERVE_PREFAB_NODE_DIR="true"
    log "Prefab node directory detected. Existing node files will be preserved when present."
fi

if [ "$PRESERVE_PREFAB_NODE_DIR" = "true" ] && [ -f "$NODE_DIR/configuration.nix" ]; then
    log "Preserving existing node configuration.nix in $NODE_DIR"
elif [ -n "$CUSTOM_NODE_CONFIG" ]; then
    log "Using custom node configuration.nix from $CUSTOM_NODE_CONFIG"
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$CUSTOM_NODE_CONFIG" "$NODE_DIR/configuration.nix"
else
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/configuration.nix" "$NODE_DIR/configuration.nix"
fi

if [ "$PRESERVE_PREFAB_NODE_DIR" = "true" ] && [ -f "$NODE_DIR/controllerScript-autoprovision.sh" ]; then
    log "Preserving existing controllerScript-autoprovision.sh in $NODE_DIR"
else
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/controllerScript-autoprovision.sh" "$NODE_DIR/controllerScript-autoprovision.sh"
    sudo -u "$SERVICE_USER" chmod u+w "$NODE_DIR/controllerScript-autoprovision.sh"
    if [ -n "${NIXOS_INSTALL_REPO_URL:-}" ]; then
        NIXOS_INSTALL_FLAKE_URL="$(normalize_tarball_flake_url "$NIXOS_INSTALL_REPO_URL")"
        sudo -u "$SERVICE_USER" sed -i "s|NIXOS_INSTALL_REPO_URL_PLACEHOLDER|${NIXOS_INSTALL_FLAKE_URL}|" "$NODE_DIR/controllerScript-autoprovision.sh"
    fi
    if [ -n "${NIX_CLUSTER_REPO_URL:-}" ]; then
        NIX_CLUSTER_INSTALL_FLAKE_URL="$(normalize_git_flake_url "$NIX_CLUSTER_REPO_URL")"
        sudo -u "$SERVICE_USER" sed -i "s|git+NIX_CLUSTER_INSTALL_REPO_URL_PLACEHOLDER|${NIX_CLUSTER_INSTALL_FLAKE_URL}|" "$NODE_DIR/controllerScript-autoprovision.sh"
    fi
fi


# Generate the node's imports.nix with conditional module imports
IMPORTS_FILE="$NODE_DIR/imports.nix"
if [ "$PRESERVE_PREFAB_NODE_DIR" = "true" ] && [ -f "$IMPORTS_FILE" ]; then
    log "Preserving existing imports.nix in $NODE_DIR"
elif [ -n "$CUSTOM_NODE_IMPORTS" ]; then
    log "Using custom node imports.nix from $CUSTOM_NODE_IMPORTS"
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$CUSTOM_NODE_IMPORTS" "$IMPORTS_FILE"
else
    echo "{ config, pkgs, inputs, ... }: { imports = [" > "$IMPORTS_FILE"
    echo "  ../../groups/$NODE_GROUP/configuration.nix" >> "$IMPORTS_FILE"
    echo "  ../../groups/$NODE_GROUP/imports.nix" >> "$IMPORTS_FILE"
    if [ "${REGISTRY_MODE:-bundled}" = "registry" ]; then
        echo "  inputs.appRegistry.nixosApps.official.pxe" >> "$IMPORTS_FILE"
    else
        echo "  ../../apps/pxe/pxe.nix" >> "$IMPORTS_FILE"
    fi
    if [ "$IS_BOOTSTRAP" = "true" ]; then
        echo "  ../../apps/forgejo/forgejo.nix" >> "$IMPORTS_FILE"
    fi
    echo "];}" >> "$IMPORTS_FILE"
fi
    sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$IMPORTS_FILE"
sudo chmod u+w "$IMPORTS_FILE"

if [ "$PRESERVE_PREFAB_NODE_DIR" = "true" ] && [ -f "$NODE_DIR/hardware-configuration.nix" ]; then
    log "Preserving existing hardware-configuration.nix in $NODE_DIR"
elif [ -f "/etc/nixos/hardware-configuration.nix" ]; then
    sudo cp /etc/nixos/hardware-configuration.nix "$NODE_DIR/hardware-configuration.nix"
        sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$NODE_DIR/hardware-configuration.nix"
elif command -v nixos-generate-config >/dev/null 2>&1; then
    log "Generating hardware-configuration.nix from the current system..."
    sudo nixos-generate-config --show-hardware-config | sudo tee "$NODE_DIR/hardware-configuration.nix" >/dev/null
    sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$NODE_DIR/hardware-configuration.nix"
fi

# Substitutes installer-collected values into the node config: hostname, admin user, repo path, and trigger mode.
log "Hydrating node configuration..."
HOST_ID=$(head -c 4 /dev/urandom | od -A n -t x4 | tr -d ' ' | cut -c 1-8)
case "${NODE_ROLE:-worker}" in
    controller)
        HA_ROLE="active"
        ;;
    spare)
        HA_ROLE="spare"
        ;;
    *)
        HA_ROLE="passive"
        ;;
esac
if [ "${KEEPALIVED_ENABLE:-false}" = "true" ]; then
    PLACEMENT_KEEPALIVED_ROLE="${KEEPALIVED_ROLE:-backup}"
else
    PLACEMENT_KEEPALIVED_ROLE="disabled"
fi
if [ "$PRESERVE_PREFAB_NODE_DIR" = "true" ] && [ -f "$NODE_DIR/configuration.nix" ]; then
    log "Skipping placeholder hydration for preserved node configuration.nix"
else
sudo -u "$SERVICE_USER" sed -i "s|HOST_ID_PLACEHOLDER|$HOST_ID|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|networking.hostName = \".*\";|networking.hostName = \"$HOSTNAME\";|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|users.users.tdavis|users.users.$NODE_ADMIN|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|NODE_ADMIN_PLACEHOLDER|$NODE_ADMIN|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|repoPath = \".*\";|repoPath = \"$TARGET_DIR\";|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|SSH_PASSWORD_AUTH_PLACEHOLDER|${SSH_PASSWORD_AUTH:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|NODE_ROLE_PLACEHOLDER|${NODE_ROLE:-worker}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|HA_ROLE_PLACEHOLDER|$HA_ROLE|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_ROLE_PLACEHOLDER|$PLACEMENT_KEEPALIVED_ROLE|" "$NODE_DIR/configuration.nix"

if [ -n "${NODE_ADMIN_PASSWORD_HASH:-}" ]; then
    SAFE_NODE_ADMIN_PASSWORD_HASH=$(nix_cluster_escape_sed "$NODE_ADMIN_PASSWORD_HASH")
    sudo -u "$SERVICE_USER" sed -i "s|ADMIN_PASSWORD_CONFIG_PLACEHOLDER|hashedPassword = \"$SAFE_NODE_ADMIN_PASSWORD_HASH\";|" "$NODE_DIR/configuration.nix"
else
    sudo -u "$SERVICE_USER" sed -i 's|ADMIN_PASSWORD_CONFIG_PLACEHOLDER|hashedPassword = "!";|' "$NODE_DIR/configuration.nix"
fi

SSH_KEYS_NIX_EXPR=$(jq -r 'if length == 0 then "" else "openssh.authorizedKeys.keys = [ " + (map(@json) | join(" ")) + " ];" end' <<< "$NODE_SSH_PUB_KEYS_JSON")
if [ -n "$SSH_KEYS_NIX_EXPR" ]; then
    SAFE_SSH_KEYS_EXPR=$(nix_cluster_escape_sed "$SSH_KEYS_NIX_EXPR")
    sudo -u "$SERVICE_USER" sed -i "s|SSH_PUB_KEYS_PLACEHOLDER|$SAFE_SSH_KEYS_EXPR|" "$NODE_DIR/configuration.nix"
else
    sudo -u "$SERVICE_USER" sed -i "/SSH_PUB_KEYS_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
fi

SAFE_CONTROLLER_PXE_KEY=$(nix_cluster_escape_sed "$CONTROLLER_NODE_SSH_PUB_KEY")
sudo -u "$SERVICE_USER" sed -i "s|PXE_AUTHORIZED_KEYS_PLACEHOLDER|[ \"$SAFE_CONTROLLER_PXE_KEY\" ]|" "$NODE_DIR/configuration.nix"

if [ "$TRIGGER_CHOICE" == "2" ]; then
    sudo -u "$SERVICE_USER" sed -i "s|MATRIX_ENABLE_PLACEHOLDER|false|" "$NODE_DIR/configuration.nix"
    sudo -u "$SERVICE_USER" sed -i "s|WEBHOOK_ENABLE_PLACEHOLDER|true|" "$NODE_DIR/configuration.nix"
else
    sudo -u "$SERVICE_USER" sed -i "s|MATRIX_ENABLE_PLACEHOLDER|true|" "$NODE_DIR/configuration.nix"
    sudo -u "$SERVICE_USER" sed -i "s|WEBHOOK_ENABLE_PLACEHOLDER|false|" "$NODE_DIR/configuration.nix"
fi

sudo -u "$SERVICE_USER" sed -i "s|IS_CONTROLLER_PLACEHOLDER|${IS_CONTROLLER:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CADDY_ENABLE_PLACEHOLDER|${CADDY_ENABLE:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_ENABLE_PLACEHOLDER|${KEEPALIVED_ENABLE:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_INTERFACE_PLACEHOLDER|$(nix_cluster_escape_sed "${KEEPALIVED_INTERFACE:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_ROUTER_ID_PLACEHOLDER|${KEEPALIVED_ROUTER_ID:-51}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_PRIORITY_PLACEHOLDER|${KEEPALIVED_PRIORITY:-100}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|KEEPALIVED_VIP_CIDR_PLACEHOLDER|$(nix_cluster_escape_sed "${KEEPALIVED_VIP_CIDR:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_ENABLE_PLACEHOLDER|${CF_TUNNEL:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_TUNNEL_ENABLE_PLACEHOLDER|${CF_TUNNEL:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_TUNNEL_NAME_PLACEHOLDER|$(nix_cluster_escape_sed "${CF_TUNNEL_NAME:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_TUNNEL_DOMAIN_PLACEHOLDER|$(nix_cluster_escape_sed "${CF_TUNNEL_DOMAIN:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_TUNNEL_VIP_PLACEHOLDER|$(nix_cluster_escape_sed "${CF_TUNNEL_VIP:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_ZONE_ID_PLACEHOLDER|$(nix_cluster_escape_sed "${CF_ZONE_ID:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|CLOUDFLARE_ACCOUNT_ID_PLACEHOLDER|$(nix_cluster_escape_sed "${CF_ACCOUNT_ID:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|PXE_ENABLE_PLACEHOLDER|${PXE_ENABLE:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|PXE_DHCP_ENABLE_PLACEHOLDER|${PXE_DHCP_ENABLE:-false}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|PXE_INTERFACE_PLACEHOLDER|$(nix_cluster_escape_sed "${PXE_INTERFACE:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|PXE_HTTP_PORT_PLACEHOLDER|${PXE_HTTP_PORT:-8081}|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|PXE_BOOT_URL_PLACEHOLDER|$(nix_cluster_escape_sed "${PXE_BOOT_URL:-}")|" "$NODE_DIR/configuration.nix"
sudo -u "$SERVICE_USER" sed -i "s|POSTGRES_BACKUP_ENABLE_PLACEHOLDER|${POSTGRES_BACKUP_ENABLE:-false}|" "$NODE_DIR/configuration.nix"

# Dynamically scaffold Forgejo module if this is the bootstrap node
if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Scaffolding Forgejo module..."
    FORGEJO_MODULE_DIR="$TARGET_DIR/apps/forgejo"
    sudo -u "$SERVICE_USER" mkdir -p "$FORGEJO_MODULE_DIR"
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
    sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$FORGEJO_FILE"
    sudo chmod 0644 "$FORGEJO_FILE"
    rm -f /tmp/forgejo.nix
    
    sudo -u "$SERVICE_USER" sed -i "/FORGEJO_CONFIG_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
    sudo -u "$SERVICE_USER" sed -i "s|FIREWALL_FORGEJO_PLACEHOLDER|3000|" "$NODE_DIR/configuration.nix"
    # Prepend forgejo into the existing package array so there's no duplicate systemPackages block.
    sudo -u "$SERVICE_USER" sed -i "s|CONTROLLER_PACKAGES_PLACEHOLDER|forgejo CONTROLLER_PACKAGES_PLACEHOLDER|" "$NODE_DIR/configuration.nix"
else
    # Delete the Forgejo placeholder line entirely so Nix doesn't crash
    sudo -u "$SERVICE_USER" sed -i "/FORGEJO_CONFIG_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
    # Cleanly strip the firewall placeholder (including the leading space)
    sudo -u "$SERVICE_USER" sed -i "s| FIREWALL_FORGEJO_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
    # Fallback strip just in case
    sudo -u "$SERVICE_USER" sed -i "s|FIREWALL_FORGEJO_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
fi

# Inject allowUnfree and Terraform on controller nodes; cleanly remove placeholders on agents.
if [ "${IS_CONTROLLER:-false}" = "true" ]; then
    sudo -u "$SERVICE_USER" sed -i "s|ALLOW_UNFREE_PLACEHOLDER|nixpkgs.config.allowUnfree = true;|" "$NODE_DIR/configuration.nix"
    sudo -u "$SERVICE_USER" sed -i "s|CONTROLLER_PACKAGES_PLACEHOLDER|terraform|" "$NODE_DIR/configuration.nix"
else
    sudo -u "$SERVICE_USER" sed -i "/ALLOW_UNFREE_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
    sudo -u "$SERVICE_USER" sed -i "s| CONTROLLER_PACKAGES_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
    sudo -u "$SERVICE_USER" sed -i "s|CONTROLLER_PACKAGES_PLACEHOLDER||" "$NODE_DIR/configuration.nix"
fi
fi

# Inject Cloudflare tunnel Terraform provisioning into the controller script when enabled.
if [ "${CF_TUNNEL:-false}" = "true" ] && [ "${IS_CONTROLLER:-false}" = "true" ]; then
    log "Injecting Cloudflare tunnel provisioning into controller script..."
    CF_SCRIPT=$(cat <<'CFEOF'
          if [ -d "apps/terraform" ]; then
          echo "[NIX-CLUSTER] === Cloudflare Tunnel Provisioning ==="
          export TF_VAR_cloudflare_api_token=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_api_token"]' secrets/secrets.yaml)
          export TF_VAR_tunnel_name=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_name"]' secrets/secrets.yaml)
          export TF_VAR_tunnel_domain=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_tunnel_domain"]' secrets/secrets.yaml)
          export TF_VAR_cloudflare_account_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_account_id"]' secrets/secrets.yaml)
          export TF_VAR_cloudflare_zone_id=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d --extract '["cloudflare_zone_id"]' secrets/secrets.yaml)
          echo "[NIX-CLUSTER] Tunnel name: $TF_VAR_tunnel_name"
          echo "[NIX-CLUSTER] Tunnel domain: $TF_VAR_tunnel_domain"
              cd apps/terraform
          echo "[NIX-CLUSTER] Running terraform init..."
          terraform init -input=false
          echo "[NIX-CLUSTER] Running terraform plan..."
          terraform plan -input=false -out=tfplan 2>&1 | tee /tmp/tf-plan.log
          PLAN_EXIT=$?
          if [ $PLAN_EXIT -ne 0 ]; then
              echo "[NIX-CLUSTER] ERROR: terraform plan failed (exit $PLAN_EXIT)."
              cd ../..
          else
              echo "[NIX-CLUSTER] Running terraform apply..."
              terraform apply -input=false tfplan 2>&1 | tee /tmp/tf-apply.log
              APPLY_EXIT=$?
              rm -f tfplan
              if [ $APPLY_EXIT -ne 0 ]; then
                  echo "[NIX-CLUSTER] ERROR: terraform apply failed (exit $APPLY_EXIT)."
                  cd ../..
              else
                  echo "[NIX-CLUSTER] Terraform apply succeeded."
                  echo "[NIX-CLUSTER] Tunnel ID: $(terraform output -raw tunnel_id 2>/dev/null || echo 'N/A')"
                  echo "[NIX-CLUSTER] Tunnel Name: $(terraform output -raw tunnel_name 2>/dev/null || echo 'N/A')"
                  TOKEN=$(terraform output -raw tunnel_token)
                  cd ../..
                  if [ -n "$TOKEN" ] && [[ "$TOKEN" != *"No outputs found" ]] && ! sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops -d secrets/secrets.yaml | grep -q "$TOKEN"; then
                      echo "[NIX-CLUSTER] Tunnel token changed — updating SOPS..."
                      JSON_TOKEN=$(jq -Rn --arg value "$TOKEN" '$value')
                      sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops --set "[\"cloudflare_tunnel_token\"] $JSON_TOKEN" secrets/secrets.yaml
                      git add secrets/secrets.yaml
                      git commit -m "chore: update CF tunnel token [skip nix-cluster]"
                      git push
                  else
                      echo "[NIX-CLUSTER] Tunnel token unchanged — no update needed."
                  fi
              fi
          fi
      else
          echo "[NIX-CLUSTER] Terraform directory not present. Skipping tunnel provisioning."
      fi
CFEOF
)
    # Write the controller script block to a temp file and use sed to replace the placeholder
    CF_SCRIPT_FILE=$(mktemp)
    echo "$CF_SCRIPT" > "$CF_SCRIPT_FILE"
    sudo chown "$SERVICE_USER:$SERVICE_GROUP" "$CF_SCRIPT_FILE"
    sudo chmod 0644 "$CF_SCRIPT_FILE"
    sudo -u "$SERVICE_USER" sed -i "/CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER/{
        r $CF_SCRIPT_FILE
        d
    }" "$NODE_DIR/configuration.nix"
    rm -f "$CF_SCRIPT_FILE"
else
    sudo -u "$SERVICE_USER" sed -i "/CLOUDFLARE_CONTROLLER_SCRIPT_PLACEHOLDER/d" "$NODE_DIR/configuration.nix"
fi

# Adds this node's age public key to .sops.yaml and injects its nixosConfiguration into flake.nix via NODES_MARKER.
SOPS_CONFIG="$TARGET_DIR/.sops.yaml"
SECRETS_FILE="$TARGET_DIR/secrets/secrets.yaml"

log "Updating Fleet SOPS configuration..."
if [ ! -f "$SOPS_CONFIG" ]; then
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/.sops.yaml" "$SOPS_CONFIG"
    sudo -u "$SERVICE_USER" chmod u+w "$SOPS_CONFIG"
fi

if ! grep -q "$PUB_KEY" "$SOPS_CONFIG"; then
    log "Adding public key to SOPS config..."
    sudo -u "$SERVICE_USER" sed -i "s|AGE_PUBLIC_KEY_PLACEHOLDER|$PUB_KEY|g" "$SOPS_CONFIG"
fi

log "Adding node to Fleet flake.nix..."
if ! grep -q "nixosConfigurations.$HOSTNAME" "$TARGET_DIR/flake.nix"; then
    sudo -u "$SERVICE_USER" sed -i "/# NODES_MARKER/a \    nixosConfigurations.$HOSTNAME = nixpkgs.lib.nixosSystem { system = \"x86_64-linux\"; specialArgs = { inherit inputs; }; modules = [ ./nodes/$HOSTNAME/configuration.nix nixCluster.nixosModules.default ]; };" "$TARGET_DIR/flake.nix"
else
    log "Node $HOSTNAME already exists in flake.nix. Skipping insertion."
fi

# Creates and SOPS-encrypts secrets.yaml on first enrollment; updates SOPS keys on subsequent runs.
if [ ! -f "$SECRETS_FILE" ]; then
    log "Initializing global secrets file..."
    sudo -u "$SERVICE_USER" mkdir -p "$(dirname "$SECRETS_FILE")"
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/secrets.yaml" "$SECRETS_FILE"

    # Escapes &, /, and \ so they are treated as literals in sed replacement strings.
    escape_sed() { echo "$1" | sed 's/[&/\]/\\&/g'; }

    sudo -u "$SERVICE_USER" sed -i "s|git_username:.*|git_username: \"$(escape_sed "$GIT_USER")\"|" "$SECRETS_FILE"
    sudo -u "$SERVICE_USER" sed -i "s|git_password:.*|git_password: \"$(escape_sed "$GIT_TOKEN")\"|" "$SECRETS_FILE"

    # Pre-populate CF tunnel fields collected during prompts so they appear in the editor
    if [ "${CF_TUNNEL:-false}" = "true" ]; then
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_tunnel_name:.*|cloudflare_tunnel_name: \"$(escape_sed "$CF_TUNNEL_NAME")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_tunnel_domain:.*|cloudflare_tunnel_domain: \"$(escape_sed "$CF_TUNNEL_DOMAIN")\"|" "$SECRETS_FILE"
    fi

    if [ "$NON_INTERACTIVE" = true ]; then
        log "Injecting secrets from config file..."
        sudo -u "$SERVICE_USER" sed -i "s|matrix_bot_token:.*|matrix_bot_token: \"$(escape_sed "$MATRIX_BOT_TOKEN")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|matrix_room_id:.*|matrix_room_id: \"$(escape_sed "$MATRIX_ROOM_ID")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|matrix_homeserver:.*|matrix_homeserver: \"$(escape_sed "$MATRIX_HOMESERVER")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|webhook_secret:.*|webhook_secret: \"$(escape_sed "$WEBHOOK_SECRET")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_api_token:.*|cloudflare_api_token: \"$(escape_sed "$CF_API_TOKEN")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_tunnel_name:.*|cloudflare_tunnel_name: \"$(escape_sed "$CF_TUNNEL_NAME")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_tunnel_domain:.*|cloudflare_tunnel_domain: \"$(escape_sed "$CF_TUNNEL_DOMAIN")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_zone_id:.*|cloudflare_zone_id: \"$(escape_sed "$CF_ZONE_ID")\"|" "$SECRETS_FILE"
        sudo -u "$SERVICE_USER" sed -i "s|cloudflare_account_id:.*|cloudflare_account_id: \"$(escape_sed "$CF_ACCOUNT_ID")\"|" "$SECRETS_FILE"
    else
        log "Opening secrets/secrets.yaml for Matrix setup..."
        read -p "Press Enter to open editor (Ensure Matrix credentials are set)..."
        sudo -u "$SERVICE_USER" vim "$SECRETS_FILE"
    fi

    sudo -u "$SERVICE_USER" sops --config "$SOPS_CONFIG" --encrypt --in-place "$SECRETS_FILE"
else
    log "Global secrets file exists. Attempting key update..."
    if ! sudo -u "$SERVICE_USER" sops updatekeys -y "$SECRETS_FILE" 2>/dev/null; then
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

    PXE_MODULE_DIR="$TARGET_DIR/apps/pxe"
    if [ ! -d "$PXE_MODULE_DIR" ]; then
        sudo -u "$SERVICE_USER" mkdir -p "$PXE_MODULE_DIR"
    fi
    sudo -u "$SERVICE_USER" cp --no-preserve=mode "$TEMPLATES_DIR/pxe.nix" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u "$SERVICE_USER" chmod u+w "$PXE_MODULE_DIR/pxe.nix"
    sudo -u "$SERVICE_USER" sed -i "s|PXE_INTERFACE_PLACEHOLDER|${PXE_INTERFACE:-}|" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u "$SERVICE_USER" sed -i "s|PXE_HTTP_PORT_PLACEHOLDER|${PXE_HTTP_PORT:-8081}|" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u "$SERVICE_USER" sed -i "s|PXE_BOOT_URL_PLACEHOLDER|${PXE_BOOT_URL:-}|" "$PXE_MODULE_DIR/pxe.nix"
    sudo -u "$SERVICE_USER" sed -i "s|PXE_DHCP_ENABLE_PLACEHOLDER|${PXE_DHCP_ENABLE:-false}|" "$PXE_MODULE_DIR/pxe.nix"
fi

log "Ensuring encrypted repository provisioning metadata..."
sync_encrypted_json_file "$TARGET_DIR/deployments.json"
sync_encrypted_json_file "$CONFIG_TEMPLATE_PATH"

# Opens the node config in an editor before committing, allowing manual adjustments such as static IP.
if [ "$NON_INTERACTIVE" != true ]; then
    log "Opening node configuration for manual adjustments (e.g., networking, static IP)..."
    read -p "Press Enter to open editor ($NODE_DIR/configuration.nix)..."
    sudo -u "$SERVICE_USER" vim "$NODE_DIR/configuration.nix"
else
    log "Skipping manual node configuration (Non-interactive mode)."
fi


# Commits all scaffolded files. Defers push if running in bootstrap mode.
log "Committing enrollment to Fleet repository..."
sudo -u "$SERVICE_USER" git config user.email "nix-cluster-installer@$HOSTNAME"
sudo -u "$SERVICE_USER" git config user.name "nix-cluster Installer"
sudo -u "$SERVICE_USER" git add .
sudo -u "$SERVICE_USER" git commit -m "Enrollment: $HOSTNAME (Group: $NODE_GROUP)" || log "No changes to commit."

if [ "$IS_BOOTSTRAP" = "true" ]; then
    log "Bootstrap mode: Deferring git push until Forgejo is online."
else
    log "Pushing enrollment to Fleet repository..."
    sudo -u "$SERVICE_USER" env GIT_CONFIG_NOSYSTEM=1 git push origin main
    log "Hardening Git security..."
    sudo -u "$SERVICE_USER" git remote set-url origin "$REPO_URL"
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
    REPO_CREATE_STATUS=$(curl -sS --max-time 20 -o /tmp/nix-cluster-forgejo-create.log -w "%{http_code}" -X POST "http://localhost:3000/api/v1/user/repos" \
         -H "Content-Type: application/json" \
         -u "$GIT_USER:$GIT_TOKEN" \
         -d "{\"name\": \"$REPO_NAME\", \"private\": true}")
    REPO_CREATE_EXIT=$?
    set -e

    if [ "$REPO_CREATE_EXIT" -ne 0 ]; then
        warn "Forgejo repository API call failed with exit code $REPO_CREATE_EXIT."
        if [ -f /tmp/nix-cluster-forgejo-create.log ]; then
            log "Forgejo repository API response body:"
            cat /tmp/nix-cluster-forgejo-create.log || true
        fi
        log_unit_diagnostics forgejo
        exit 1
    fi

    log "Forgejo repository API response: HTTP $REPO_CREATE_STATUS"
    if [ -f /tmp/nix-cluster-forgejo-create.log ]; then
        log "Forgejo repository API response body:"
        cat /tmp/nix-cluster-forgejo-create.log || true
    fi

    if [ "$REPO_CREATE_STATUS" != "201" ] && [ "$REPO_CREATE_STATUS" != "409" ]; then
        warn "Unexpected Forgejo repository API status: HTTP $REPO_CREATE_STATUS"
        log_unit_diagnostics forgejo
        exit 1
    fi

    log "Creating nix-cluster automation webhook via Forgejo API..."
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

    HOOK_STATUS=$(curl -sS --max-time 20 -o /tmp/nix-cluster-hook.log -w "%{http_code}" -X POST "http://localhost:3000/api/v1/repos/$GIT_USER/$REPO_NAME/hooks" \
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
    sudo -u "$SERVICE_USER" git remote set-url origin "http://$GIT_USER:$ENCODED_TOKEN@localhost:3000/$GIT_USER/$REPO_NAME.git"

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
    sudo -u "$SERVICE_USER" env GIT_CONFIG_NOSYSTEM=1 git push -u --force origin main
    log "Bootstrap repository push succeeded."

    if [ "${CF_TUNNEL:-false}" = "true" ] && [ "${IS_CONTROLLER:-false}" = "true" ]; then
        log "Running final rebuild to ensure cloudflared is active after the repo push..."
        sudo NIXPKGS_ALLOW_UNFREE=1 nixos-rebuild switch --flake "$TARGET_DIR#$HOSTNAME" --impure || warn "Final rebuild failed after bootstrap push."
    fi

    log "Restoring bootstrap repository remote to configured shared URL..."
    sudo -u "$SERVICE_USER" git remote set-url origin "$REPO_URL"
    
    log "Bootstrap Complete. Fleet repository is now live at $REPO_URL"
fi

success_banner "[SUCCESS] NODE JOINED: ${HOSTNAME} role=${NODE_ROLE:-worker} repo=${REPO_URL}"
echo -e "${GREEN}[SUCCESS]${NC} Enrollment complete."