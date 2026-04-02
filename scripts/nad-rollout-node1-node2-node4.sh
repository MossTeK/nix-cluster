#!/usr/bin/env bash
set -euo pipefail

if [[ "${NIX_CLUSTER_BOOTSTRAPPED:-0}" != "1" ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    exec nix shell \
      nixpkgs#bash \
      nixpkgs#coreutils \
      nixpkgs#curl \
      nixpkgs#git \
      nixpkgs#gnugrep \
      nixpkgs#jq \
      nixpkgs#openssh \
      nixpkgs#python3 \
      nixpkgs#sshpass \
      --command env NIX_CLUSTER_BOOTSTRAPPED=1 bash "$0" "$@"
  fi
fi

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script with sudo." >&2
    exit 1
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

log() {
  printf '[rollout] %s\n' "$*"
}

fail() {
  printf '[rollout] ERROR: %s\n' "$*" >&2
  exit 1
}

run_local_user() {
  sudo -u "$LOCAL_USER" -H env HOME="$LOCAL_HOME" "$@"
}

run_local_shell() {
  run_local_user bash -lc "$*"
}

repo_dirty() {
  local repo="$1"
  run_local_shell "cd '$repo' && test -n \"\$(git status --porcelain)\""
}

commit_and_push_if_dirty() {
  local repo="$1"
  local message="$2"
  if repo_dirty "$repo"; then
    log "Committing and pushing $(basename "$repo")"
    run_local_shell "cd '$repo' && git add . && git commit -m '$message' && git push origin main"
  else
    log "No local changes in $(basename "$repo"); skipping commit"
  fi
}

build_nix_cluster_local() {
  log "Building nix-cluster locally"
  run_local_shell "cd '$NIX_CLUSTER_REPO' && nix build .#default && nix build .#install"
}

build_fleet_with_override() {
  log "Building homelab-fleet locally against local nix-cluster"
  run_local_shell "cd '$FLEET_REPO' && \
    nix build .#nixosConfigurations.node1.config.system.build.toplevel --override-input nixCluster path:$NIX_CLUSTER_REPO && \
    nix build .#nixosConfigurations.node2.config.system.build.toplevel --override-input nixCluster path:$NIX_CLUSTER_REPO && \
    nix build .#nixosConfigurations.node4.config.system.build.toplevel --override-input nixCluster path:$NIX_CLUSTER_REPO"
}

update_fleet_lock() {
  log "Updating homelab-fleet flake.lock to newest nix-cluster"
  run_local_shell "cd '$FLEET_REPO' && nix flake lock --update-input nixCluster"
}

build_fleet_locked() {
  log "Building homelab-fleet from locked inputs"
  run_local_shell "cd '$FLEET_REPO' && \
    nix build .#nixosConfigurations.node1.config.system.build.toplevel && \
    nix build .#nixosConfigurations.node2.config.system.build.toplevel && \
    nix build .#nixosConfigurations.node4.config.system.build.toplevel"
}

ssh_as_local_user() {
  local target="$1"
  shift
  if [[ -n "${REMOTE_LOGIN_PASSWORD_B64:-}" ]]; then
    run_local_user env SSHPASS="$(printf '%s' "$REMOTE_LOGIN_PASSWORD_B64" | base64 -d)" \
      sshpass -e ssh "${SSH_OPTS[@]}" "$target" "$@"
  else
    run_local_user ssh "${SSH_OPTS[@]}" "$target" "$@"
  fi
}

remote_action() {
  local node_name="$1"
  local node_ip="$2"
  local action="$3"
  local output_file="$4"

  log "${action} on ${node_name} (${node_ip})"
  ssh_as_local_user "moss@${node_ip}" \
    "env REMOTE_SUDO_PASSWORD_B64='${REMOTE_SUDO_PASSWORD_B64}' FLEET_ORIGIN_B64='${FLEET_ORIGIN_B64}' bash -s -- '${action}' '${node_name}'" <<'REMOTE' | tee "$output_file"
set -euo pipefail

action="${1:-}"
node_name="${2:-}"

sudo_password() {
  printf '%s' "${REMOTE_SUDO_PASSWORD_B64}" | base64 -d
}

sudo_run() {
  local password
  password="$(sudo_password)"
  printf '%s\n' "$password" | sudo -S -p '' "$@"
}

fleet_origin() {
  printf '%s' "${FLEET_ORIGIN_B64}" | base64 -d
}

have_user() {
  getent passwd "$1" >/dev/null 2>&1
}

service_user() {
  if have_user nix-cluster; then
    echo nix-cluster
  elif have_user nops; then
    echo nops
  else
    echo ""
  fi
}

service_group() {
  local user
  user="$(service_user)"
  if [[ -n "$user" ]]; then
    id -gn "$user"
  else
    echo root
  fi
}

service_home() {
  local user
  user="$(service_user)"
  if [[ -n "$user" ]]; then
    getent passwd "$user" | cut -d: -f6
  else
    echo /root
  fi
}

desired_service_user() {
  echo nix-cluster
}

desired_service_home() {
  echo /home/nix-cluster
}

desired_repo_path() {
  echo /home/nix-cluster/homelab-fleet
}

current_repo_path() {
  if [[ -f /etc/nops-runtime-config.json ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PY'
import json
with open('/etc/nops-runtime-config.json', 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get('directories', {}).get('repo') or '')
PY
    else
      nix shell nixpkgs#python3 --command python3 - <<'PY'
import json
with open('/etc/nops-runtime-config.json', 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get('directories', {}).get('repo') or '')
PY
    fi
    return
  fi

  local home
  home="$(service_home)"
  if [[ -n "$home" ]]; then
    echo "$home/homelab-fleet"
  else
    echo "$(desired_repo_path)"
  fi
}

print_runtime_summary() {
  if [[ -f /etc/nops-runtime-config.json ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PY'
import json
p = "/etc/nops-runtime-config.json"
with open(p, "r", encoding="utf-8") as f:
    data = json.load(f)
print("hostname:", data.get("hostname"))
print("is_controller:", data.get("is_controller"))
print("repo:", data.get("directories", {}).get("repo"))
print("state:", data.get("directories", {}).get("state"))
print("metrics:", data.get("directories", {}).get("metrics"))
print("tracked_units:", data.get("observability", {}).get("tracked_units"))
print("ha_enable:", data.get("ha", {}).get("enable"))
print("runtime_store:", data.get("ha", {}).get("runtime_store"))
print("reporting:", data.get("ha", {}).get("reporting"))
print("scheduler:", data.get("ha", {}).get("scheduler"))
PY
    else
      nix shell nixpkgs#python3 --command python3 - <<'PY'
import json
p = "/etc/nops-runtime-config.json"
with open(p, "r", encoding="utf-8") as f:
    data = json.load(f)
print("hostname:", data.get("hostname"))
print("is_controller:", data.get("is_controller"))
print("repo:", data.get("directories", {}).get("repo"))
print("state:", data.get("directories", {}).get("state"))
print("metrics:", data.get("directories", {}).get("metrics"))
print("tracked_units:", data.get("observability", {}).get("tracked_units"))
print("ha_enable:", data.get("ha", {}).get("enable"))
print("runtime_store:", data.get("ha", {}).get("runtime_store"))
print("reporting:", data.get("ha", {}).get("reporting"))
print("scheduler:", data.get("ha", {}).get("scheduler"))
PY
    fi
  else
    echo "MISSING /etc/nops-runtime-config.json"
  fi
}

print_path_state() {
  local current_repo current_home desired_repo desired_home
  current_repo="$(current_repo_path)"
  current_home="$(service_home)"
  desired_repo="$(desired_repo_path)"
  desired_home="$(desired_service_home)"

  for p in \
    "$desired_home" \
    "$desired_repo" \
    "$desired_home/.ssh" \
    "$desired_home/.ssh/id_ed25519" \
    "$desired_home/log" \
    /home/nops \
    /home/nops/homelab-fleet \
    "$current_home" \
    "$current_repo" \
    /var/lib/nops \
    /var/lib/nops/ha \
    /var/lib/nops/metrics \
    /var/lib/nops-heartbeat \
    /etc/nops-runtime-config.json
  do
    if [[ -e "$p" ]]; then
      sudo_run stat -c "%A %U:%G %n" "$p"
    else
      echo "MISSING $p"
    fi
  done
}

print_repo_state() {
  local user repo
  user="$(service_user)"
  repo="$(current_repo_path)"
  if [[ -n "$user" && -d "$repo/.git" ]]; then
    sudo_run -u "$user" git -C "$repo" remote -v || true
    sudo_run -u "$user" git -C "$repo" branch --show-current || true
    sudo_run -u "$user" git -C "$repo" status --short || true
    sudo_run -u "$user" git -C "$repo" rev-parse HEAD || true
  else
    echo "MISSING $repo/.git"
  fi
}

print_service_state() {
  local unit
  for unit in \
    nix-cluster \
    caddy \
    cloudflared \
    keepalived \
    pixiecore \
    promtail \
    prometheus-node-exporter \
    postgresqlBackup.timer
  do
    echo "unit=$unit enabled=$(systemctl is-enabled \"$unit\" 2>/dev/null || true) active=$(systemctl is-active \"$unit\" 2>/dev/null || true)"
  done
}

collect_state() {
  echo "==================== $(hostname) ===================="
  echo "--- identity ---"
  hostname
  id
  uname -a

  echo
  echo "--- users ---"
  getent passwd nix-cluster || true
  getent passwd nops || true

  echo
  echo "--- key paths ---"
  print_path_state

  echo
  echo "--- repo state ---"
  print_repo_state

  echo
  echo "--- runtime config summary ---"
  print_runtime_summary

  echo
  echo "--- service state ---"
  print_service_state

  echo
  echo "--- nix-cluster status ---"
  sudo_run systemctl status nix-cluster --no-pager -l || true

  echo
  echo "--- recent nix-cluster logs ---"
  sudo_run journalctl -u nix-cluster -n 120 --no-pager || true

  echo
  echo "--- ha files ---"
  sudo_run ls -lah /var/lib/nops/ha 2>/dev/null || true
  sudo_run ls -lah /var/lib/nops/metrics 2>/dev/null || true

  echo
  echo "--- metrics grep ---"
  curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null | grep -E "nix_cluster|nops|node_systemd_unit_state" | tail -n 80 || true
}

prepare_node() {
  local origin current_user current_group current_home current_repo desired_repo
  origin="$(fleet_origin)"
  current_user="$(service_user)"
  current_group="$(service_group)"
  current_home="$(service_home)"
  current_repo="$(current_repo_path)"
  desired_repo="$(desired_repo_path)"

  if [[ -z "$current_user" ]]; then
    echo "No existing service user found; will stage using root-owned paths until rebuild"
    current_user="root"
    current_group="root"
    current_home="/root"
    current_repo="$desired_repo"
  fi

  sudo_run install -d -o "$current_user" -g "$current_group" -m 0755 "$current_home"
  sudo_run install -d -o "$current_user" -g "$current_group" -m 0700 "$current_home/.ssh"
  sudo_run install -d -o "$current_user" -g "$current_group" -m 0755 "$current_home/log"
  sudo_run install -d -o "$current_user" -g "$current_group" -m 0755 /var/lib/nops
  sudo_run install -d -o "$current_user" -g "$current_group" -m 0755 /var/lib/nops/ha
  sudo_run install -d -o "$current_user" -g "$current_group" -m 0755 /var/lib/nops/metrics
  sudo_run install -d -o "$current_user" -g "$current_group" -m 0755 /var/lib/nops-heartbeat

  if [[ "$current_home" != "/home/nops" && -d /home/nops/.ssh && ! -e "$current_home/.ssh/id_ed25519" ]]; then
    sudo_run cp -a /home/nops/.ssh/. "$current_home/.ssh/"
  fi

  if [[ ! -d "$current_repo/.git" && -d /home/nops/homelab-fleet/.git && "$current_repo" != "/home/nops/homelab-fleet" ]]; then
    sudo_run cp -a /home/nops/homelab-fleet "$current_repo"
  fi

  if [[ ! -d "$current_repo/.git" ]]; then
    sudo_run rm -rf "$current_repo"
    sudo_run -u "$current_user" git clone "$origin" "$current_repo"
  fi

  sudo_run find "$current_repo/.git" -name '*.lock' -delete 2>/dev/null || true
  sudo_run chown -R "$current_user:$current_group" "$current_home"
  sudo_run chown -R "$current_user:$current_group" "$current_repo"
  sudo_run chown -R "$current_user:$current_group" /var/lib/nops /var/lib/nops-heartbeat
  sudo_run chmod 700 "$current_home/.ssh" 2>/dev/null || true
  sudo_run chmod 600 "$current_home/.ssh/id_ed25519" 2>/dev/null || true
  sudo_run chmod 644 "$current_home/.ssh/id_ed25519.pub" 2>/dev/null || true

  sudo_run -u "$current_user" git -C "$current_repo" remote set-url origin "$origin" || true
  sudo_run -u "$current_user" git -C "$current_repo" config --global --add safe.directory "$current_repo" || true
  sudo_run -u "$current_user" git -C "$current_repo" status --short || true
}

refresh_repo() {
  local user group repo
  user="$(service_user)"
  group="$(service_group)"
  repo="$(current_repo_path)"
  sudo_run find "$repo/.git" -name '*.lock' -delete 2>/dev/null || true
  sudo_run chown -R "$user:$group" "$repo"
  sudo_run -u "$user" git -C "$repo" fetch origin
  sudo_run -u "$user" git -C "$repo" reset --hard origin/main
}

rebuild_node() {
  local flake_repo
  refresh_repo
  flake_repo="$(current_repo_path)"
  sudo_run nixos-rebuild switch --flake "${flake_repo}#${node_name}" --impure
  sudo_run systemctl restart nix-cluster
  sudo_run systemctl status nix-cluster --no-pager -l || true
  sudo_run journalctl -u nix-cluster -n 200 --no-pager || true
}

verify_controller() {
  local user
  user="$(service_user)"
  sudo_run -u "$user" /run/current-system/sw/bin/nops-fleet-status
  sudo_run -u "$user" /run/current-system/sw/bin/nops-controller-heartbeat || true
  sudo_run systemctl status nix-cluster --no-pager || true
  sudo_run systemctl status caddy --no-pager || true
  sudo_run systemctl status cloudflared --no-pager || true
  sudo_run systemctl status keepalived --no-pager || true
  sudo_run systemctl status pixiecore --no-pager || true
  sudo_run systemctl status postgresqlBackup.timer --no-pager || true
  sudo_run ls -lah /var/lib/nops/ha || true
  sudo_run ls -lah /var/lib/nops/metrics || true
  curl -fsS http://127.0.0.1:9100/metrics | grep -E 'nix_cluster|nops' || true
}

verify_worker() {
  sudo_run systemctl status nix-cluster --no-pager || true
  sudo_run systemctl status caddy --no-pager || true
  sudo_run systemctl status cloudflared --no-pager || true
  sudo_run systemctl status keepalived --no-pager || true
  sudo_run ls -lah /var/lib/nops/ha || true
  sudo_run ls -lah /var/lib/nops/metrics || true
  curl -fsS http://127.0.0.1:9100/metrics | grep -E 'nix_cluster|nops' || true
  systemctl is-enabled pixiecore || true
  systemctl is-active pixiecore || true
  systemctl is-enabled postgresqlBackup.timer || true
  systemctl is-active postgresqlBackup.timer || true
}

case "$action" in
  collect)
    collect_state
    ;;
  prepare)
    prepare_node
    ;;
  rebuild)
    rebuild_node
    ;;
  verify-controller)
    verify_controller
    ;;
  verify-worker)
    verify_worker
    ;;
  *)
    echo "Unknown action: $action" >&2
    exit 1
    ;;
esac
REMOTE
}

collect_all() {
  local phase="$1"
  local entry name ip
  for entry in "${NODES[@]}"; do
    name="${entry%%:*}"
    ip="${entry##*:}"
    remote_action "$name" "$ip" collect "$LOG_ROOT/${phase}-${name}-state.log"
  done
}

prepare_all_nodes() {
  local entry name ip
  for entry in "${NODES[@]}"; do
    name="${entry%%:*}"
    ip="${entry##*:}"
    remote_action "$name" "$ip" prepare "$LOG_ROOT/prepare-${name}.log"
  done
}

rebuild_node_remote() {
  local name="$1"
  local ip="$2"
  remote_action "$name" "$ip" rebuild "$LOG_ROOT/rebuild-${name}.log"
}

verify_node_remote() {
  local name="$1"
  local ip="$2"
  local action="$3"
  remote_action "$name" "$ip" "$action" "$LOG_ROOT/verify-${name}.log"
}

main() {
  require_root
  require_cmd git nix ssh base64 sudo sshpass

  LOCAL_USER="${SUDO_USER:-moss}"
  LOCAL_HOME="$(getent passwd "$LOCAL_USER" | cut -d: -f6)"
  [[ -n "$LOCAL_HOME" ]] || fail "Could not determine home directory for $LOCAL_USER"

  INFRA_ROOT="${INFRA_ROOT:-$LOCAL_HOME/repos/infra}"
  NIX_CLUSTER_REPO="$INFRA_ROOT/nix-cluster"
  FLEET_REPO="$INFRA_ROOT/homelab-fleet"

  [[ -d "$NIX_CLUSTER_REPO/.git" ]] || fail "Missing git repo: $NIX_CLUSTER_REPO"
  [[ -d "$FLEET_REPO/.git" ]] || fail "Missing git repo: $FLEET_REPO"

  SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
  )

  NODES=(
    "node1:192.168.2.201"
    "node2:192.168.2.202"
    "node4:192.168.2.204"
  )

  LOG_ROOT="/var/log/nix-cluster-rollout-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOG_ROOT"

  local password
  read -rsp "Remote sudo password for moss on node1/node2/node4: " password
  echo
  [[ -n "$password" ]] || fail "Password is required"
  REMOTE_SUDO_PASSWORD_B64="$(printf '%s' "$password" | base64 -w0)"
  REMOTE_LOGIN_PASSWORD_B64="$REMOTE_SUDO_PASSWORD_B64"
  unset password

  FLEET_ORIGIN_B64="$(run_local_shell "cd '$FLEET_REPO' && git remote get-url origin" | tr -d '\n' | base64 -w0)"

  log "Collecting pre-rollout state"
  collect_all pre

  build_nix_cluster_local
  build_fleet_with_override

  commit_and_push_if_dirty "$NIX_CLUSTER_REPO" "refactor: automate nad rollout and diagnostics"

  update_fleet_lock
  build_fleet_locked
  commit_and_push_if_dirty "$FLEET_REPO" "chore: update fleet for latest nix-cluster"

  log "Preparing nodes for /home/nix-cluster and runtime ownership"
  prepare_all_nodes

  log "Rebuilding controller first"
  rebuild_node_remote node1 192.168.2.201
  verify_node_remote node1 192.168.2.201 verify-controller

  log "Rebuilding workers"
  rebuild_node_remote node2 192.168.2.202
  verify_node_remote node2 192.168.2.202 verify-worker

  rebuild_node_remote node4 192.168.2.204
  verify_node_remote node4 192.168.2.204 verify-worker

  log "Collecting post-rollout state"
  collect_all post

  log "Rollout complete. Logs are in $LOG_ROOT"
}

main "$@"
