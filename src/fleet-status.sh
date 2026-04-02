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

CONFIG_PATH="$(resolve_runtime_config_path)"
SOPS_KEY="${NIX_CLUSTER_SOPS_KEY_FILE:-${NOPS_SOPS_KEY_FILE:-/var/lib/sops-nix/key.txt}}"

usage() {
	cat <<'EOF'
Usage:
	nix-cluster-fleet-status [--json] [hostname|ip ...]

Examples:
	nix-cluster-fleet-status
	nix-cluster-fleet-status node2 192.168.2.204
	nix-cluster-fleet-status --json
EOF
}

if [ ! -r "$CONFIG_PATH" ]; then
	echo "Missing runtime config at $CONFIG_PATH" >&2
	exit 1
fi

REPO_PATH=$(jq -r '.directories.repo // empty' "$CONFIG_PATH")
if [ -z "$REPO_PATH" ]; then
	echo "Repo path not defined in $CONFIG_PATH" >&2
	exit 1
fi

DEPLOYMENTS_JSON="$REPO_PATH/deployments.json"
if [ ! -f "$DEPLOYMENTS_JSON" ]; then
	echo "Missing deployments inventory at $DEPLOYMENTS_JSON" >&2
	exit 1
fi

read_deployments() {
	if sudo env SOPS_AGE_KEY_FILE="$SOPS_KEY" sops -d "$DEPLOYMENTS_JSON" 2>/dev/null; then
		return 0
	fi

	cat "$DEPLOYMENTS_JSON"
}

json_output="false"
declare -a filters=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--json)
			json_output="true"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			filters+=("$1")
			shift
			;;
	esac
done

LOCAL_HOSTNAME=$(hostname)
TMP_DEPLOYMENTS=$(mktemp)
trap 'rm -f "$TMP_DEPLOYMENTS"' EXIT
read_deployments > "$TMP_DEPLOYMENTS"

matches_filter() {
	local hostname="$1"
	local ip="$2"

	if [ "${#filters[@]}" -eq 0 ]; then
		return 0
	fi

	local filter
	for filter in "${filters[@]}"; do
		if [ "$filter" = "$hostname" ] || [ "$filter" = "$ip" ]; then
			return 0
		fi
	done

	return 1
}

if [ "$json_output" = "true" ]; then
	OUTPUT=$(mktemp)
	trap 'rm -f "$TMP_DEPLOYMENTS" "$OUTPUT"' EXIT
	: > "$OUTPUT"
fi

while IFS=$'\t' read -r hostname ip; do
	if [ -z "$hostname" ] || [ -z "$ip" ]; then
		continue
	fi

	if [ "$hostname" = "$LOCAL_HOSTNAME" ]; then
		continue
	fi

	if ! matches_filter "$hostname" "$ip"; then
		continue
	fi

	if [ "$json_output" = "true" ]; then
		if remote_json=$(nix-cluster-node status "$ip" --json 2>/dev/null); then
			jq -n --arg hostname "$hostname" --arg ip "$ip" --argjson units "$remote_json" '{hostname: $hostname, ip: $ip, reachable: true, units: $units}' >> "$OUTPUT"
		else
			jq -n --arg hostname "$hostname" --arg ip "$ip" '{hostname: $hostname, ip: $ip, reachable: false, units: []}' >> "$OUTPUT"
		fi
		continue
	fi

	echo "=== $hostname ($ip) ==="
	if ! nix-cluster-node status "$ip"; then
		echo "unreachable"
	fi
	echo
done < <(jq -r '.[] | [.hostname, .installer_ip] | @tsv' "$TMP_DEPLOYMENTS")

if [ "$json_output" = "true" ]; then
	jq -s '.' "$OUTPUT"
fi
