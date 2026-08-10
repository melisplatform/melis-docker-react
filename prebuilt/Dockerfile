# Melis Platform — pre-built image (PHP 8.3 + Apache + Composer)
# Unlike install/Dockerfile, the Melis skeleton is BAKED AT BUILD TIME, so the
# published image already contains a ready-to-run Melis project: the user only
# needs a database and `docker run` — no Composer/build step on their machine.
# DB schema, admin user and the optional demo site are still set up through the
# native Melis web installer on first visit.
#
# PHP version is configurable: default 8.3 (officially supported by Melis 5.3.x).
# Override with --build-arg PHP_VERSION=8.4 (or PHP_VERSION in .env via compose).
# 8.4 is experimental but runs Melis. 8.5 is NOT usable yet: the skeleton's Laminas
# deps cap at 8.4, so the create-project step below FAILS the build on 8.5
# (see melis-core#24).
ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-apache

ARG APP_NAME=melis
ARG TZ=Europe/Paris
# Pin the skeleton version for reproducible images (override at build:
#   --build-arg SKELETON_VERSION="^5.3").  Empty = latest stable.
# Defaults to the 6.x line: v6.0.0 dropped the four laminas `vcs` repositories in
# favour of the Packagist-published melisplatform/laminas-* forks, which is what
# makes a GitHub token unnecessary. Empty = latest stable.
ARG SKELETON_VERSION=^6.0
# Exported so the entrypoint's defensive create-project uses the same version.
ENV APP_NAME=${APP_NAME} \
    TZ=${TZ} \
    COMPOSER_ALLOW_SUPERUSER=1 \
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

# Composer (kept at runtime too: the web installer adds modules via composer)
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Shared, www-data-writable Composer home — a large install-time speedup.
# The web installer runs Composer *inside an HTTP request*, i.e. as www-data, whose
# HOME (/var/www) is root-owned: Composer then silently disables its cache and
# re-fetches every repository's metadata over the network on every run. With the 7
# `vcs` repositories this project ends up with (4 laminas forks + 3 React repos),
# each needing every branch/tag enumerated through the GitHub API, that alone cost
# ~12 min in the wizard's "downloadModules" step (measured: 706 s of 711 s spent
# in "Loading composer repositories", 4 s actually installing packages).
# Pointing every Composer run — build, entrypoint, installer, marketplace, the
# guard's repair — at one writable home means the metadata this build already
# downloads is still there when the wizard runs.
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
# installer guard here. docker-compose.yml mounts the host conf/ over it so edits
# apply to the published image without a rebuild.
COPY ./conf /melis-conf
RUN a2enmod rewrite headers

# --- Bake the Melis skeleton into the image (the key difference vs install/) ---
# Community Edition skeleton (public); cms/front/engine + demo are added later by
# the web installer. Built into a ready-to-serve project under the app dir.
RUN if [ -n "${SKELETON_VERSION}" ]; then \
        composer create-project melisplatform/melis-platform-skeleton:"${SKELETON_VERSION}" . \
            --no-interaction --no-progress --prefer-dist ; \
    else \
        composer create-project melisplatform/melis-platform-skeleton . \
            --no-interaction --no-progress --prefer-dist ; \
    fi \
    && mkdir -p config cache mnt/public/media \
    && chown -R www-data:www-data /var/www/${APP_NAME}

# --- Enable the React back-office (/melis-react) ---
# Switches melis-core to its public `melis-react` branch — which ships the COMMITTED
# production React build in public/ui-react/, so no Node.js is needed in this image —
# and adds the MelisReactApi + MelisReactOverride modules (see conf/enable-react.sh).
# Disable with --build-arg WITH_REACT=0. No GitHub credentials needed — all three
# React packages resolve from Packagist.
ARG WITH_REACT=1
RUN if [ "$WITH_REACT" = "1" ]; then \
        bash /melis-conf/enable-react.sh /var/www/${APP_NAME} \
        && chown -R www-data:www-data /var/www/${APP_NAME} ; \
    fi

# Hand the cache these root-run builds just filled to www-data, so the web
# installer's own Composer runs read it instead of re-downloading everything.
RUN chown -R www-data:www-data /composer

COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80
# Container is healthy once Apache serves the app. Probe /melis/ and NOT /: `/` is
# the PUBLIC site and only exists once a site is installed, so a back-office-only
# install (or a demo site whose module failed to install) answers 500 there and the
# container is wrongly marked unhealthy. /melis/ is served in every state — it 302s
# to /melis/setup before the install and to /melis/login after.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS http://localhost/melis/ -o /dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
