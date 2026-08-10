# Melis Platform — turnkey install image (Apache + Composer)
# Boots a fresh Melis skeleton on first run; the Melis web installer then
# handles DB schema, admin user and the optional demo site.
#
# PHP version is configurable: default 8.3 (officially supported by Melis 5.3.x).
# Override with --build-arg PHP_VERSION=8.4 (or PHP_VERSION in .env via compose).
# 8.4 is experimental but runs Melis. 8.5 is NOT usable yet: this image builds, but
# the skeleton's Laminas deps cap at 8.4, so composer install fails at run time
# (see melis-core#24).
ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-apache

ARG APP_NAME=melis
ARG TZ=Europe/Paris
# Skeleton version/branch for `composer create-project`. Empty = latest stable.
# Defaults to the 6.x line: v6.0.0 dropped the four laminas `vcs` repositories in
# favour of the Packagist-published melisplatform/laminas-* forks, which is what
# makes a GitHub token unnecessary. Empty = latest stable.
ARG SKELETON_VERSION=^6.0
# Exported so the entrypoint's own create-project (first run) uses the same version.
ENV APP_NAME=${APP_NAME} \
    TZ=${TZ} \
    SKELETON_VERSION=${SKELETON_VERSION}

WORKDIR /var/www/${APP_NAME}

# System packages + PHP extensions required by Melis
RUN apt-get update -y && apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git unzip curl wget \
        default-mysql-client \
        libxml2-dev libonig-dev libcurl4-gnutls-dev libzip-dev \
        libjpeg-dev libfreetype6-dev libjpeg62-turbo-dev zlib1g-dev libpng-dev \
        libicu-dev tzdata \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    # opcache: built into core on PHP 8.5+ (not a shared module), so only install
    # it on < 8.5. Detected at build time → works for any PHP_VERSION.
    && OPCACHE=$(php -r 'echo version_compare(PHP_VERSION, "8.5", "<") ? "opcache" : "";') \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli pdo pdo_mysql xml mbstring curl zip gd intl exif $OPCACHE \
    && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# Optional Xdebug for step-debugging — opt-in (off by default to keep it lean).
# Enable with --build-arg WITH_XDEBUG=1 (or WITH_XDEBUG=1 in .env via compose).
# Defaults: connects back to your IDE on port 9003; on Linux add to the php service
#   extra_hosts: ["host.docker.internal:host-gateway"]
ARG WITH_XDEBUG=0
RUN if [ "$WITH_XDEBUG" = "1" ]; then \
        pecl install xdebug && docker-php-ext-enable xdebug \
        && { \
            echo "xdebug.mode=debug,develop"; \
            echo "xdebug.start_with_request=trigger"; \
            echo "xdebug.client_host=host.docker.internal"; \
            echo "xdebug.client_port=9003"; \
            echo "xdebug.discover_client_host=true"; \
        } > /usr/local/etc/php/conf.d/zz-xdebug.ini ; \
    fi

# Composer (needed at runtime: skeleton bootstrap + the web installer adds modules)
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# --- Run Apache as the HOST user, so ./melis stays editable on the host ---
# This stack's whole point is host-editable code, but the entrypoint has to chown the
# app dir to www-data (the web installer runs as Apache and rewrites composer.json,
# installs into vendor/, writes config/). With www-data at its default uid 33 that
# leaves the tree unwritable for you: `EACCES` in the editor, and `sudo chown` is
# undone on the next boot.
# So instead of fighting the chown, we REMAP www-data to your uid/gid. Every later
# `chown www-data:www-data` then resolves to your uid, so the same files are writable
# by Apache AND by you — no ownership tug-of-war.
# HOST_UID/HOST_GID come from compose (`id -u` / `id -g`, default 1000). Set
# HOST_UID=33 to keep the classic behaviour. `-o` allows a duplicate uid/gid, so this
# can't fail if the base image already uses the target id for something else.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN if [ -n "${HOST_UID}" ] && [ "${HOST_UID}" != "33" ]; then \
        groupmod -o -g "${HOST_GID}" www-data \
        && usermod  -o -u "${HOST_UID}" -g "${HOST_GID}" www-data \
        && chown -R "${HOST_UID}:${HOST_GID}" /var/www \
        && echo "[melis-docker-react] www-data remapped to ${HOST_UID}:${HOST_GID}" ; \
    fi

# Shared, www-data-writable Composer home — a large install-time speedup.
# The web installer runs Composer *inside an HTTP request*, i.e. as www-data, whose
# HOME (/var/www) is root-owned: Composer then silently disables its cache and
# re-fetches every repository's metadata over the network on every run. With the 7
# `vcs` repositories this project ends up with (4 laminas forks + 3 React repos),
# each needing every branch/tag enumerated through the GitHub API, that alone cost
# ~12 min in the wizard's "downloadModules" step (measured: 706 s of 711 s spent
# in "Loading composer repositories", 4 s actually installing packages).
# Here the cache is filled by the entrypoint's create-project (as root), which then
# hands it to www-data — so the wizard reuses metadata already on disk.
ENV COMPOSER_HOME=/composer
RUN mkdir -p /composer && chown www-data:www-data /composer

# Clone public github repos over HTTPS instead of SSH (the image has no ssh client
# or keys). Needed when Composer resolves the public melisplatform Laminas forks
# from their VCS source — e.g. on PHP 8.5, where the locked dist versions can't be
# used. No-op for 8.3/8.4 (which install from dist). Public repos → no credentials.
RUN git config --system url."https://github.com/".insteadOf "git@github.com:"

# Apache: serve Melis from /public, enable rewrite
COPY ./conf/vhost.conf /etc/apache2/sites-available/000-default.conf
COPY ./conf/php.ini /usr/local/etc/php/conf.d/php-melis.ini
# Also keep conf/ whole at a stable path: php.ini's auto_prepend_file points the
# installer guard here.
COPY ./conf /melis-conf
RUN a2enmod rewrite headers

# --- Pre-warm the Composer metadata cache ---
# Unlike prebuilt/ and fpm/, this image bakes no skeleton, so /composer/cache would
# ship EMPTY and the web installer's module step would pay the full uncached cost:
# every one of the 7 `vcs` repositories re-enumerated over the GitHub API, ~12 min
# (measured — of which package archives were only ~4 s; the rest is metadata).
# The entrypoint's own create-project does fill the cache on a genuine first run,
# but NOT when it finds an existing project in the mounted ./melis — a re-created
# container over an existing checkout would then install at full price.
# So resolve the same graph here in a throwaway dir: --no-install fetches metadata
# only (the expensive part), and the cache it leaves behind is what the wizard reads.
# No GitHub credentials needed: with SKELETON_VERSION pointing at a skeleton that has
# no `vcs` repositories, everything (React packages included) resolves from Packagist,
# so there is no GitHub API rate limit in play. Never fatal — a failed pre-warm only
# means a slower first install.
ARG WITH_REACT=1
RUN export COMPOSER_ALLOW_SUPERUSER=1 \
    && ( mkdir -p /tmp/warm && cd /tmp/warm \
         && composer create-project \
              "melisplatform/melis-platform-skeleton${SKELETON_VERSION:+:$SKELETON_VERSION}" . \
              --no-interaction --no-progress --no-install --no-scripts \
         && if [ "$WITH_REACT" = "1" ]; then \
              composer require --no-update --no-interaction --no-scripts \
                   "melisplatform/melis-core:^6.0.2" ; \
            fi \
         && composer update --dry-run --no-interaction --no-scripts --no-progress ) \
       || echo "[melis-docker-react] WARNING: Composer cache pre-warm incomplete — the first web install will be slower." \
    ; rm -rf /tmp/warm \
    && chown -R www-data:www-data /composer \
    && du -sh /composer/cache

COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
# Container is healthy once Apache serves the app. start-period is generous because
# the very first run downloads the skeleton (composer create-project) before Apache.
#
# Probe /melis/ and NOT /: `/` is the PUBLIC site, which only exists if a site was
# installed. A perfectly good back-office-only install (or one where the demo site's
# module failed to install — see the installer guard) answers 500 there, which marked
# this container unhealthy and left vite stuck in `Created` forever waiting on
# `depends_on: service_healthy`. Observed. /melis/ is served in every state: it 302s
# to /melis/setup before the install and to /melis/login after, and curl without -L
# treats a 302 as success.
HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -fsS http://localhost/melis/ -o /dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
