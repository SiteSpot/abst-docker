#!/usr/bin/env bash
# One-command install of an AB Split Test split-test server with Docker.
#
#   # On a VPS whose DNS name abst.example.com points at it (HTTPS via Let's Encrypt):
#   ./install.sh --domain customer.com --hostname abst.example.com --licence KEY
#
#   # Local trial on http://localhost:8080 (browsers allow an http://localhost
#   # script on an https page, so this works for testing):
#   ./install.sh --domain customer.com --licence KEY
#
#   # Behind your own HTTPS proxy / load balancer:
#   ./install.sh --domain customer.com --url https://abst.example.com --bind 0.0.0.0 --licence KEY
#
#   # Upgrade to the latest plugin release and rebuild:
#   ./install.sh --upgrade
#
# The plugin itself is not in this repository. With --licence it is downloaded
# from absplittest.com (the licence is activated for this server's URL first, as
# the plugin's own updater does). Without a licence, pass --plugin-zip (the zip
# from your absplittest.com account) or --plugin-dir (a checkout of the plugin).
#
# Re-running is safe: secrets in .env are kept, other values updated, and the
# server re-provisions when the domain, licence or journeys change.
set -euo pipefail

STORE_URL=${ABST_STORE_URL:-https://absplittest.com}
STORE_ITEM_ID=${ABST_STORE_ITEM_ID:-9487}

usage() {
	cat <<'EOF'
Usage: ./install.sh --domain <customer-site> [options]

  --domain <host>        The customer's site to test, e.g. customer.com (required on first install)
  --hostname <host>      Public DNS name for this server; enables automatic HTTPS (Caddy)
  --url <url>            Public URL when you run your own HTTPS proxy instead
  --licence <key>        AB Split Test licence key (also used to download the plugin)
  --plugin-zip <file>    Use this plugin zip instead of downloading one
  --plugin-dir <dir>     Use this plugin checkout instead of downloading one
  --upgrade              Download the latest plugin release again and rebuild
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
PLUGIN_DIR=plugin

domain="" hostname="" url="" licence="" journeys="" port="" bind="" admin_user="" admin_email=""
plugin_zip="" plugin_src="" upgrade=0
while [ $# -gt 0 ]; do
	case "$1" in
		--domain) domain=${2:?}; shift 2 ;;
		--hostname) hostname=${2:?}; shift 2 ;;
		--url) url=${2:?}; shift 2 ;;
		--licence|--license) licence=${2:?}; shift 2 ;;
		--plugin-zip) plugin_zip=${2:?}; shift 2 ;;
		--plugin-dir) plugin_src=${2:?}; shift 2 ;;
		--upgrade) upgrade=1; shift ;;
		--journeys) journeys=1; shift ;;
		--port) port=${2:?}; shift 2 ;;
		--bind) bind=${2:?}; shift 2 ;;
		--admin-user) admin_user=${2:?}; shift 2 ;;
		--admin-email) admin_email=${2:?}; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

command -v docker >/dev/null || { echo "Docker is not installed: https://docs.docker.com/engine/install/" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required (the 'docker compose' plugin)." >&2; exit 1; }

# Current value of KEY in .env, if any.
existing() {
	[ -f "$ENV_FILE" ] || return 0
	sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}
secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true; }

domain=${domain:-$(existing ABST_DOMAIN)}
if [ -z "$domain" ]; then
	echo "--domain is required." >&2
	usage >&2
	exit 1
fi
if [ -n "$hostname" ] && [ -n "$url" ]; then
	echo "Use either --hostname (built-in HTTPS) or --url (your own proxy), not both." >&2
	exit 1
fi
if [ -n "$plugin_zip" ] && [ -n "$plugin_src" ]; then
	echo "Use either --plugin-zip or --plugin-dir, not both." >&2
	exit 1
fi

db_password=$(existing ABST_DB_PASSWORD); db_password=${db_password:-$(secret)}
db_root_password=$(existing ABST_DB_ROOT_PASSWORD); db_root_password=${db_root_password:-$(secret)}
admin_password=$(existing ABST_ADMIN_PASSWORD); admin_password=${admin_password:-$(secret)}
licence=${licence:-$(existing ABST_LICENCE)}
journeys=${journeys:-$(existing ABST_JOURNEYS)}
admin_user=${admin_user:-$(existing ABST_ADMIN_USER)}; admin_user=${admin_user:-admin}
admin_email=${admin_email:-$(existing ABST_ADMIN_EMAIL)}; admin_email=${admin_email:-admin@example.com}
port=${port:-$(existing ABST_HTTP_PORT)}; port=${port:-8080}
bind=${bind:-$(existing ABST_BIND)}; bind=${bind:-127.0.0.1}
hostname=${hostname:-$(existing ABST_HOSTNAME)}
url=${url:-$(existing ABST_URL)}

profiles=""
if [ -n "$hostname" ]; then
	url="https://$hostname"
	profiles="tls"
elif [ -z "$url" ]; then
	url="http://localhost:$port"
fi
url=${url%/}

# ---------------------------------------------------------------------------
# The plugin: ./plugin/ holds the plugin folder that goes into the image.
# ---------------------------------------------------------------------------

plugin_version() {
	sed -n 's/^[ *]*Version:[[:space:]]*//p' "$1/bt-bb-ab.php" 2>/dev/null | head -n 1 | tr -d '\r'
}

# One field of a flat JSON reply, with \/ unescaped. Enough for the store's answers.
json_field() {
	sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | sed 's#\\/#/#g' | head -n 1
}

# Download the current release from the store. The licence must be activated for
# this server's URL before the package link works; provisioning activates the same
# URL later, so this is the same activation, not an extra one.
download_plugin() {
	command -v curl >/dev/null || { echo "curl is required to download the plugin." >&2; return 1; }
	command -v unzip >/dev/null || { echo "unzip is required to download the plugin." >&2; return 1; }
	local reply link tmp
	echo "Activating the licence for $url ..."
	reply=$(curl -sS -X POST "$STORE_URL/" --data-urlencode "edd_action=activate_license" \
		--data-urlencode "item_id=$STORE_ITEM_ID" --data-urlencode "license=$licence" --data-urlencode "url=$url")
	case "$reply" in
		*'"success":true'*) ;;
		*) echo "The store did not accept the licence for $url: $(printf '%s' "$reply" | json_field error)" >&2
		   echo "Check the key, or pass --plugin-zip with the zip from your absplittest.com account." >&2
		   return 1 ;;
	esac
	echo "Downloading the latest AB Split Test release ..."
	reply=$(curl -sS -X POST "$STORE_URL/" --data-urlencode "edd_action=get_version" \
		--data-urlencode "item_id=$STORE_ITEM_ID" --data-urlencode "license=$licence" --data-urlencode "url=$url")
	link=$(printf '%s' "$reply" | json_field download_link)
	if [ -z "$link" ]; then
		echo "The store gave no download link (version reply: $(printf '%s' "$reply" | json_field new_version))." >&2
		return 1
	fi
	tmp=$(mktemp -d)
	if ! curl -sS -L -f -o "$tmp/plugin.zip" "$link"; then
		echo "Downloading the plugin failed." >&2
		rm -rf "$tmp"
		return 1
	fi
	install_plugin_zip "$tmp/plugin.zip"
	rm -rf "$tmp"
}

install_plugin_zip() {
	local tmp
	tmp=$(mktemp -d)
	unzip -q "$1" -d "$tmp" || { rm -rf "$tmp"; echo "Could not unzip $1." >&2; return 1; }
	local main
	main=$(find "$tmp" -maxdepth 2 -name bt-bb-ab.php | head -n 1)
	[ -n "$main" ] || { rm -rf "$tmp"; echo "$1 does not contain AB Split Test (no bt-bb-ab.php)." >&2; return 1; }
	rm -rf "$PLUGIN_DIR.tmp"
	mv "$(dirname "$main")" "$PLUGIN_DIR.tmp"
	rm -rf "$tmp" "$PLUGIN_DIR"
	mv "$PLUGIN_DIR.tmp" "$PLUGIN_DIR"
}

install_plugin_dir() {
	[ -f "$1/bt-bb-ab.php" ] || { echo "$1 is not an AB Split Test checkout (no bt-bb-ab.php)." >&2; return 1; }
	rm -rf "$PLUGIN_DIR.tmp"
	# Ship what a release ships: no repo-only folders.
	mkdir -p "$PLUGIN_DIR.tmp"
	tar -C "$1" --exclude=.git --exclude=.github --exclude=.claude --exclude=tests --exclude=docs \
		--exclude=node_modules --exclude=.wp-test-core -cf - . | tar -C "$PLUGIN_DIR.tmp" -xf -
	rm -rf "$PLUGIN_DIR"
	mv "$PLUGIN_DIR.tmp" "$PLUGIN_DIR"
}

if [ -n "$plugin_zip" ]; then
	install_plugin_zip "$plugin_zip"
elif [ -n "$plugin_src" ]; then
	install_plugin_dir "$plugin_src"
elif [ "$upgrade" = 1 ] || [ ! -f "$PLUGIN_DIR/bt-bb-ab.php" ]; then
	if [ -z "$licence" ]; then
		cat >&2 <<'EOF'
No plugin to install. Either:
  --licence KEY            download the current release with your licence key
  --plugin-zip FILE        use the zip from your absplittest.com account (My Account > Downloads)
  --plugin-dir DIR         use a checkout of the plugin repository
EOF
		exit 1
	fi
	download_plugin
fi
echo "Plugin: AB Split Test $(plugin_version "$PLUGIN_DIR")"

umask 077
cat > "$ENV_FILE" <<EOF
# Written by install.sh - re-run it to change these.
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
  Login:     $admin_user / $admin_password   (also in .env)

Add this to every page on $domain, as high in <head> as possible:
EOF
docker compose exec -T app abst info
cat <<EOF

Useful commands (run from this directory):
  docker compose exec app abst info           # embed snippet and URLs again
  docker compose exec app abst editor-link    # fresh Magic editor link (expires in ~2h)
  docker compose exec app abst list_tests     # any 'wp absplittest' command
  docker compose logs -f app                  # server logs
  ./install.sh --upgrade                      # latest plugin release, rebuilt
EOF
if [ -n "$hostname" ]; then
	echo
	echo "HTTPS: $hostname must resolve to this machine and ports 80/443 must be open for the certificate."
fi
