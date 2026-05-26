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

usage() {
	cat <<'EOF'
Usage:
	NIX_CLUSTER_SOPS_KEY_FILE=/var/lib/sops-nix/key.txt nix-cluster-secret-ensure [options] secret[=generator:length] ...

Examples:
	nix-cluster-secret-ensure outline_secret_key=hex:64
	nix-cluster-secret-ensure --json --git-sync outline_secret_key=hex:64 outline_utils_secret=hex:64

Options:
	--json                 Emit a JSON object of secret names to values.
	--git-sync             Commit and push the tracked secret file when new secrets are generated.
	--sops-file <path>     Relative path inside the fleet repo. Defaults to secrets/secrets.yaml.
	--default-generator <name>
	                       Default generator for specs without an explicit generator. Defaults to base64.
	--default-length <n>   Default generated length. Defaults to 48.
	-q, --quiet            Suppress non-fatal status messages.
	-h, --help             Show this help.

Supported generators:
	base64, hex, alnum
EOF
}

is_positive_integer() {
	case "$1" in
		""|*[!0-9]*)
			return 1
			;;
		*)
			[ "$1" -gt 0 ]
			;;
	esac
}

generate_secret() {
	local generator="$1"
	local length="$2"
	local result=""
	local bytes

	case "$generator" in
		hex)
			bytes=$(( (length + 1) / 2 ))
			openssl rand -hex "$bytes" | tr -d '\n' | cut -c1-"$length"
			return 0
			;;
		base64)
			bytes=$(( length + 8 ))
			while [ "${#result}" -lt "$length" ]; do
				result="${result}$(openssl rand -base64 "$bytes" | tr -d '\n=' | tr '/+' '_-')"
			done
			printf '%s\n' "${result:0:length}"
			return 0
			;;
		alnum)
			bytes=$(( length + 8 ))
			while [ "${#result}" -lt "$length" ]; do
				result="${result}$(openssl rand -base64 "$bytes" | tr -dc 'A-Za-z0-9')"
			done
			printf '%s\n' "${result:0:length}"
			return 0
			;;
		*)
			echo "Unsupported generator: $generator" >&2
			return 1
			;;
	esac
}

CONFIG_PATH="$(resolve_runtime_config_path)"
SOPS_KEY="${NIX_CLUSTER_SOPS_KEY_FILE:-${NOPS_SOPS_KEY_FILE:-/var/lib/sops-nix/key.txt}}"
SOPS_FILE_REL="secrets/secrets.yaml"
DEFAULT_GENERATOR="base64"
DEFAULT_LENGTH=48
JSON_OUTPUT="false"
GIT_SYNC="false"
QUIET="false"

declare -a SECRET_SPECS=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--json)
			JSON_OUTPUT="true"
			shift
			;;
		--git-sync)
			GIT_SYNC="true"
			shift
			;;
		--sops-file)
			SOPS_FILE_REL="$2"
			shift 2
			;;
		--default-generator)
			DEFAULT_GENERATOR="$2"
			shift 2
			;;
		--default-length)
			DEFAULT_LENGTH="$2"
			shift 2
			;;
		-q|--quiet)
			QUIET="true"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			while [ "$#" -gt 0 ]; do
				SECRET_SPECS+=("$1")
				shift
			done
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			SECRET_SPECS+=("$1")
			shift
			;;
	esac
done

if [ "${#SECRET_SPECS[@]}" -eq 0 ]; then
	echo "At least one secret spec is required." >&2
	usage >&2
	exit 1
fi

if ! is_positive_integer "$DEFAULT_LENGTH"; then
	echo "Default length must be a positive integer: $DEFAULT_LENGTH" >&2
	exit 1
fi

if [ ! -r "$CONFIG_PATH" ]; then
	echo "Missing runtime config at $CONFIG_PATH" >&2
	exit 1
fi

REPO_PATH=$(jq -r '.directories.repo // empty' "$CONFIG_PATH")
UPDATE_REMOTE=$(jq -r '.update.remote_name // "origin"' "$CONFIG_PATH")
UPDATE_BRANCH_REF=$(jq -r '.update.branch_ref // "origin/main"' "$CONFIG_PATH")

if [ -z "$REPO_PATH" ]; then
	echo "Repo path not defined in $CONFIG_PATH" >&2
	exit 1
fi

if [[ "$SOPS_FILE_REL" = /* ]]; then
	SOPS_FILE="$SOPS_FILE_REL"
else
	SOPS_FILE="$REPO_PATH/$SOPS_FILE_REL"
fi

if [ ! -f "$SOPS_FILE" ]; then
	echo "Missing SOPS file at $SOPS_FILE" >&2
	exit 1
fi

if [ ! -r "$SOPS_KEY" ]; then
	echo "Missing SOPS age key at $SOPS_KEY" >&2
	exit 1
fi

if [[ "$UPDATE_BRANCH_REF" == "$UPDATE_REMOTE/"* ]]; then
	UPDATE_BRANCH_NAME="${UPDATE_BRANCH_REF#${UPDATE_REMOTE}/}"
else
	UPDATE_BRANCH_NAME="$UPDATE_BRANCH_REF"
fi

DECRYPTED_JSON=$(SOPS_AGE_KEY_FILE="$SOPS_KEY" sops decrypt --output-type json "$SOPS_FILE")
RESULT_JSON='{}'
CHANGED="false"
declare -a CHANGED_NAMES=()

for spec in "${SECRET_SPECS[@]}"; do
	secret_name="$spec"
	secret_generator="$DEFAULT_GENERATOR"
	secret_length="$DEFAULT_LENGTH"

	if [[ "$spec" == *=* ]]; then
		secret_name="${spec%%=*}"
		secret_meta="${spec#*=}"
		if [[ "$secret_meta" == *:* ]]; then
			secret_generator="${secret_meta%%:*}"
			secret_length="${secret_meta#*:}"
		elif [ -n "$secret_meta" ]; then
			secret_generator="$secret_meta"
		fi
	fi

	if [ -z "$secret_name" ]; then
		echo "Invalid secret spec: $spec" >&2
		exit 1
	fi

	if ! is_positive_integer "$secret_length"; then
		echo "Secret length must be a positive integer for $secret_name: $secret_length" >&2
		exit 1
	fi

	secret_value=$(printf '%s' "$DECRYPTED_JSON" | jq -r --arg name "$secret_name" '.[$name] // empty')
	if [ -z "$secret_value" ]; then
		secret_value=$(generate_secret "$secret_generator" "$secret_length")
		printf '%s' "$(jq -cn --arg value "$secret_value" '$value')" \
			| SOPS_AGE_KEY_FILE="$SOPS_KEY" sops --input-type yaml --output-type yaml -i set --value-stdin "$SOPS_FILE" "[\"$secret_name\"]" >/dev/null
		DECRYPTED_JSON=$(printf '%s' "$DECRYPTED_JSON" | jq --arg name "$secret_name" --arg value "$secret_value" '. + {($name): $value}')
		CHANGED="true"
		CHANGED_NAMES+=("$secret_name")
		if [ "$QUIET" != "true" ]; then
			echo "Generated $secret_name in $SOPS_FILE" >&2
		fi
	fi

	RESULT_JSON=$(printf '%s' "$RESULT_JSON" | jq --arg name "$secret_name" --arg value "$secret_value" '. + {($name): $value}')
done

if [ "$GIT_SYNC" = "true" ] && [ "$CHANGED" = "true" ]; then
	if [ ! -d "$REPO_PATH/.git" ]; then
		echo "warning: repo path is not a git repository, skipping push" >&2
	else
		relative_sops_file="$SOPS_FILE"
		if [[ "$SOPS_FILE" == "$REPO_PATH/"* ]]; then
			relative_sops_file="${SOPS_FILE#${REPO_PATH}/}"
		fi

		git -C "$REPO_PATH" add -- "$relative_sops_file"
		if ! git -C "$REPO_PATH" diff --cached --quiet -- "$relative_sops_file"; then
			commit_targets=$(printf '%s\n' "${CHANGED_NAMES[@]}" | paste -sd ',' -)
			git -C "$REPO_PATH" \
				-c user.name="nix-cluster" \
				-c user.email="nix-cluster@$(hostname)" \
				commit -m "nix-cluster: ensure ${commit_targets} [skip nix-cluster]" >/dev/null

			if git -C "$REPO_PATH" push "$UPDATE_REMOTE" "HEAD:${UPDATE_BRANCH_NAME}" >/dev/null 2>&1; then
				if [ "$QUIET" != "true" ]; then
					echo "Pushed generated secrets to ${UPDATE_REMOTE}/${UPDATE_BRANCH_NAME}" >&2
				fi
			else
				echo "failed to push generated secrets to ${UPDATE_REMOTE}/${UPDATE_BRANCH_NAME}" >&2
				exit 1
			fi
		fi
	fi
fi

if [ "$JSON_OUTPUT" = "true" ]; then
	printf '%s\n' "$RESULT_JSON"
	exit 0
fi

printf '%s\n' "$RESULT_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"'