#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${NOPS_RUNTIME_CONFIG_PATH:-${NOPS_CONFIG_PATH:-/etc/nops-runtime-config.json}}"

usage() {
	cat <<'EOF'
Usage:
	nops-observe status [--json] [unit ...]
	nops-observe journal [journalctl flags]

Examples:
	nops-observe status
	nops-observe status --json nix-cluster.service caddy.service
	nops-observe journal -u nix-cluster.service -n 100
	nops-observe journal -f --since '-5 min'
EOF
}

have_config() {
	[ -r "$CONFIG_PATH" ]
}

default_units() {
	if have_config; then
		jq -r '.observability.tracked_units[]?' "$CONFIG_PATH"
	fi
}

collect_status() {
	local requested_unit="$1"

	if ! systemctl show "$requested_unit" --property=Id >/dev/null 2>&1; then
		jq -n \
			--arg requested_unit "$requested_unit" \
			'{
				requested_unit: $requested_unit,
				unit: $requested_unit,
				load_state: "not-found",
				active_state: "unknown",
				sub_state: "unknown",
				unit_file_state: "unknown",
				result: "unknown",
				exec_main_pid: "0",
				exec_main_status: "0",
				active_enter_timestamp: "",
				healthy: false
			}'
		return 0
	fi

	local id=""
	local load_state=""
	local active_state=""
	local sub_state=""
	local unit_file_state=""
	local result=""
	local exec_main_pid=""
	local exec_main_status=""
	local active_enter_timestamp=""

	while IFS='=' read -r key value; do
		case "$key" in
			Id) id="$value" ;;
			LoadState) load_state="$value" ;;
			ActiveState) active_state="$value" ;;
			SubState) sub_state="$value" ;;
			UnitFileState) unit_file_state="$value" ;;
			Result) result="$value" ;;
			ExecMainPID) exec_main_pid="$value" ;;
			ExecMainStatus) exec_main_status="$value" ;;
			ActiveEnterTimestamp) active_enter_timestamp="$value" ;;
		esac
	done < <(
		systemctl show "$requested_unit" \
			--property=Id \
			--property=LoadState \
			--property=ActiveState \
			--property=SubState \
			--property=UnitFileState \
			--property=Result \
			--property=ExecMainPID \
			--property=ExecMainStatus \
			--property=ActiveEnterTimestamp
	)

	local healthy="false"
	if [ "$load_state" = "loaded" ] && { [ "$active_state" = "active" ] || [ "$active_state" = "activating" ] || [ "$active_state" = "reloading" ]; }; then
		healthy="true"
	fi

	jq -n \
		--arg requested_unit "$requested_unit" \
		--arg unit "$id" \
		--arg load_state "$load_state" \
		--arg active_state "$active_state" \
		--arg sub_state "$sub_state" \
		--arg unit_file_state "$unit_file_state" \
		--arg result "$result" \
		--arg exec_main_pid "$exec_main_pid" \
		--arg exec_main_status "$exec_main_status" \
		--arg active_enter_timestamp "$active_enter_timestamp" \
		--argjson healthy "$healthy" \
		'{
			requested_unit: $requested_unit,
			unit: $unit,
			load_state: $load_state,
			active_state: $active_state,
			sub_state: $sub_state,
			unit_file_state: $unit_file_state,
			result: $result,
			exec_main_pid: $exec_main_pid,
			exec_main_status: $exec_main_status,
			active_enter_timestamp: $active_enter_timestamp,
			healthy: $healthy
		}'
}

status_command() {
	local json_output="false"
	local -a units=()

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
				units+=("$1")
				shift
				;;
		esac
	done

	if [ "${#units[@]}" -eq 0 ]; then
		mapfile -t units < <(default_units)
	fi

	if [ "${#units[@]}" -eq 0 ]; then
		units=("nix-cluster.service")
	fi

	local tmp_json
	tmp_json=$(mktemp)
	trap 'rm -f "$tmp_json"' RETURN

	: > "$tmp_json"
	for unit in "${units[@]}"; do
		collect_status "$unit" >> "$tmp_json"
	done

	if [ "$json_output" = "true" ]; then
		jq -s '.' "$tmp_json"
		return 0
	fi

	printf '%-28s %-12s %-14s %-12s %-12s %s\n' "UNIT" "ACTIVE" "SUB" "LOAD" "FILE" "LAST CHANGE"
	jq -r '. | [(.unit // .requested_unit), .active_state, .sub_state, .load_state, .unit_file_state, (.active_enter_timestamp // "")] | @tsv' "$tmp_json" | \
		while IFS=$'\t' read -r unit active sub load file_state changed; do
			printf '%-28s %-12s %-14s %-12s %-12s %s\n' "$unit" "$active" "$sub" "$load" "$file_state" "$changed"
		done
}

journal_command() {
	local -a args=("$@")
	local has_unit="false"
	local follow="false"
	local pager_set="false"

	local index=0
	while [ "$index" -lt "${#args[@]}" ]; do
		case "${args[$index]}" in
			-u|--unit)
				has_unit="true"
				index=$((index + 2))
				continue
				;;
			--unit=*)
				has_unit="true"
				;;
			-f|--follow)
				follow="true"
				;;
			--no-pager|--pager-end)
				pager_set="true"
				;;
		esac

		index=$((index + 1))
	done

	if [ "$has_unit" = "false" ]; then
		local -a units=()
		mapfile -t units < <(default_units)
		if [ "${#units[@]}" -eq 0 ]; then
			units=("nix-cluster.service")
		fi
		for unit in "${units[@]}"; do
			args=(-u "$unit" "${args[@]}")
		done
	fi

	if [ "$follow" = "false" ] && [ "$pager_set" = "false" ]; then
		args=(--no-pager "${args[@]}")
	fi

	exec journalctl "${args[@]}"
}

if [ "$#" -lt 1 ]; then
	usage
	exit 1
fi

command="$1"
shift

case "$command" in
	status)
		status_command "$@"
		;;
	journal)
		journal_command "$@"
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
