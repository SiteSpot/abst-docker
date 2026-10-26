# AB Split Test as a self-contained split-test server: WordPress + the plugin,
# set up headless (external-first mode) on first boot.
#
# The plugin folder is expected at ./plugin (install.sh downloads it with your
# licence key, or takes --plugin-zip / --plugin-dir). Build from this directory:
#
#   docker build -t absplittest .
#
# Normally you don't build this by hand - install.sh drives docker compose.
#
# The base image supplies PHP and Apache; WordPress itself lives in a volume and
# updates in place. So the tag names no WordPress major: a tag like
# wordpress:6-php8.3-apache stops being rebuilt once that major is superseded,
# and it stuck on PHP 8.3.31 (May 2026), missing the critical PHP security
# release of 21 Oct 2026 (8.3.36). This tag is rebuilt for every PHP 8.3 patch
# release, which `install.sh --upgrade` pulls. Move to a newer PHP branch before
# docker-library stops building 8.3 (its security support ends 31 Dec 2027).
FROM wordpress:php8.3-apache

# WP-CLI is a single phar; take it from the official CLI image.
COPY --from=wordpress:cli /usr/local/bin/wp /usr/local/bin/wp

# Behind a TLS proxy (Caddy in docker-compose.yml, or a platform load balancer)
# log the real visitor IP instead of the proxy's.
RUN a2enmod remoteip \
 && { \
      echo 'RemoteIPHeader X-Forwarded-For'; \
      echo 'RemoteIPInternalProxy 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.1'; \
    } > /etc/apache2/conf-available/remoteip.conf \
 && a2enconf remoteip

# Pin the public URL from ABST_URL so the embed script and REST endpoints are
# always generated against the address visitors can reach.
ENV WORDPRESS_CONFIG_EXTRA="if (getenv_docker('ABST_URL', '')) { define('WP_HOME', rtrim(getenv_docker('ABST_URL', ''), '/')); define('WP_SITEURL', WP_HOME); }"

# The plugin ships inside the image and is synced into wp-content on each boot
# (see absplittest-setup), so rebuilding the image upgrades it.
COPY plugin/ /opt/absplittest
COPY bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/absplittest-entrypoint /usr/local/bin/absplittest-setup /usr/local/bin/abst \
 && mkdir -p /var/lib/absplittest \
 && chown www-data:www-data /var/lib/absplittest

VOLUME /var/lib/absplittest

HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=30 \
  CMD test -f /var/lib/absplittest/ready && curl -fsS -o /dev/null http://127.0.0.1/wp-json/ || exit 1

ENTRYPOINT ["absplittest-entrypoint"]
CMD ["apache2-foreground"]
