#!/usr/bin/env bash
# One-command install of an AB Split Test split-test server with Docker.
#
#   # On a VPS whose DNS name abst.example.com points at it (HTTPS via Let's Encrypt):
#   ./docker/install.sh --domain customer.com --hostname abst.example.com --licence KEY
#
#   # Local trial on http://localhost:8080 (browsers allow an http://localhost
#   # script on an https page, so this works for testing):
#   ./docker/install.sh --domain customer.com
#
#   # Behind your own HTTPS proxy / load balancer:
#   ./docker/install.sh --domain customer.com --url https://abst.example.com --bind 0.0.0.0
#
# Re-running is safe: secrets in docker/.env are kept, other values updated,
# and the server re-provisions when the domain, licence or journeys change.
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: docker/install.sh --domain <customer-site> [options]

  --domain <host>        The customer's site to test, e.g. customer.com (required)
  --hostname <host>      Public DNS name for this server; enables automatic HTTPS (Caddy)
  --url <url>            Public URL when you run your own HTTPS proxy instead
  --licence <key>        AB Split Test licence key
  --journeys             Enable heatmaps, page analytics and session replays
  --port <port>          Host port for WordPress (default 8080)
  --bind <addr>          Host address WordPress listens on (default 127.0.0.1)
  --admin-user <login>   WordPress admin login (default admin)
  --admin-email <email>  WordPress admin email (default admin@example.com)
  -h, --help             Show this help
EOF
}

cd "$(dirname "$0")"
ENV_FILE=.env

domain="" hostname="" url="" licence="" journeys="" port="" bind="" admin_user="" admin_email=""
while [ $# -gt 0 ]; do
	case "$1" in
		--domain) domain=${2:?}; shift 2 ;;
		--hostname) hostname=${2:?}; shift 2 ;;
		--url) url=${2:?}; shift 2 ;;
		--licence|--license) licence=${2:?}; shift 2 ;;
		--journeys) journeys=1; shift ;;
		--port) port=${2:?}; shift 2 ;;
		--bind) bind=${2:?}; shift 2 ;;
		--admin-user) admin_user=${2:?}; shift 2 ;;
		--admin-email) admin_email=${2:?}; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

if [ -z "$domain" ]; then
	echo "--domain is required." >&2
	usage >&2
	exit 1
fi
if [ -n "$hostname" ] && [ -n "$url" ]; then
	echo "Use either --hostname (built-in HTTPS) or --url (your own proxy), not both." >&2
	exit 1
fi

command -v docker >/dev/null || { echo "Docker is not installed: https://docs.docker.com/engine/install/" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required (the 'docker compose' plugin)." >&2; exit 1; }

# Current value of KEY in .env, if any.
existing() {
	[ -f "$ENV_FILE" ] || return 0
	sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}
secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true; }

db_password=$(existing ABST_DB_PASSWORD); db_password=${db_password:-$(secret)}
db_root_password=$(existing ABST_DB_ROOT_PASSWORD); db_root_password=${db_root_password:-$(secret)}
admin_password=$(existing ABST_ADMIN_PASSWORD); admin_password=${admin_password:-$(secret)}
licence=${licence:-$(existing ABST_LICENCE)}
admin_user=${admin_user:-$(existing ABST_ADMIN_USER)}; admin_user=${admin_user:-admin}
admin_email=${admin_email:-$(existing ABST_ADMIN_EMAIL)}; admin_email=${admin_email:-admin@example.com}
port=${port:-$(existing ABST_HTTP_PORT)}; port=${port:-8080}
bind=${bind:-$(existing ABST_BIND)}; bind=${bind:-127.0.0.1}

profiles=""
if [ -n "$hostname" ]; then
	url="https://$hostname"
	profiles="tls"
elif [ -z "$url" ]; then
	url="http://localhost:$port"
fi
url=${url%/}

umask 077
cat > "$ENV_FILE" <<EOF
# Written by docker/install.sh - re-run it to change these.
ABST_DOMAIN=$domain
ABST_LICENCE=$licence
ABST_JOURNEYS=$journeys
ABST_URL=$url
ABST_HOSTNAME=$hostname
COMPOSE_PROFILES=$profiles
ABST_BIND=$bind
ABST_HTTP_PORT=$port
ABST_ADMIN_USER=$admin_user
ABST_ADMIN_PASSWORD=$admin_password
ABST_ADMIN_EMAIL=$admin_email
ABST_DB_PASSWORD=$db_password
ABST_DB_ROOT_PASSWORD=$db_root_password
EOF

echo "Building and starting AB Split Test at $url ..."
docker compose up -d --build --remove-orphans

echo "Waiting for WordPress setup and provisioning (first boot takes a minute) ..."
ready=0
for _ in $(seq 1 150); do
	if docker compose exec -T app test -f /var/lib/absplittest/ready 2>/dev/null; then
		ready=1
		break
	fi
	if [ -z "$(docker compose ps -q --status running app)" ]; then
		break
	fi
	sleep 2
done
if [ "$ready" != 1 ]; then
	echo "Setup did not finish. Recent logs:" >&2
	docker compose logs --tail 60 app >&2
	exit 1
fi

cat <<EOF

AB Split Test is running.

  Admin:     $url/wp-admin/
  Login:     $admin_user / $admin_password   (also in docker/.env)

Add this to every page on $domain, as high in <head> as possible:
EOF
docker compose exec -T app abst info
cat <<EOF

Useful commands (run from the docker/ directory):
  docker compose exec app abst info           # embed snippet and URLs again
  docker compose exec app abst editor-link    # fresh Magic editor link (expires in ~2h)
  docker compose exec app abst list_tests     # any 'wp absplittest' command
  docker compose logs -f app                  # server logs
EOF
if [ -n "$hostname" ]; then
	echo
	echo "HTTPS: $hostname must resolve to this machine and ports 80/443 must be open for the certificate."
fi
