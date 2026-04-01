#!/usr/bin/env bash
set -euo pipefail

NOPS_SSH_KEY="${NOPS_CONTROLLER_SSH_KEY:-/home/nops/.ssh/id_ed25519}"
NOPS_REMOTE_USER="${NOPS_REMOTE_USER:-nops}"

SSH_OPTS=(
	-i "$NOPS_SSH_KEY"
	-o BatchMode=yes
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o ConnectTimeout=5
)

usage() {
	cat <<'EOF'
Usage:
	nops-node status <host|user@host> [--json] [unit ...]
	nops-node journal <host|user@host> [journalctl flags]

Examples:
	nops-node status 192.168.2.202
	nops-node status node2 --json
	nops-node journal node2 -u nix-cluster.service -n 100
	nops-node journal node2 -f --since '-5 min'
EOF
}

target_spec() {
	local target="$1"
	if [[ "$target" == *@* ]]; then
		printf '%s\n' "$target"
	else
		printf '%s@%s\n' "$NOPS_REMOTE_USER" "$target"
	fi
}

run_remote() {
	local target="$1"
	shift
	ssh "${SSH_OPTS[@]}" "$(target_spec "$target")" "$@"
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
		run_remote "$target" sudo /run/current-system/sw/bin/nops-observe status "$@"
		;;
	journal)
		run_remote "$target" sudo /run/current-system/sw/bin/nops-observe journal "$@"
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
