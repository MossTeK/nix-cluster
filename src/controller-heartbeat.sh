#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${NOPS_RUNTIME_CONFIG_PATH:-${NOPS_CONFIG_PATH:-/etc/nops-runtime-config.json}}"
STATE_DIR="${NOPS_HEARTBEAT_STATE_DIR:-/var/lib/nops-heartbeat}"
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
