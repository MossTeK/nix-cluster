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

resolve_heartbeat_state_dir() {
	local candidate
	for candidate in \
		"${NIX_CLUSTER_HEARTBEAT_STATE_DIR:-}" \
		"${NOPS_HEARTBEAT_STATE_DIR:-}" \
		"/var/lib/nix-cluster-heartbeat" \
		"/var/lib/nops-heartbeat"
	do
		if [ -n "$candidate" ] && { [ -d "$candidate" ] || [ ! -e "$candidate" ]; }; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
}

CONFIG_PATH="$(resolve_runtime_config_path)"
STATE_DIR="$(resolve_heartbeat_state_dir)"
STATE_FILE="$STATE_DIR/controller-status.json"
HOSTNAME_VALUE=$(hostname)

mkdir -p "$STATE_DIR"

if [ ! -r "$CONFIG_PATH" ]; then
	echo "Missing runtime config at $CONFIG_PATH" >&2
	exit 1
fi

mapfile -t targets < <(jq -r '.controller.monitor.targets[]? | select(. != "")' "$CONFIG_PATH")

if [ "${#targets[@]}" -eq 0 ]; then
	exit 0
fi

previous_target=""
previous_reachable=""
if [ -f "$STATE_FILE" ]; then
	previous_target=$(jq -r '.target // empty' "$STATE_FILE" 2>/dev/null || true)
	previous_reachable=$(jq -r '.reachable // empty' "$STATE_FILE" 2>/dev/null || true)
fi

reachable="false"
active_target=""

for target in "${targets[@]}"; do
	if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
		reachable="true"
		active_target="$target"
		break
	fi
done

if [ -z "$active_target" ]; then
	active_target="${targets[0]}"
fi

jq -n \
	--arg target "$active_target" \
	--argjson reachable "$reachable" \
	--arg checked_at "$(date --iso-8601=seconds)" \
	'{target: $target, reachable: $reachable, checked_at: $checked_at}' > "$STATE_FILE"

if [ "$previous_target" != "$active_target" ] || [ "$previous_reachable" != "$reachable" ]; then
	if [ "$reachable" = "true" ]; then
		systemd-cat -t nix-cluster-controller-heartbeat echo "worker=$HOSTNAME_VALUE controller=$active_target status=reachable"
	else
		systemd-cat -t nix-cluster-controller-heartbeat echo "worker=$HOSTNAME_VALUE controller=$active_target status=unreachable"
	fi
fi