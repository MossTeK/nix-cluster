#!/usr/bin/env bash

set -u

CONFIG_FILE="${1:-$HOME/nops-config.json}"
FLEET_DIR="${FLEET_DIR:-/home/nops/homelab-fleet}"
SOPS_KEY_FILE="${SOPS_KEY_FILE:-/var/lib/sops-nix/key.txt}"
FORGEJO_APP_INI="/var/lib/forgejo/custom/conf/app.ini"
FORGEJO_API="http://localhost:3000/api/healthz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILURES=0
WARNINGS=0

section() {
    printf "\n${BLUE}== %s ==${NC}\n" "$1"
}

pass() {
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

fail() {
    FAILURES=$((FAILURES + 1))
    printf "${RED}[FAIL]${NC} %s\n" "$1"
}

info() {
    printf "[INFO] %s\n" "$1"
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

have_systemd_unit() {
    sudo systemctl list-unit-files "$1" >/dev/null 2>&1
}

print_cmd_output() {
    local label="$1"
    shift

    info "$label"
    if ! "$@" 2>&1 | sed 's/^/    /'; then
        warn "$label failed"
    fi
}

print_shell_output() {
    local label="$1"
    local command_text="$2"

    info "$label"
    if ! sh -c "$command_text" 2>&1 | sed 's/^/    /'; then
        warn "$label failed"
    fi
}

json_value() {
    local query="$1"
    jq -r "$query // empty" "$CONFIG_FILE" 2>/dev/null
}

check_file_exists() {
    local path="$1"
    local label="$2"

    if [ -e "$path" ]; then
        pass "$label exists: $path"
    else
        fail "$label missing: $path"
    fi
}

check_dir_exists() {
    local path="$1"
    local label="$2"

    if [ -d "$path" ]; then
        pass "$label exists: $path"
    else
        fail "$label missing: $path"
    fi
}

check_user() {
    local user_name="$1"

    if id "$user_name" >/dev/null 2>&1; then
        pass "User present: $user_name"
    else
        fail "User missing: $user_name"
    fi
}

check_group() {
    local group_name="$1"

    if getent group "$group_name" >/dev/null 2>&1; then
        pass "Group present: $group_name"
    else
        fail "Group missing: $group_name"
    fi
}

check_json_field() {
    local field_name="$1"
    local value

    value=$(json_value ".${field_name}")
    if [ -n "$value" ] && [ "$value" != "null" ] && [ "$value" != "false" ]; then
        pass "Config field set: $field_name"
    else
        fail "Config field missing or empty: $field_name"
    fi
}

check_json_bool() {
    local field_name="$1"
    local value

    value=$(json_value ".${field_name}")
    if [ "$value" = "true" ] || [ "$value" = "false" ]; then
        pass "Config boolean set: $field_name=$value"
    else
        fail "Config boolean invalid: $field_name"
    fi
}

check_grep() {
    local pattern="$1"
    local file_path="$2"
    local label="$3"

    if [ -f "$file_path" ] && grep -Fq "$pattern" "$file_path"; then
        pass "$label"
    else
        fail "$label"
    fi
}

extract_secret_value() {
    local key_name="$1"

    if [ ! -f "$FLEET_DIR/secrets/secrets.yaml" ] || [ ! -f "$SOPS_KEY_FILE" ] || ! have_command sops; then
        return 1
    fi

    sudo env SOPS_AGE_KEY_FILE="$SOPS_KEY_FILE" sops -d --extract "[\"$key_name\"]" "$FLEET_DIR/secrets/secrets.yaml" 2>/dev/null || true
}

check_cloudflare_token() {
    local api_token="$1"

    if [ -z "$api_token" ]; then
        fail "Cloudflare API token unavailable for diagnostics"
        return 0
    fi

    local verify_response
    verify_response=$(curl -sS --max-time 20 \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null || true)

    if echo "$verify_response" | jq -e '.success == true' >/dev/null 2>&1; then
        pass "Cloudflare API token verified"
    else
        fail "Cloudflare API token verification failed"
        echo "$verify_response" | sed 's/^/    /'
    fi
}

check_cloudflare_account() {
    local api_token="$1"
    local account_id="$2"

    if [ -z "$api_token" ] || [ -z "$account_id" ]; then
        fail "Cloudflare account check skipped due to missing token or account id"
        return 0
    fi

    local response
    response=$(curl -sS --max-time 20 \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/accounts/$account_id" 2>/dev/null || true)

    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        pass "Cloudflare account id is valid"
    else
        fail "Cloudflare account id lookup failed"
        echo "$response" | sed 's/^/    /'
    fi
}

check_cloudflare_zone() {
    local api_token="$1"
    local zone_id="$2"
    local expected_domain="$3"

    if [ -z "$api_token" ] || [ -z "$zone_id" ]; then
        fail "Cloudflare zone check skipped due to missing token or zone id"
        return 0
    fi

    local response
    local zone_name
    response=$(curl -sS --max-time 20 \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$zone_id" 2>/dev/null || true)

    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        pass "Cloudflare zone id is valid"
        zone_name=$(echo "$response" | jq -r '.result.name // empty')
        if [ -n "$zone_name" ] && [ -n "$expected_domain" ]; then
            if [[ "$expected_domain" == "$zone_name" || "$expected_domain" == *".$zone_name" ]]; then
                pass "Tunnel domain matches Cloudflare zone: $zone_name"
            else
                warn "Tunnel domain '$expected_domain' does not appear to be inside zone '$zone_name'"
            fi
        fi
    else
        fail "Cloudflare zone id lookup failed"
        echo "$response" | sed 's/^/    /'
    fi
}

section "System"
info "Hostname: $(hostname)"
info "Date: $(date -Is)"
info "User: $(id -un)"
print_cmd_output "Kernel and OS" uname -a
print_cmd_output "Filesystem usage" df -h /
print_cmd_output "Boot filesystem usage" df -h /boot

section "Required Commands"
for cmd in jq curl git nix sudo systemctl; do
    if have_command "$cmd"; then
        pass "Command available: $cmd"
    else
        fail "Command missing: $cmd"
    fi
done

for cmd in sops age-keygen docker terraform; do
    if have_command "$cmd"; then
        pass "Optional command available: $cmd"
    else
        warn "Optional command missing: $cmd"
    fi
done

section "Bootstrap Users And Paths"
check_user "nops"
if id forgejo >/dev/null 2>&1; then
    pass "User present: forgejo"
else
    warn "User missing: forgejo"
fi
check_group "nops"
if getent group forgejo >/dev/null 2>&1; then
    pass "Group present: forgejo"
else
    warn "Group missing: forgejo"
fi
check_dir_exists "/home/nops" "nops home"
if [ -e "$SOPS_KEY_FILE" ]; then
    pass "SOPS Age key exists: $SOPS_KEY_FILE"
    print_cmd_output "SOPS key permissions" stat -c '%U:%G %a %n' "$SOPS_KEY_FILE"
else
    fail "SOPS Age key missing: $SOPS_KEY_FILE"
fi

section "Config JSON"
if [ -f "$CONFIG_FILE" ]; then
    pass "Config file present: $CONFIG_FILE"
else
    fail "Config file missing: $CONFIG_FILE"
fi

if [ -f "$CONFIG_FILE" ] && have_command jq; then
    check_json_bool "bootstrap_mode"
    check_json_bool "cloudflare_tunnel"
    check_json_field "git_user"
    check_json_field "git_token"
    check_json_field "repo_url"
    check_json_field "node_group"
    check_json_field "node_admin"
    check_json_field "node_admin_pass"

    if [ "$(json_value '.cloudflare_tunnel')" = "true" ]; then
        check_json_field "cloudflare_api_token"
        check_json_field "cloudflare_account_id"
        check_json_field "cloudflare_zone_id"
        check_json_field "cloudflare_tunnel_name"
        check_json_field "cloudflare_tunnel_domain"
        check_json_field "cloudflare_tunnel_vip"
    fi
fi

section "Cleanup Residue"
for path in /var/lib/forgejo /home/nops "$FLEET_DIR"; do
    if [ -e "$path" ]; then
        print_cmd_output "State path details for $path" sudo ls -ld "$path"
    else
        warn "State path not present: $path"
    fi
done

section "Generated Fleet Repository"
if [ -d "$FLEET_DIR" ]; then
    pass "Fleet directory exists: $FLEET_DIR"
    check_file_exists "$FLEET_DIR/flake.nix" "Fleet flake"
    check_file_exists "$FLEET_DIR/.sops.yaml" "Fleet SOPS config"
    check_file_exists "$FLEET_DIR/secrets/secrets.yaml" "Fleet encrypted secrets"
    check_file_exists "$FLEET_DIR/modules/terraform/main.tf" "Terraform module"
    check_file_exists "$FLEET_DIR/modules/cloudflare/cloudflared.nix" "Cloudflared module"

    if [ -f "$FLEET_DIR/flake.nix" ]; then
        print_cmd_output "Node entries in flake.nix" grep -n 'nixosConfigurations\.|NODES_MARKER' "$FLEET_DIR/flake.nix"
    fi

    if [ -d "$FLEET_DIR/nodes" ]; then
        print_cmd_output "Scaffolded node directories" find "$FLEET_DIR/nodes" -maxdepth 2 -type f | sort
    fi

    NODE_CONFIG=$(find "$FLEET_DIR/nodes" -mindepth 2 -maxdepth 2 -name configuration.nix 2>/dev/null | head -n 1)
    if [ -n "$NODE_CONFIG" ]; then
        pass "Node configuration found: $NODE_CONFIG"
        check_grep "services.forgejo = {" "$NODE_CONFIG" "Generated node config contains Forgejo service"
        check_grep "systemd.services.forgejo.preStart = lib.mkAfter ''" "$NODE_CONFIG" "Generated node config contains Forgejo preStart ownership fix"
        check_grep "Cloudflare Tunnel Provisioning" "$NODE_CONFIG" "Generated node config contains Cloudflare controller script"
        print_cmd_output "Generated node config excerpt" sed -n '1,220p' "$NODE_CONFIG"
    else
        fail "No generated node configuration found under $FLEET_DIR/nodes"
    fi
else
    fail "Fleet directory missing: $FLEET_DIR"
fi

section "SOPS And Secret Material"
if [ -f "$FLEET_DIR/secrets/secrets.yaml" ] && [ -f "$SOPS_KEY_FILE" ] && have_command sops; then
    if sudo sh -c "SOPS_AGE_KEY_FILE='$SOPS_KEY_FILE' sops -d '$FLEET_DIR/secrets/secrets.yaml' >/dev/null" 2>/tmp/nops-secrets-dec.err; then
        pass "Fleet secrets decrypt successfully"
        for key_name in git_username git_password cloudflare_api_token cloudflare_account_id cloudflare_zone_id cloudflare_tunnel_name cloudflare_tunnel_domain cloudflare_tunnel_token; do
            if [ -n "$(extract_secret_value "$key_name")" ]; then
                pass "Decrypted secret present: $key_name"
            else
                warn "Decrypted secret missing or empty: $key_name"
            fi
        done
    else
        fail "Fleet secrets failed to decrypt"
        sed 's/^/    /' /tmp/nops-secrets-dec.err
    fi
else
    warn "Skipped SOPS decrypt check because secrets file, key, or sops command is unavailable"
fi

section "Forgejo Runtime"
if [ -d /var/lib/forgejo ]; then
    pass "Forgejo state directory exists"
    print_shell_output "Forgejo state ownership" "sudo find /var/lib/forgejo -maxdepth 2 \\( -type d -o -type f \\) | sort | xargs -r sudo stat -c '%U:%G %a %n'"
else
    warn "Forgejo state directory does not exist"
fi

if [ -f "$FORGEJO_APP_INI" ]; then
    pass "Forgejo app.ini exists"
    print_cmd_output "Forgejo app.ini permissions" sudo stat -c '%U:%G %a %n' "$FORGEJO_APP_INI"
else
    warn "Forgejo app.ini does not exist"
fi

for unit in forgejo nops cloudflared docker; do
    if have_systemd_unit "$unit.service"; then
        pass "Systemd unit present: $unit.service"
        print_cmd_output "systemctl status $unit" sudo systemctl status "$unit" --no-pager
        print_cmd_output "Recent journal for $unit" sudo journalctl -u "$unit" -n 50 --no-pager
    else
        warn "Systemd unit missing: $unit.service"
    fi
done

if curl -fsS --max-time 5 "$FORGEJO_API" >/dev/null 2>&1; then
    pass "Forgejo API health endpoint responded"
else
    warn "Forgejo API health endpoint did not respond: $FORGEJO_API"
fi

section "Cloudflare API"
CF_API_TOKEN=""
CF_ACCOUNT_ID=""
CF_ZONE_ID=""
CF_TUNNEL_DOMAIN=""

if [ -f "$CONFIG_FILE" ] && have_command jq; then
    CF_API_TOKEN=$(json_value '.cloudflare_api_token')
    CF_ACCOUNT_ID=$(json_value '.cloudflare_account_id')
    CF_ZONE_ID=$(json_value '.cloudflare_zone_id')
    CF_TUNNEL_DOMAIN=$(json_value '.cloudflare_tunnel_domain')
fi

if [ -z "$CF_API_TOKEN" ]; then
    CF_API_TOKEN=$(extract_secret_value cloudflare_api_token)
    CF_ACCOUNT_ID=$(extract_secret_value cloudflare_account_id)
    CF_ZONE_ID=$(extract_secret_value cloudflare_zone_id)
    CF_TUNNEL_DOMAIN=$(extract_secret_value cloudflare_tunnel_domain)
fi

if [ -n "$CF_API_TOKEN" ]; then
    check_cloudflare_token "$CF_API_TOKEN"
    check_cloudflare_account "$CF_API_TOKEN" "$CF_ACCOUNT_ID"
    check_cloudflare_zone "$CF_API_TOKEN" "$CF_ZONE_ID" "$CF_TUNNEL_DOMAIN"
else
    warn "No Cloudflare API token available for remote validation"
fi

section "Summary"
if [ "$FAILURES" -eq 0 ]; then
    pass "Diagnostics completed with no hard failures"
else
    fail "Diagnostics completed with $FAILURES hard failure(s)"
fi

if [ "$WARNINGS" -gt 0 ]; then
    warn "Diagnostics completed with $WARNINGS warning(s)"
fi

rm -f /tmp/nops-secrets-dec.err
