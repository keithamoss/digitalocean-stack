#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
NGINX_DIR="$SCRIPT_DIR/../nginx"

skip_download=0

for arg in "$@"; do
	case "$arg" in
		--skip-download)
			skip_download=1
			;;
		*)
			echo "Unknown option: $arg" >&2
			exit 1
			;;
	esac
done

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

main() {
	require_command docker
	require_command git

	if [[ "$skip_download" -eq 0 ]]; then
		require_command python3
		if [[ -f "$NGINX_DIR/secrets/github.env" ]]; then
			set -a
			. "$NGINX_DIR/secrets/github.env"
			set +a
		else
			echo "Missing $NGINX_DIR/secrets/github.env (expected GITHUB_TOKEN)." >&2
			exit 1
		fi

		if ! python3 "$NGINX_DIR/download-artifacts.py"; then
			echo "Artifact download failed; skipping nginx restart." >&2
			exit 1
		fi
	else
		echo "Skipping artifact download as requested." >&2
	fi

  # git pull origin master
	docker compose -f "$NGINX_DIR/compose.yml" pull
	docker compose -f "$NGINX_DIR/compose.yml" stop
	docker compose -f "$NGINX_DIR/compose.yml" up --remove-orphans -d

	docker image prune --force
}

main "$@"