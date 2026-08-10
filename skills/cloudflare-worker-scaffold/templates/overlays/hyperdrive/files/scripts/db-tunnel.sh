#!/usr/bin/env bash
# db-tunnel.sh — open a local TCP proxy to a private Postgres reachable through a
# Cloudflare Tunnel (Access-protected public hostname), so `wrangler dev` (or any
# Postgres client) can reach it at localhost.
#
# Prereqs:
#   - cloudflared installed:
#       https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
#   - A public hostname route (Type: TCP) on your tunnel pointing at Postgres
#   - A Cloudflare Access application protecting that hostname with a Service Auth policy
#   - A service token (Client ID + Secret) allowed by that policy
#
# Usage:
#   ./scripts/db-tunnel.sh --hostname db.example.com [--port 5432] \
#       [--service-token-id <id>] [--service-token-secret <secret>]
#
#   Env fallbacks: TUNNEL_SERVICE_TOKEN_ID / TUNNEL_SERVICE_TOKEN_SECRET
#
#   Then point wrangler dev / your client at localhost, e.g.:
#       postgres://<user>:<pass>@localhost:5432/<db>
set -euo pipefail

HOSTNAME=""
PORT="5432"
ST_ID="${TUNNEL_SERVICE_TOKEN_ID:-}"
ST_SECRET="${TUNNEL_SERVICE_TOKEN_SECRET:-}"

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--hostname)             HOSTNAME="${2:-}"; shift 2 ;;
		--port)                 PORT="${2:-}"; shift 2 ;;
		--service-token-id)     ST_ID="${2:-}"; shift 2 ;;
		--service-token-secret) ST_SECRET="${2:-}"; shift 2 ;;
		-h|--help)              usage; exit 0 ;;
		*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
	esac
done

if [ -z "$HOSTNAME" ]; then
	echo "error: --hostname is required" >&2
	usage
	exit 2
fi
if ! command -v cloudflared >/dev/null 2>&1; then
	echo "error: cloudflared not found. Install it first (see header)." >&2
	exit 1
fi

echo "Opening TCP proxy: localhost:${PORT} -> ${HOSTNAME} (via Cloudflare Access)"
echo "Leave this running; connect wrangler dev / your client to localhost:${PORT}."

ARGS=(access tcp --hostname "$HOSTNAME" --url "127.0.0.1:${PORT}")
if [ -n "$ST_ID" ] && [ -n "$ST_SECRET" ]; then
	ARGS+=(--service-token-id "$ST_ID" --service-token-secret "$ST_SECRET")
fi

exec cloudflared "${ARGS[@]}"
