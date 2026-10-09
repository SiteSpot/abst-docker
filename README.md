# AB Split Test server (Docker)

Run [AB Split Test](https://absplittest.com) as a split-test server for
**any website**, not just WordPress sites, with one command. You get
WordPress, the plugin and MariaDB, set up headless (in "external-first" mode)
for one customer domain. WordPress is only the admin and storage layer. The
customer's site just loads one `<script>`.

The plugin itself is not in this repository: `install.sh` downloads the
current release from absplittest.com with your licence key (or takes a zip or
a plugin checkout, see below).

## Quick start

On any Linux server with Docker, pointing a DNS name at it:

```bash
git clone https://github.com/SiteSpot/abst-docker.git && cd abst-docker
./install.sh --domain customer.com --hostname abst.example.com --licence YOUR-KEY
```

It prints:

- the **embed snippet** to paste into `<head>` on every page of `customer.com`
- a **Magic editor link** that opens the point-and-click editor on the customer's homepage
- the WordPress **admin URL and login** for tests, results, heatmaps and settings

HTTPS is automatic: Caddy gets a Let's Encrypt certificate for `--hostname`.
Ports 80 and 443 must be open, and the DNS record must already point at the server.

The licence is activated for the server's URL before the download, exactly as
the plugin's own updater does, so this does not use an extra site on the licence.

### Other ways to run it

| Situation | Command |
|---|---|
| Try it locally | `./install.sh --domain customer.com --licence KEY` → `http://localhost:8080` |
| You already have an HTTPS proxy / load balancer | `./install.sh --domain customer.com --url https://abst.example.com --bind 0.0.0.0 --licence KEY` |
| Heatmaps, page analytics, session replays | add `--journeys` |
| You have the plugin zip (My Account → Downloads) | `--plugin-zip bt-bb-ab.zip` instead of `--licence` |
| You have a checkout of the plugin repository | `--plugin-dir ../ABSPLITTEST` |
| Container platforms (no install.sh) | put the plugin folder in `./plugin`, build the image, and run it with the env vars in [`.env.example`](.env.example) plus `WORDPRESS_DB_*` for your MySQL/MariaDB |

**Local mode is for trying things out only.** Chrome asks visitors for
permission before a public HTTPS site can load a script from `localhost`
(Local Network Access). For real traffic, use `--hostname` or `--url`.

## Everyday commands

Run these from this directory:

```bash
docker compose exec app abst info            # embed snippet, URLs, analyzer key
docker compose exec app abst editor-link     # fresh Magic editor link (expires ~2h)
docker compose exec app abst list_tests      # any `wp absplittest` command…
docker compose exec app abst get_results 12
docker compose exec app abst wp plugin list  # …or any WP-CLI command
docker compose logs -f app
```

## Changing things

Re-run `install.sh` with new options. Passwords in `.env` are kept, and the
server re-provisions itself when the domain, licence, journeys flag or URL
change. The WordPress admin password is only used at first install. After
that, change it in the admin.

## Upgrading

```bash
git pull && ./install.sh --upgrade
```

`--upgrade` downloads the latest plugin release with the licence in `.env`
and rebuilds the image. Each boot copies the plugin from the image into
WordPress. The one exception is when the plugin's own updater has already
installed a newer version; then that version is kept. The embed script is
rebuilt on every boot.

## Data and backups

Everything lives in Docker volumes: `absplittest_db` (tests and results),
`absplittest_wordpress` (WordPress, uploads and the embed file) and
`absplittest_state` (provisioning output). Back up the database with:

```bash
docker compose exec db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" wordpress' > backup.sql
```

## Without Docker: any WordPress host

The container is only a convenience. Any host that runs WordPress can be the
split-test server:

1. Create a fresh WordPress site on its own subdomain, e.g. `abst.example.com`,
   with HTTPS.
2. Install and activate the AB Split Test plugin.
3. Either run `wp absplittest provision --domain=customer.com --licence=KEY --editor-user=admin`
   over SSH, or in **Settings → AB Split Test** add the external domain and set
   **Primary site** to *An external site*.
4. Paste the embed snippet into the customer's site.

What to check on the host:

- **HTTPS is required.** The customer's HTTPS pages can't load an `http://` script.
- **`wp-content/uploads` must be writable.** The embed is written to `uploads/abst/abstembed.js`.
- **Page caching and CDNs must not cache `/wp-json/abst/v1/*` POSTs or strip
  CORS headers.** Most don't, but check aggressive managed-host caches.
- **Size the host for the customer's traffic, not the WordPress site's.** Every
  visitor on the customer's site sends tracking beacons to this server. Cheap
  shared hosting with PHP worker limits will struggle on busy sites.

## Notes

- The plugin adds three sample tests when it's activated. They are scoped to
  WordPress pages, so they never run on the customer's site. Delete them
  whenever you like.
- `wp absplittest create_test` can't set a URL conversion goal yet, because
  `--conversion_url` isn't a declared option. Create those tests in the admin
  or the Magic editor, or through `POST /wp-json/bt-bb-ab/v1/create-test`.
