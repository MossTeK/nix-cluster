#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
	nix-cluster-fleet-watch [--interval SECONDS] [--initial] [hostname|ip ...]

Examples:
	nix-cluster-fleet-watch
	nix-cluster-fleet-watch --interval 3
	nix-cluster-fleet-watch --initial node2 node4
EOF
}

interval=5
show_initial="false"
declare -a filters=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--interval)
			interval="${2:-}"
			shift 2
			;;
		--initial)
			show_initial="true"
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

if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
	echo "--interval must be a positive integer" >&2
	exit 1
fi

fetch_snapshot() {
	if [ "${#filters[@]}" -gt 0 ]; then
		nix-cluster-fleet-status --json "${filters[@]}"
	else
		nix-cluster-fleet-status --json
	fi
}

normalize_snapshot() {
	jq -r '
		.[] as $host |
		if ($host.reachable | not) then
			[$host.hostname, $host.ip, "__host__", "unreachable", "false"] | @tsv
		else
			$host.units[]? |
			[$host.hostname, $host.ip, (.unit // .requested_unit), .active_state, (.healthy | tostring)] | @tsv
		end
	'
}

print_change() {
	local hostname="$1"
	local ip="$2"
	local unit="$3"
	local active="$4"
	local healthy="$5"
	local timestamp
	timestamp=$(date --iso-8601=seconds)

	if [ "$unit" = "__host__" ]; then
		printf '[%s] %s (%s) unreachable\n' "$timestamp" "$hostname" "$ip"
		return 0
	fi

	printf '[%s] %s (%s) %s => active=%s healthy=%s\n' "$timestamp" "$hostname" "$ip" "$unit" "$active" "$healthy"
}

previous=""
first_pass="true"

while true; do
	if snapshot=$(fetch_snapshot 2>/dev/null); then
		current=$(printf '%s\n' "$snapshot" | normalize_snapshot | sort)
	else
		current=""
	fi

	if [ "$first_pass" = "true" ]; then
		if [ "$show_initial" = "true" ] && [ -n "$current" ]; then
			while IFS=$'\t' read -r hostname ip unit active healthy; do
				print_change "$hostname" "$ip" "$unit" "$active" "$healthy"
			done <<< "$current"
		fi
		previous="$current"
		first_pass="false"
		sleep "$interval"
		continue
	fi

	changes=$(comm -3 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") | sed '/^$/d' || true)
	if [ -n "$changes" ]; then
		while IFS=$'\t' read -r hostname ip unit active healthy; do
			[ -n "$hostname" ] || continue
			print_change "$hostname" "$ip" "$unit" "$active" "$healthy"
		done <<< "$current"
	fi

	previous="$current"
	sleep "$interval"
done
