#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  collect-node-state.sh --local
  collect-node-state.sh --host user@host [--host user@host ...] [--ssh-opt OPT ...]

Examples:
  ./scripts/collect-node-state.sh --local
  ./scripts/collect-node-state.sh --host moss@192.168.2.201 --host moss@192.168.2.202
  ./scripts/collect-node-state.sh --host moss@node1 --ssh-opt='-i ~/.ssh/id_ed25519'

Notes:
- --local runs on the current machine.
- --host uses normal interactive ssh and does NOT force BatchMode, so password or key auth can work.
- Run with sudo locally if your node requires elevated access for systemd logs.
EOF
}

print_runtime_summary() {
  local runtime_config=""
  if [[ -f /etc/nix-cluster-runtime-config.json ]]; then
    runtime_config="/etc/nix-cluster-runtime-config.json"
  elif [[ -f /etc/nops-runtime-config.json ]]; then
    runtime_config="/etc/nops-runtime-config.json"
  fi

  if [[ -n "$runtime_config" ]]; then
    RUNTIME_CONFIG_PATH="$runtime_config" python3 - <<'PY'
import json
import os
p = os.environ["RUNTIME_CONFIG_PATH"]
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
    echo "MISSING /etc/nix-cluster-runtime-config.json"
  fi
}

print_path_state() {
  for p in \
    /home/nix-cluster \
    /home/nix-cluster/homelab-fleet \
    /home/nix-cluster/.ssh \
    /home/nix-cluster/.ssh/id_ed25519 \
    /home/nix-cluster/log \
    /home/nix-cluster/log/provisioning \
    /home/nops \
    /home/nops/homelab-fleet \
    /var/lib/nix-cluster \
    /var/lib/nix-cluster/ha \
    /var/lib/nix-cluster/metrics \
    /var/lib/nix-cluster-heartbeat \
    /var/lib/nops \
    /var/lib/nops/ha \
    /var/lib/nops/metrics \
    /var/lib/nops-heartbeat \
    /etc/nix-cluster-runtime-config.json \
    /etc/nops-runtime-config.json
  do
    if [[ -e "$p" ]]; then
      stat -c "%A %U:%G %n" "$p"
    else
      echo "MISSING $p"
    fi
  done
}

print_repo_state() {
  if [[ -d /home/nix-cluster/homelab-fleet/.git ]]; then
    sudo -u nix-cluster git -C /home/nix-cluster/homelab-fleet remote -v || true
    sudo -u nix-cluster git -C /home/nix-cluster/homelab-fleet branch --show-current || true
    sudo -u nix-cluster git -C /home/nix-cluster/homelab-fleet status --short || true
    sudo -u nix-cluster git -C /home/nix-cluster/homelab-fleet rev-parse HEAD || true
  else
    echo "MISSING /home/nix-cluster/homelab-fleet/.git"
  fi
}

print_service_state() {
  for u in \
    nix-cluster \
    caddy \
    cloudflared \
    keepalived \
    pixiecore \
    promtail \
    prometheus-node-exporter \
    postgresqlBackup.timer
  do
    echo "unit=$u enabled=$(systemctl is-enabled "$u" 2>/dev/null || true) active=$(systemctl is-active "$u" 2>/dev/null || true)"
  done
}

collect_local() {
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
  sudo systemctl status nix-cluster --no-pager -l || true

  echo
  echo "--- recent nix-cluster logs ---"
  sudo journalctl -u nix-cluster -n 120 --no-pager || true

  echo
  echo "--- ha files ---"
  ls -lah /var/lib/nix-cluster/ha 2>/dev/null || ls -lah /var/lib/nops/ha 2>/dev/null || true
  ls -lah /var/lib/nix-cluster/metrics 2>/dev/null || ls -lah /var/lib/nops/metrics 2>/dev/null || true

  echo
  echo "--- provisioning logs ---"
  find /home/nix-cluster/log/provisioning -maxdepth 3 -type f 2>/dev/null | sort | tail -n 40 || true

  echo
  echo "--- latest install log tails ---"
  latest_install_logs=$(find /home/nix-cluster/log/provisioning -name 'nixos-install.log' -type f 2>/dev/null | sort | tail -n 3)
  if [[ -n "$latest_install_logs" ]]; then
    while IFS= read -r log_path; do
      [[ -n "$log_path" ]] || continue
      echo "### $log_path ###"
      tail -n 40 "$log_path" || true
    done <<< "$latest_install_logs"
  else
    echo "No persisted worker install logs found."
  fi

  echo
  echo "--- metrics grep ---"
  curl -fsS http://127.0.0.1:9100/metrics 2>/dev/null | grep -E "nix_cluster|nops|node_systemd_unit_state" | tail -n 80 || true
}

run_remote() {
  local host="$1"
  shift || true
  echo
  echo "==================== $host ===================="
  "${ssh_cmd[@]}" "$host" "bash -s -- --local" < "$0"
}

hosts=()
ssh_opts=()
mode=""
ssh_cmd=(ssh)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      mode="local"
      shift
      ;;
    --host)
      mode="remote"
      hosts+=("$2")
      shift 2
      ;;
    --ssh-opt)
      ssh_opts+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$mode" == "local" ]]; then
  collect_local
  exit 0
fi

if [[ "$mode" == "remote" ]]; then
  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "At least one --host is required for remote mode" >&2
    exit 1
  fi

  if [[ ${#ssh_opts[@]} -gt 0 ]]; then
    ssh_cmd+=("${ssh_opts[@]}")
  fi

  for host in "${hosts[@]}"; do
    run_remote "$host"
  done
  exit 0
fi

usage >&2
exit 1
