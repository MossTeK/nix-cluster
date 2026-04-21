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
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=5
)
TEMP_FILES=()
CONTROLLER_LOG_DIR="/home/nix-cluster/log"
PROVISIONING_LOG_ROOT="${CONTROLLER_LOG_DIR}/provisioning"
CURRENT_NODE_LOG_DIR=""
INSTALL_LOG_SYSLOG_TAG="nix-cluster-install"
REMOTE_INSTALLER_LOG_DIR="/var/log/nixos-install"
REMOTE_INSTALLER_LOG_FILE="${REMOTE_INSTALLER_LOG_DIR}/install.log"
REMOTE_INSTALLER_STATE_FILE="${REMOTE_INSTALLER_LOG_DIR}/state.env"
REMOTE_PERSISTED_INSTALL_LOG_DIR="/mnt/var/log/nixos-install"

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sanitize_path_component() {
  printf '%s\n' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

ensure_provisioning_log_root() {
  mkdir -p "$PROVISIONING_LOG_ROOT"
}

ensure_node_log_dir() {
  local safe_host

  if [ -n "$CURRENT_NODE_LOG_DIR" ]; then
    printf '%s\n' "$CURRENT_NODE_LOG_DIR"
    return 0
  fi

  safe_host=$(sanitize_path_component "$HOSTNAME")
  CURRENT_NODE_LOG_DIR="${PROVISIONING_LOG_ROOT}/${safe_host}/$(date -u +"%Y%m%dT%H%M%SZ")"
  mkdir -p "$CURRENT_NODE_LOG_DIR"
  ln -sfn "$CURRENT_NODE_LOG_DIR" "${PROVISIONING_LOG_ROOT}/${safe_host}/latest"
  printf '%s\n' "$CURRENT_NODE_LOG_DIR"
}

node_log_path() {
  local file_name="$1"

  ensure_node_log_dir >/dev/null
  printf '%s/%s\n' "$CURRENT_NODE_LOG_DIR" "$file_name"
}

emit_install_journal() {
  local message="$1"

  if command -v logger >/dev/null 2>&1; then
    logger -t "$INSTALL_LOG_SYSLOG_TAG" -- "$message" || true
  fi
}

capture_remote_command_output() {
  local output_name="$1"
  local remote_user="$2"
  local remote_password="$3"
  local remote_auth_mode="$4"
  local remote_command="$5"
  local run_mode="${6:-sudo}"
  local output_path

  output_path=$(node_log_path "$output_name")
  if [ "$run_mode" = "direct" ]; then
    run_remote "$remote_user" "$INSTALLER_IP" "$remote_password" "$remote_auth_mode" "$remote_command" >"$output_path" 2>&1 || return 1
  else
    run_remote_sudo_command "$remote_user" "$INSTALLER_IP" "$remote_password" "$remote_auth_mode" "$remote_command" >"$output_path" 2>&1 || return 1
  fi

  [ -s "$output_path" ]
}

capture_remote_file() {
  local output_name="$1"
  local remote_user="$2"
  local remote_password="$3"
  local remote_auth_mode="$4"
  local remote_path="$5"
  local run_mode="${6:-sudo}"
  local remote_command

  remote_command=$(printf "if [ -f %q ]; then cat %q; fi" "$remote_path" "$remote_path")
  capture_remote_command_output "$output_name" "$remote_user" "$remote_password" "$remote_auth_mode" "$remote_command" "$run_mode"
}

ingest_local_file_to_journal() {
  local source_name="$1"
  local local_path="$2"
  local line

  [ -s "$local_path" ] || return 0

  while IFS= read -r line; do
    emit_install_journal "host=$HOSTNAME ip=$INSTALLER_IP source=$source_name $line"
  done < "$local_path"
}

capture_remote_installer_artifacts() {
  local remote_user="$1"
  local remote_password="$2"
  local remote_auth_mode="$3"
  local prefix="${4:-installer}"
  local live_log_path
  local persisted_log_path

  capture_remote_command_output "${prefix}-paths.txt" "$remote_user" "$remote_password" "$remote_auth_mode" "for path in '$REMOTE_INSTALLER_LOG_DIR' '$REMOTE_PERSISTED_INSTALL_LOG_DIR' /mnt/etc/nixos; do echo \"== \\$path ==\"; ls -lah \"\\$path\" 2>/dev/null || true; echo; done" || true

  capture_remote_file "${prefix}-live-install.log" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_LOG_FILE" || true
  live_log_path=$(node_log_path "${prefix}-live-install.log")
  ingest_local_file_to_journal "${prefix}-live-install" "$live_log_path"

  capture_remote_file "${prefix}-live-state.env" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_STATE_FILE" || true
  capture_remote_file "${prefix}-persisted-install.log" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_PERSISTED_INSTALL_LOG_DIR/install.log" || true
  persisted_log_path=$(node_log_path "${prefix}-persisted-install.log")
  ingest_local_file_to_journal "${prefix}-persisted-install" "$persisted_log_path"
  capture_remote_file "${prefix}-persisted-state.env" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_PERSISTED_INSTALL_LOG_DIR/state.env" || true
  capture_remote_file "${prefix}-lsblk.before.txt" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_LOG_DIR/lsblk.before.txt" || true
  capture_remote_file "${prefix}-ip.addr.txt" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_LOG_DIR/ip.addr.txt" || true
  capture_remote_file "${prefix}-ip.route.txt" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_LOG_DIR/ip.route.txt" || true
  capture_remote_file "${prefix}-findmnt.mnt.txt" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_LOG_DIR/findmnt.mnt.txt" || true
  capture_remote_file "${prefix}-target.nixos.tree.txt" "$remote_user" "$remote_password" "$remote_auth_mode" "$REMOTE_INSTALLER_LOG_DIR/target.nixos.tree.txt" || true
  capture_remote_file "${prefix}-target-configuration.nix" "$remote_user" "$remote_password" "$remote_auth_mode" "/mnt/etc/nixos/configuration.nix" || true
  capture_remote_file "${prefix}-target-hardware-configuration.nix" "$remote_user" "$remote_password" "$remote_auth_mode" "/mnt/etc/nixos/hardware-configuration.nix" || true
  capture_remote_file "${prefix}-target-disko.nix" "$remote_user" "$remote_password" "$remote_auth_mode" "/mnt/etc/nixos/disko.nix" || true
}

capture_controller_probe_snapshot() {
  local probe_log

  probe_log=$(node_log_path "controller-probe.txt")
  {
    echo "timestamp=$(timestamp_utc)"
    echo "controller=$CONTROLLER_HOSTNAME"
    echo "target_hostname=$HOSTNAME"
    echo "target_ip=$INSTALLER_IP"
    echo "installer_user=$INSTALLER_USER"
    echo "node_admin=$NODE_ADMIN"
    echo "installer_auth_mode=$INSTALLER_AUTH_MODE"
    echo "controller_ssh_pub_key_fingerprint=$(ssh-keygen -lf \"${NIX_CLUSTER_SSH_KEY}.pub\" 2>/dev/null | awk '{print $2, $4}' || true)"
    echo "expected_live_install_log=$REMOTE_INSTALLER_LOG_FILE"
    echo "expected_persisted_install_log=$REMOTE_PERSISTED_INSTALL_LOG_DIR/install.log"
    echo
    echo "== ping =="
    ping -c 1 -W 2 "$INSTALLER_IP" || true
    echo
    echo "== ip neigh =="
    ip neigh show "$INSTALLER_IP" || true
    echo
    echo "== ssh keyscan =="
    ssh-keyscan -T 5 "$INSTALLER_IP" 2>/dev/null || true
  } >"$probe_log" 2>&1
}

capture_remote_snapshot() {
  local snapshot_name="$1"
  local remote_user="$2"
  local remote_password="$3"
  local remote_auth_mode="$4"
  local snapshot_log
  local remote_script

  snapshot_log=$(node_log_path "$snapshot_name")
  remote_script=$(cat <<'EOF'
set -u
echo "timestamp=$(date -Is)"
echo "hostname=$(hostname 2>/dev/null || true)"
echo "user=$(id -un 2>/dev/null || true)"
echo
echo "== ip -4 -brief addr =="
ip -4 -brief addr 2>/dev/null || true
echo
echo "== ip route =="
ip route 2>/dev/null || true
echo
echo "== lsblk =="
lsblk -o NAME,PATH,FSTYPE,SIZE,MOUNTPOINT,MODEL 2>/dev/null || true
echo
echo "== findmnt / =="
findmnt / 2>/dev/null || true
echo
echo "== active boot =="
cat /proc/cmdline 2>/dev/null || true
echo
echo "== nix-cluster service =="
systemctl is-active nix-cluster 2>/dev/null || true
systemctl status nix-cluster --no-pager -l 2>/dev/null || true
echo
echo "== nix-cluster journal =="
journalctl -b -u nix-cluster -n 120 --no-pager 2>/dev/null || true
echo
echo "== setup log =="
sudo cat /var/log/nix-cluster-setup.log 2>/dev/null || true
EOF
)

  run_remote "$remote_user" "$INSTALLER_IP" "$remote_password" "$remote_auth_mode" "$remote_script" >"$snapshot_log" 2>&1 || true
}

capture_failure_artifacts() {
  local reason="$1"
  local summary_log

  ensure_node_log_dir >/dev/null
  summary_log=$(node_log_path "failure-summary.txt")
  {
    echo "timestamp=$(timestamp_utc)"
    echo "reason=$reason"
    echo "hostname=$HOSTNAME"
    echo "installer_ip=$INSTALLER_IP"
    echo "installer_user=$INSTALLER_USER"
    echo "node_admin=$NODE_ADMIN"
    echo "installer_auth_mode=$INSTALLER_AUTH_MODE"
    echo "log_dir=$CURRENT_NODE_LOG_DIR"
  } >"$summary_log"

  capture_controller_probe_snapshot

  if can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"; then
    capture_remote_snapshot "installer-runtime.txt" "$INSTALLER_USER" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"
    capture_remote_installer_artifacts "$INSTALLER_USER" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "installer" || true
  fi

  if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto; then
    capture_remote_snapshot "admin-runtime.txt" "$NODE_ADMIN" "$NODE_ADMIN_PASS" auto
  fi

  if can_login_with_key nix-cluster "$INSTALLER_IP"; then
    capture_remote_snapshot "nix-cluster-runtime.txt" "nix-cluster" "" ssh_key
  fi
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

runtime_workers_present() {
  [ -r "$RUNTIME_CONFIG" ] && jq -e '.workers? | type == "object" and length > 0' "$RUNTIME_CONFIG" >/dev/null 2>&1
}

render_runtime_workers_json() {
  local output_file="$1"
  jq '
    (.workers // {} | to_entries | map({
      hostname: .key,
      installer_ip: (.value.installer_ip // ""),
      installer_user: (.value.installer_user // "nixos"),
      installer_auth_mode: (.value.installer_auth_mode // "ssh_key"),
      installer_ssh_pub_key: (.value.installer_ssh_pub_key // ""),
      installer_password: (.value.installer_password // ""),
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
    }))
  ' "$RUNTIME_CONFIG" > "$output_file"
}

merge_runtime_workers_into_deployments() {
  local existing_json="$1"
  local output_file="$2"
  jq --slurpfile runtime "$RUNTIME_CONFIG" '
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
  ' "$existing_json" > "$output_file"
}

DEPLOYMENTS_SOURCE="deployments.json"
if [ -f "$DEPLOYMENTS_JSON" ]; then
  DEPLOYMENTS_INPUT=$(mktemp)
  prepare_json_input "$DEPLOYMENTS_JSON" "$DEPLOYMENTS_INPUT"
  if runtime_workers_present; then
    DEPLOYMENTS_MERGED=$(mktemp)
    merge_runtime_workers_into_deployments "$DEPLOYMENTS_INPUT" "$DEPLOYMENTS_MERGED"
    TEMP_FILES+=("$DEPLOYMENTS_MERGED")
    DEPLOYMENTS_INPUT="$DEPLOYMENTS_MERGED"
    DEPLOYMENTS_SOURCE="deployments.json+runtime-workers"
  fi
elif runtime_workers_present; then
  DEPLOYMENTS_INPUT=$(mktemp)
  TEMP_FILES+=("$DEPLOYMENTS_INPUT")
  render_runtime_workers_json "$DEPLOYMENTS_INPUT"
  DEPLOYMENTS_SOURCE="runtime-workers"
else
  exit 0
fi

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
  CONTROLLER_LOG_DIR=$(jq -r '.directories.log // "/home/nix-cluster/log"' "$RUNTIME_CONFIG" 2>/dev/null || true)
fi

PROVISIONING_LOG_ROOT="${CONTROLLER_LOG_DIR}/provisioning"
ensure_provisioning_log_root

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

wait_for_ssh_login() {
  local user="$1"
  local host="$2"
  local password="$3"
  local auth_mode="${4:-auto}"
  local max_attempts="${5:-60}"
  local attempt=1

  until can_login "$user" "$host" "$password" "$auth_mode"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi

    echo "[nix-cluster] waiting for live installer SSH on $host (attempt $attempt/$max_attempts, auth=$auth_mode, user=$user)..."
    emit_install_journal "live-installer-wait host=$HOSTNAME ip=$host attempt=$attempt/$max_attempts auth=$auth_mode user=$user"
    sleep 10
    attempt=$((attempt + 1))
  done

  return 0
}

subnet_prefix_from_ip() {
  local ip="$1"

  if [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

resolved_hostname_candidates() {
  local candidate

  for candidate in "$HOSTNAME" "${HOSTNAME}.local"; do
    getent ahostsv4 "$candidate" 2>/dev/null | awk '{print $1}' || true
  done
}

ping_sweep_subnet() {
  local prefix="$1"
  local ip
  local active_jobs=0

  for i in $(seq 1 254); do
    ip="${prefix}.${i}"
    if [ "$ip" = "$CONTROLLER_PRIMARY_IP" ]; then
      continue
    fi

    ( ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && printf '%s\n' "$ip" ) || true &
    active_jobs=$((active_jobs + 1))

    if [ "$active_jobs" -ge 32 ]; then
      wait >/dev/null 2>&1 || true
      active_jobs=0
    fi
  done

  wait >/dev/null 2>&1 || true
}

candidate_node_ips() {
  local prefix=""

  {
    printf '%s\n' "$INSTALLER_IP"
    resolved_hostname_candidates
    ip neigh show 2>/dev/null | awk '{print $1}' || true

    if prefix=$(subnet_prefix_from_ip "$INSTALLER_IP"); then
      ping_sweep_subnet "$prefix"
    fi
  } | awk 'NF && !seen[$0]++'
}

remote_hostname_matches() {
  local user="$1"
  local host="$2"
  local password="$3"
  local auth_mode="$4"
  local remote_hostname

  if ! can_login "$user" "$host" "$password" "$auth_mode"; then
    return 1
  fi

  remote_hostname=$(run_remote "$user" "$host" "$password" "$auth_mode" "hostname -s 2>/dev/null || hostname" 2>/dev/null | tail -n 1 | tr -d '\r')
  [ "$remote_hostname" = "$HOSTNAME" ]
}

discover_node_ip() {
  local candidate_ip

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue

    if remote_hostname_matches "$NODE_ADMIN" "$candidate_ip" "$NODE_ADMIN_PASS" auto; then
      printf '%s\n' "$candidate_ip"
      return 0
    fi

    if remote_hostname_matches "nix-cluster" "$candidate_ip" "" ssh_key; then
      printf '%s\n' "$candidate_ip"
      return 0
    fi
  done < <(candidate_node_ips)

  return 1
}

refresh_node_ip_if_needed() {
  local reason="$1"
  local discovered_ip=""

  if discovered_ip=$(discover_node_ip 2>/dev/null); then
    if [ "$discovered_ip" != "$INSTALLER_IP" ]; then
      echo "[nix-cluster] $HOSTNAME detected at DHCP address $discovered_ip instead of inventory address $INSTALLER_IP."
      INSTALLER_IP="$discovered_ip"
      publish_join_state "dhcp-address-detected" "$reason; discovered $HOSTNAME at $INSTALLER_IP"
    fi
    return 0
  fi

  return 1
}

wait_for_installed_node_login() {
  local max_attempts="${1:-36}"
  local attempt=1

  until can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto; do
    refresh_node_ip_if_needed "waiting for installed OS after reboot" || true

    if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto; then
      break
    fi

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

  echo "[nix-cluster] join-state host=$HOSTNAME phase=$phase detail=$detail"
  emit_install_journal "join-state host=$HOSTNAME ip=$INSTALLER_IP phase=$phase detail=$detail"

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
  local HASHED_PASS
  local INSTALLER_FLAKE_URL="NIXOS_INSTALL_REPO_URL_PLACEHOLDER"
  local install_cmd=()
  local install_cmd_quoted=""
  local install_log_file
  local arg

  ensure_node_log_dir >/dev/null

  if [ -z "$DISK" ] || [ -z "$FS" ]; then
    echo "[nix-cluster] $HOSTNAME is missing disk or fs in deployments.json. Skipping."
    capture_failure_artifacts "missing disk or fs in deployments.json"
    publish_join_state "invalid-config" "missing disk or fs; logs in $CURRENT_NODE_LOG_DIR"
    return 1
  fi

  if ! run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "test -b '$DISK'"; then
    echo "[nix-cluster] $HOSTNAME configured disk $DISK does not exist on the live installer. Available disks:"
    run_remote "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "lsblk -dn -o NAME,PATH,SIZE,MODEL,TYPE | awk '\$5 == \"disk\" { print }'" | tee "$(node_log_path "available-disks.txt")" || true
    capture_failure_artifacts "configured disk missing on installer"
    publish_join_state "invalid-config" "configured disk missing on installer; logs in $CURRENT_NODE_LOG_DIR"
    return 1
  fi

  publish_join_state "provisioning-live-installer" "running nixos-install over ssh; live log at $REMOTE_INSTALLER_LOG_FILE"
  if [ -n "$NODE_ADMIN_PASSWORD_HASH" ]; then
    HASHED_PASS="$NODE_ADMIN_PASSWORD_HASH"
  elif [ -n "$NODE_ADMIN_PASS" ]; then
    HASHED_PASS=$(mkpasswd -m sha-512 -s <<< "$NODE_ADMIN_PASS")
  else
    HASHED_PASS="!"
  fi

  install_cmd=(
    nix
    --extra-experimental-features
    "nix-command flakes"
    run
    --refresh
    --no-write-lock-file
    "$INSTALLER_FLAKE_URL"
    --
    --hostname "$HOSTNAME"
    --disk "$DISK"
    --fs "$FS"
    --admin "$NODE_ADMIN"
    --ssh-key "$CONTROLLER_SSH_PUB_KEY"
  )

  if [ -n "$INSTALLER_SSH_PUB_KEY" ] && [ "$INSTALLER_SSH_PUB_KEY" != "$CONTROLLER_SSH_PUB_KEY" ]; then
    install_cmd+=(--ssh-key "$INSTALLER_SSH_PUB_KEY")
  fi

  install_cmd+=(
    --admin-password-hash "$HASHED_PASS"
    --packages git vim
    --force
  )

  for arg in "${install_cmd[@]}"; do
    printf -v arg '%q' "$arg"
    install_cmd_quoted+="$arg "
  done

  install_log_file=$(node_log_path "nixos-install.log")
  {
    echo "timestamp=$(timestamp_utc)"
    echo "hostname=$HOSTNAME"
    echo "installer_ip=$INSTALLER_IP"
    echo "installer_user=$INSTALLER_USER"
    echo "installer_auth_mode=$INSTALLER_AUTH_MODE"
    echo "remote_live_log=$REMOTE_INSTALLER_LOG_FILE"
    echo "remote_persisted_log=$REMOTE_PERSISTED_INSTALL_LOG_DIR/install.log"
    echo "install_command=$install_cmd_quoted"
    echo
  } >"$install_log_file"

  if ! run_remote_sudo_command "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "$install_cmd_quoted" 2>&1 | tee -a "$install_log_file"; then
    echo "[nix-cluster] Failed to run nixos-install on $HOSTNAME."
    capture_failure_artifacts "remote nixos-install command failed"
    publish_join_state "install-failed" "remote nixos-install command failed; logs in $CURRENT_NODE_LOG_DIR"
    return 1
  fi

  capture_remote_installer_artifacts "$INSTALLER_USER" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "post-install" || true

  if stop_pixiecore_for_disk_boot; then
    PXE_TEMP_DISABLED=1
  fi

  echo "[nix-cluster] Rebooting $HOSTNAME into the installed system..."
  run_remote_sudo_command "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true
  publish_join_state "waiting-for-installed-os" "waiting for first boot after install"

  echo "[nix-cluster] Waiting for $HOSTNAME to reboot..."
  if ! wait_for_installed_node_login 36; then
    if [ "$PXE_TEMP_DISABLED" -eq 1 ]; then
      start_pixiecore_after_disk_boot
    fi
    if can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE"; then
      echo "[nix-cluster] $HOSTNAME rebooted back into the live installer instead of the installed system. Boot from the local disk to continue enrollment."
      capture_failure_artifacts "node rebooted back into live installer"
      publish_join_state "installer-returned" "node rebooted back into live installer; logs in $CURRENT_NODE_LOG_DIR"
    else
      echo "[nix-cluster] $HOSTNAME did not become reachable after installation. Skipping enrollment."
      capture_failure_artifacts "node did not become reachable after install"
      publish_join_state "install-failed" "node did not become reachable after install; logs in $CURRENT_NODE_LOG_DIR"
    fi
    return 1
  fi

  if [ "$PXE_TEMP_DISABLED" -eq 1 ]; then
    start_pixiecore_after_disk_boot
  fi

  publish_join_state "installed-os-online" "installed system is reachable at $INSTALLER_IP"

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
  CURRENT_NODE_LOG_DIR=""
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

  if [ -z "$INSTALLER_SSH_PUB_KEY" ]; then
    INSTALLER_SSH_PUB_KEY="$CONTROLLER_SSH_PUB_KEY"
  fi

  NODE_SSH_KEYS_JSON=$(jq -cn \
    --arg controller "$CONTROLLER_SSH_PUB_KEY" \
    --arg installer "$INSTALLER_SSH_PUB_KEY" \
    '[ $controller, $installer ] | map(select(length > 0)) | unique')

  publish_node_inventory "$DEPLOYMENTS_SOURCE" "desired"
  publish_join_state "desired" "inventory record loaded from $DEPLOYMENTS_SOURCE"

  if ! can_login_with_key nix-cluster "$INSTALLER_IP" \
    && ! can_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" \
    && ! can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto; then
    refresh_node_ip_if_needed "preflight node discovery" || true
  fi

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
      ensure_node_log_dir >/dev/null
      echo "[nix-cluster] $HOSTNAME detected as Base OS, but reinstall=true so rebooting into netboot for a fresh install..."
      publish_join_state "rebooting-for-reinstall" "base os reachable and reinstall requested"
      run_remote_sudo_command "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true

      echo "[nix-cluster] Waiting for $HOSTNAME to come back on the live installer..."
      if ! wait_for_ssh_login "$INSTALLER_USER" "$INSTALLER_IP" "$INSTALLER_PASSWORD" "$INSTALLER_AUTH_MODE" 60; then
        if can_login "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS"; then
          echo "[nix-cluster] $HOSTNAME came back on the installed system instead of netboot. Ensure PXE/network boot is selected first, then rerun the controller."
          capture_failure_artifacts "node rebooted back into installed system instead of installer"
          publish_join_state "reinstall-blocked" "node rebooted back into installed system instead of installer; logs in $CURRENT_NODE_LOG_DIR"
        else
          echo "[nix-cluster] $HOSTNAME did not become SSH-reachable on the live installer after reboot. Skipping reinstall."
          capture_failure_artifacts "node did not return on live installer after reboot"
          publish_join_state "reinstall-failed" "node did not return on live installer; logs in $CURRENT_NODE_LOG_DIR"
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
        --argjson node_ssh_pub_keys "$NODE_SSH_KEYS_JSON" \
        --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
        --arg installer_ssh_pub_key "$INSTALLER_SSH_PUB_KEY" \
        --argjson ssh_password_auth "$SSH_PASSWORD_AUTH" \
        --arg node_role "$NODE_ROLE" \
        --arg keepalived_role "$KEEPALIVED_ROLE" \
        --arg fleet_private_key "$(sudo cat "$SOPS_KEY")" \
        --arg webhook_secret "$WEBHOOK_SECRET" \
        '.bootstrap_mode = false |
         .is_controller = ($node_role == "controller") |
         .preserve_existing_node_files = true |
         .git_user = $git_user |
         .git_token = $git_token |
         .repo_url = $repo_url |
         .node_group = $node_group |
         .node_admin = $admin |
         .node_admin_pass = "" |
         .node_admin_password_hash = $admin_password_hash |
         .node_ssh_pub_key = $node_ssh_pub_key |
         .node_ssh_pub_keys = $node_ssh_pub_keys |
         .ssh_password_auth = $ssh_password_auth |
         .installer_auth_mode = $installer_auth_mode |
         .installer_ssh_pub_key = $installer_ssh_pub_key |
         .node_role = $node_role |
         .keepalived_role = $keepalived_role |
         .fleet_private_key = $fleet_private_key |
         .trigger_choice = "2" |
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
        --argjson node_ssh_pub_keys "$NODE_SSH_KEYS_JSON" \
        --arg installer_auth_mode "$INSTALLER_AUTH_MODE" \
        --arg installer_ssh_pub_key "$INSTALLER_SSH_PUB_KEY" \
        --argjson ssh_password_auth "$SSH_PASSWORD_AUTH" \
        --arg node_role "$NODE_ROLE" \
        --arg keepalived_role "$KEEPALIVED_ROLE" \
        --arg fleet_private_key "$(sudo cat "$SOPS_KEY")" \
        --arg webhook_secret "$WEBHOOK_SECRET" \
        '{bootstrap_mode: false, is_controller: ($node_role == "controller"), preserve_existing_node_files: true, git_user: $git_user, git_token: $git_token, repo_url: $repo_url, node_group: $node_group, node_admin: $admin, node_admin_pass: "", node_admin_password_hash: $admin_password_hash, node_ssh_pub_key: $node_ssh_pub_key, node_ssh_pub_keys: $node_ssh_pub_keys, ssh_password_auth: $ssh_password_auth, installer_auth_mode: $installer_auth_mode, installer_ssh_pub_key: $installer_ssh_pub_key, node_role: $node_role, keepalived_role: $keepalived_role, fleet_private_key: $fleet_private_key, trigger_choice: "2", webhook_secret: $webhook_secret}' > "$CONFIG_JSON"
    fi

    if copy_to_remote "$CONFIG_JSON" "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" /tmp/nix-cluster-config.json auto; then
      run_remote_sudo_command "$NODE_ADMIN" "$INSTALLER_IP" "$NODE_ADMIN_PASS" auto "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#git -c nix --extra-experimental-features 'nix-command flakes' run git+NIX_CLUSTER_INSTALL_REPO_URL_PLACEHOLDER#install -- --config /tmp/nix-cluster-config.json"
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