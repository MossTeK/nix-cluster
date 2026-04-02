#!/usr/bin/env bash
set -euo pipefail

resolve_runtime_config_path() {
	local candidate
	for candidate in \
		"${NIX_CLUSTER_RUNTIME_CONFIG_PATH:-}" \
		"${NIX_CLUSTER_CONFIG_PATH:-}" \
		"${NOPS_RUNTIME_CONFIG_PATH:-}" \
		"${NOPS_CONFIG_PATH:-}" \
		"/etc/nix-cluster-runtime-config.json" \
		"/etc/nops-runtime-config.json"
	do
		if [ -n "$candidate" ] && [ -r "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	printf '%s\n' "${NIX_CLUSTER_RUNTIME_CONFIG_PATH:-${NIX_CLUSTER_CONFIG_PATH:-${NOPS_RUNTIME_CONFIG_PATH:-${NOPS_CONFIG_PATH:-/etc/nix-cluster-runtime-config.json}}}}"
}

NIX_CLUSTER_SSH_KEY="${NIX_CLUSTER_CONTROLLER_SSH_KEY:-${NOPS_CONTROLLER_SSH_KEY:-/home/nix-cluster/.ssh/id_ed25519}}"
NIX_CLUSTER_REMOTE_USER="${NIX_CLUSTER_REMOTE_USER:-${NOPS_REMOTE_USER:-nix-cluster}}"
CONFIG_PATH="$(resolve_runtime_config_path)"
SOPS_KEY="${NIX_CLUSTER_SOPS_KEY_FILE:-${NOPS_SOPS_KEY_FILE:-/var/lib/sops-nix/key.txt}}"

SSH_OPTS=(
	-i "$NIX_CLUSTER_SSH_KEY"
	-o BatchMode=yes
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o ConnectTimeout=5
)

read_deployments() {
	local repo_path
	repo_path=$(jq -r '.directories.repo // empty' "$CONFIG_PATH" 2>/dev/null || true)
	if [ -z "$repo_path" ] || [ ! -f "$repo_path/deployments.json" ]; then
		return 1
	fi

	if sudo env SOPS_AGE_KEY_FILE="$SOPS_KEY" sops -d "$repo_path/deployments.json" 2>/dev/null; then
		return 0
	fi

	cat "$repo_path/deployments.json"
}

lookup_target_json() {
	local target="$1"
	local host="$target"
	if [[ "$host" == *@* ]]; then
		host="${host#*@}"
	fi

	read_deployments | jq -c --arg host "$host" '.[] | select(.hostname == $host or .installer_ip == $host)' | head -n 1
}

target_spec() {
	local target="$1"
	if [[ "$target" == *@* ]]; then
		printf '%s\n' "$target"
	else
		printf '%s@%s\n' "$NIX_CLUSTER_REMOTE_USER" "$target"
	fi
}

run_with_key() {
	local remote="$1"
	shift
	ssh "${SSH_OPTS[@]}" "$remote" "$@"
}

run_with_password() {
	local password="$1"
	local remote="$2"
	shift 2
	SSHPASS="$password" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$remote" "$@"
}

remote_sudo_command() {
	local sudo_password="$1"
	shift
	local cmd=("$@")
	if [ -n "$sudo_password" ]; then
		printf "printf '%%s\\n' %q | sudo -S" "$sudo_password"
	else
		printf "sudo -n"
	fi
	local arg
	for arg in "${cmd[@]}"; do
		printf ' %q' "$arg"
	done
	printf '\n'
}

usage() {
	cat <<'EOF'
Usage:
	nix-cluster-node status <host|user@host> [--json] [unit ...]
	nix-cluster-node journal <host|user@host> [journalctl flags]

Examples:
	nix-cluster-node status 192.168.2.202
	nix-cluster-node status node2 --json
	nix-cluster-node journal node2 -u nix-cluster.service -n 100
	nix-cluster-node journal node2 -f --since '-5 min'
EOF
}

run_remote() {
	local target="$1"
	shift

	if [[ "$target" == *@* ]]; then
		run_with_key "$target" "$@"
		return $?
	fi

	local remote_default
	remote_default="$(target_spec "$target")"
	if run_with_key "$remote_default" "$@"; then
		return 0
	fi

	local target_json=""
	target_json=$(lookup_target_json "$target" 2>/dev/null || true)
	if [ -z "$target_json" ]; then
		return 1
	fi

	local admin_user admin_pass remote_admin sudo_cmd
	admin_user=$(printf '%s\n' "$target_json" | jq -r '.node_admin // empty')
	admin_pass=$(printf '%s\n' "$target_json" | jq -r '.node_admin_pass // empty')
	if [ -z "$admin_user" ]; then
		return 1
	fi

	remote_admin="$admin_user@${target#*@}"
	sudo_cmd=$(remote_sudo_command "$admin_pass" "$@")

	if run_with_key "$remote_admin" "$sudo_cmd"; then
		return 0
	fi

	if [ -n "$admin_pass" ]; then
		run_with_password "$admin_pass" "$remote_admin" "$sudo_cmd"
		return $?
	fi

	return 1
}

if [ "$#" -lt 2 ]; then
	usage
	exit 1
fi

command="$1"
target="$2"
shift 2

case "$command" in
	status)
		run_remote "$target" sudo /run/current-system/sw/bin/nix-cluster-observe status "$@"
		;;
	journal)
		run_remote "$target" sudo /run/current-system/sw/bin/nix-cluster-observe journal "$@"
		;;
	-h|--help|help)
		usage
		;;
	*)
		echo "Unknown command: $command" >&2
		usage
		exit 1
		;;
esac