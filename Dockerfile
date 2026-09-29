# AB Split Test as a self-contained split-test server: WordPress + the plugin,
# set up headless (external-first mode) on first boot. Build from the repo root:
#
#   docker build -f docker/Dockerfile -t absplittest .
#
# Normally you don't build this by hand - docker/install.sh drives docker compose.
FROM wordpress:6-php8.3-apache

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
COPY . /opt/absplittest
COPY docker/bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/absplittest-entrypoint /usr/local/bin/absplittest-setup /usr/local/bin/abst \
 && rm -rf /opt/absplittest/docker \
 && mkdir -p /var/lib/absplittest \
 && chown www-data:www-data /var/lib/absplittest

VOLUME /var/lib/absplittest

HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=30 \
  CMD test -f /var/lib/absplittest/ready && curl -fsS -o /dev/null http://127.0.0.1/wp-json/ || exit 1

ENTRYPOINT ["absplittest-entrypoint"]
CMD ["apache2-foreground"]
