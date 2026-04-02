#!/usr/bin/env bash
set -euo pipefail

if [[ "${NIX_CLUSTER_BOOTSTRAPPED:-0}" != "1" ]]; then
  missing=0
  for cmd in bash git nix ssh sshpass tar base64 sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing=1
      break
    fi
  done

  if [[ "$missing" == "1" ]]; then
    exec nix shell \
      nixpkgs#bash \
      nixpkgs#coreutils \
      nixpkgs#git \
      nixpkgs#gnutar \
      nixpkgs#nix \
      nixpkgs#openssh \
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
  printf '[recover] %s\n' "$*"
}

fail() {
  printf '[recover] ERROR: %s\n' "$*" >&2
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
    run_local_shell "cd '$repo' && git add -A && git commit -m '$message' && git push origin main"
  else
    log "No local changes in $(basename "$repo"); skipping commit"
  fi
}

validate_local_builds() {
  log "Validating nix-cluster locally"
  run_local_shell "cd '$NIX_CLUSTER_REPO' && nix build .#default && nix build .#install"

  log "Validating homelab-fleet against local nix-cluster"
  run_local_shell "cd '$FLEET_REPO' && \
    nix build .#nixosConfigurations.node1.config.system.build.toplevel --override-input nixCluster path:$NIX_CLUSTER_REPO && \
    nix build .#nixosConfigurations.node2.config.system.build.toplevel --override-input nixCluster path:$NIX_CLUSTER_REPO && \
    nix build .#nixosConfigurations.node4.config.system.build.toplevel --override-input nixCluster path:$NIX_CLUSTER_REPO"
}

update_fleet_lock() {
  log "Updating homelab-fleet flake.lock"
  run_local_shell "cd '$FLEET_REPO' && nix flake lock --update-input nixCluster"
}

validate_fleet_locked() {
  log "Validating homelab-fleet with locked inputs"
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

sync_fleet_tree() {
  local node_name="$1"
  local node_ip="$2"

  log "Syncing homelab-fleet checkout to ${node_name} staging path"
  run_local_shell "tar --exclude=result --exclude=.direnv -cf - -C '$FLEET_REPO' ." | \
    ssh_as_local_user "moss@${node_ip}" "rm -rf /home/moss/homelab-fleet-recovery && mkdir -p /home/moss/homelab-fleet-recovery && tar -xf - -C /home/moss/homelab-fleet-recovery"
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
  printf '%s' "$REMOTE_SUDO_PASSWORD_B64" | base64 -d
}

sudo_run() {
  local password
  password="$(sudo_password)"
  printf '%s\n' "$password" | sudo -S -p '' "$@"
}

fleet_origin() {
  printf '%s' "$FLEET_ORIGIN_B64" | base64 -d
}

ensure_runtime_dirs() {
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0755 /home/nix-cluster
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0700 /home/nix-cluster/.ssh
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0755 /home/nix-cluster/log
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0755 /var/lib/nops
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0755 /var/lib/nops/ha
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0755 /var/lib/nops/metrics
  sudo_run install -d -o nix-cluster -g nix-cluster -m 0755 /var/lib/nops-heartbeat
}

install_service_repo_from_stage() {
  local origin
  origin="$(fleet_origin)"

  sudo_run rm -rf /home/nix-cluster/homelab-fleet
  sudo_run cp -a /home/moss/homelab-fleet-recovery /home/nix-cluster/homelab-fleet
  sudo_run chown -R nix-cluster:nix-cluster /home/nix-cluster/homelab-fleet
  sudo_run -u nix-cluster git -C /home/nix-cluster/homelab-fleet remote set-url origin "$origin"
  sudo_run -u nix-cluster git -C /home/nix-cluster/homelab-fleet config --global --add safe.directory /home/nix-cluster/homelab-fleet || true
  sudo_run find /home/nix-cluster/homelab-fleet/.git -name '*.lock' -delete 2>/dev/null || true
}

rebuild_from_stage() {
  sudo_run systemctl stop nix-cluster || true
  sudo_run nixos-rebuild switch --flake /home/moss/homelab-fleet-recovery#${node_name} --impure
}

repair_node1() {
  sudo_run systemctl stop nix-cluster || true

  if [[ ! -e /home/nix-cluster/.ssh/id_ed25519 && -d /home/nops/.ssh ]]; then
    sudo_run cp -a /home/nops/.ssh/. /home/nix-cluster/.ssh/
  fi

  ensure_runtime_dirs
  install_service_repo_from_stage

  sudo_run chown -R nix-cluster:nix-cluster /home/nix-cluster
  sudo_run chown -R nix-cluster:nix-cluster /var/lib/nops /var/lib/nops-heartbeat
  sudo_run chmod 700 /home/nix-cluster/.ssh 2>/dev/null || true
  sudo_run chmod 600 /home/nix-cluster/.ssh/id_ed25519 2>/dev/null || true
  sudo_run chmod 644 /home/nix-cluster/.ssh/id_ed25519.pub 2>/dev/null || true

  sudo_run systemctl restart nix-cluster
  sudo_run systemctl status nix-cluster --no-pager -l || true
  sudo_run journalctl -u nix-cluster -n 200 --no-pager || true
}

bootstrap_worker() {
  sudo_run systemctl stop nix-cluster || true
  ensure_runtime_dirs
  install_service_repo_from_stage
  sudo_run chown -R nix-cluster:nix-cluster /home/nix-cluster
  sudo_run chown -R nix-cluster:nix-cluster /var/lib/nops /var/lib/nops-heartbeat
  sudo_run systemctl restart nix-cluster
  sudo_run systemctl status nix-cluster --no-pager -l || true
  sudo_run journalctl -u nix-cluster -n 200 --no-pager || true
}

verify_controller() {
  sudo_run systemctl status nix-cluster --no-pager || true
  sudo_run systemctl status nix-cluster-runtime-store --no-pager || true
  sudo_run systemctl status caddy --no-pager || true
  sudo_run systemctl status cloudflared --no-pager || true
  sudo_run systemctl status keepalived --no-pager || true
  sudo_run systemctl status pixiecore --no-pager || true
  sudo_run systemctl status postgresqlBackup.timer --no-pager || true
  sudo_run -u nix-cluster /run/current-system/sw/bin/nops-fleet-status || true
  curl -fsS http://127.0.0.1:2379/health || true
  if command -v etcdctl >/dev/null 2>&1; then
    sudo_run env ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 get --prefix /nix-cluster/inventory || true
    sudo_run env ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 get --prefix /nix-cluster/join || true
  fi
  sudo_run ls -lah /var/lib/nops/ha || true
  sudo_run ls -lah /var/lib/nops/metrics || true
  curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null | grep -E 'nix_cluster|nops' || true
}

verify_worker() {
  sudo_run systemctl status nix-cluster --no-pager || true
  sudo_run systemctl status caddy --no-pager || true
  sudo_run systemctl status cloudflared --no-pager || true
  sudo_run systemctl status keepalived --no-pager || true
  sudo_run ls -lah /var/lib/nops/ha || true
  sudo_run ls -lah /var/lib/nops/metrics || true
  curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null | grep -E 'nix_cluster|nops' || true
  systemctl is-enabled pixiecore || true
  systemctl is-active pixiecore || true
  systemctl is-enabled postgresqlBackup.timer || true
  systemctl is-active postgresqlBackup.timer || true
}

case "$action" in
  rebuild-from-stage)
    rebuild_from_stage
    ;;
  repair-node1)
    repair_node1
    ;;
  bootstrap-worker)
    bootstrap_worker
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

main() {
  require_root
  require_cmd bash git nix ssh sshpass tar base64 sudo

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

  LOG_ROOT="/var/log/nix-cluster-recovery-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOG_ROOT"

  local password
  read -rsp "Remote login/sudo password for moss on node1/node2/node4: " password
  echo
  [[ -n "$password" ]] || fail "Password is required"
  REMOTE_SUDO_PASSWORD_B64="$(printf '%s' "$password" | base64 -w0)"
  REMOTE_LOGIN_PASSWORD_B64="$REMOTE_SUDO_PASSWORD_B64"
  unset password

  validate_local_builds
  commit_and_push_if_dirty "$NIX_CLUSTER_REPO" "feat: automate node1 node2 node4 recovery"
  update_fleet_lock
  validate_fleet_locked
  commit_and_push_if_dirty "$FLEET_REPO" "chore: deploy latest nix-cluster recovery state"

  FLEET_ORIGIN_B64="$(run_local_shell "cd '$FLEET_REPO' && git remote get-url origin | sed -E 's|^https?://[^/@]+:[^/@]+@|https://|'" | tr -d '\n' | base64 -w0)"

  sync_fleet_tree node1 192.168.2.201
  remote_action node1 192.168.2.201 rebuild-from-stage "$LOG_ROOT/node1-rebuild.log"
  remote_action node1 192.168.2.201 repair-node1 "$LOG_ROOT/node1-repair.log"
  remote_action node1 192.168.2.201 verify-controller "$LOG_ROOT/node1-verify.log"

  sync_fleet_tree node2 192.168.2.202
  remote_action node2 192.168.2.202 rebuild-from-stage "$LOG_ROOT/node2-rebuild.log"
  remote_action node2 192.168.2.202 bootstrap-worker "$LOG_ROOT/node2-bootstrap.log"
  remote_action node2 192.168.2.202 verify-worker "$LOG_ROOT/node2-verify.log"

  sync_fleet_tree node4 192.168.2.204
  remote_action node4 192.168.2.204 rebuild-from-stage "$LOG_ROOT/node4-rebuild.log"
  remote_action node4 192.168.2.204 bootstrap-worker "$LOG_ROOT/node4-bootstrap.log"
  remote_action node4 192.168.2.204 verify-worker "$LOG_ROOT/node4-verify.log"

  log "Recovery complete. Logs are in $LOG_ROOT"
}

main "$@"
