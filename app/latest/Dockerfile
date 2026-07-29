# Melis Platform — legacy dev image (app/latest).
#
# This stack does NOT bake an application: docker-compose.yml bind-mounts an
# EXISTING Melis project (../../../) over /var/www/$APP_NAME at runtime. The image
# only provides the runtime (Apache + PHP + extensions + Composer) and the
# entrypoint/conf that the other stacks use.
#
# PHP version is configurable like the other stacks. 8.3 = default/recommended,
# 8.4 = experimental but runs Melis, 8.5 needs the extra fixes documented in
# CLAUDE.md (melis-core#24).
ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-apache AS builder

# Define build arguments
ARG APP_NAME
ARG TZ
ARG MELIS_PLATFORM
ARG MELIS_MODULE

# Set environment variables
ENV APP_NAME=${APP_NAME} \
    TZ=${TZ} \
    MELIS_PLATFORM=${MELIS_PLATFORM} \
    MELIS_MODULE=${MELIS_MODULE} \
    COMPOSER_ALLOW_SUPERUSER=1

## WORKDIR
WORKDIR /var/www/${APP_NAME}

# Install dependencies in a single RUN command to reduce layers
RUN apt-get update -y \
    && apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    vim \
    cron \
    curl \
    wget \
    git \
    unzip \
    default-mysql-client \
    libxml2-dev \
    libonig-dev \
    libcurl4-gnutls-dev \
    libzip-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    zlib1g-dev \
    libpng-dev \
    tzdata \
    # Add libicu-dev for the intl extension
    libicu-dev \
    # systemd-timesyncd \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    # opcache: built into core on PHP 8.5+ (not a shared module), so installing it
    # there fails with "cp: cannot stat 'modules/*'". Detected at build time, so this
    # works for any PHP_VERSION.
    && OPCACHE=$(php -r 'echo version_compare(PHP_VERSION, "8.5", "<") ? "opcache" : "";') \
    && docker-php-ext-install -j$(nproc) \
    mysqli \
    pdo \
    pdo_mysql \
    xml \
    mbstring \
    curl \
    zip \
    gd \
    intl \
    exif \
    $OPCACHE \
    && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && dpkg-reconfigure --frontend noninteractive tzdata

# Composer — required at RUNTIME, not just for bootstrap: the Melis web installer
# adds modules (cms/front/engine) via Composer during the install, and
# conf/enable-react.sh needs it to pull the React back-office branches.
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Shared, www-data-writable Composer home. The web installer runs Composer *inside
# an HTTP request*, i.e. as www-data, whose HOME (/var/www) is root-owned: Composer
# then silently disables its cache and re-fetches every repository's metadata over
# the network on every run. With this project's GitHub `vcs` repositories (4 laminas
# forks, +3 more once React is enabled) that alone cost ~12 min in the wizard's
# module step. Pointing every Composer run at one writable home avoids it.
ENV COMPOSER_HOME=/composer
RUN mkdir -p /composer && chown www-data:www-data /composer

# Clone public github repos over HTTPS instead of SSH (the image has no ssh client
# or keys). Needed when Composer resolves the public melisplatform Laminas forks
# from their VCS source — they are declared with git@github.com: URLs. Public repos
# → no credentials involved.
RUN git config --system url."https://github.com/".insteadOf "git@github.com:"

FROM builder AS config

COPY ./conf/php.ini /usr/local/etc/php/conf.d/php-melis.ini
COPY ./conf/my.cnf /etc/mysql/conf.d/mysql.cnf
COPY ./conf/vhost.conf /etc/apache2/sites-available/vhost.conf
COPY ./conf/apache2.conf /etc/apache2/apache2.conf
# Keep conf/ whole at a stable path: php.ini's auto_prepend_file points the
# installer guard here, and the entrypoint runs enable-react.sh from here.
COPY ./conf /melis-conf

# Final stage
FROM config

# Create the directories Melis writes to. The application itself is NOT copied in:
# docker-compose.yml bind-mounts the real project over this path at runtime, which
# would mask anything baked here anyway. (The previous `COPY ../../../` did not do
# what it looks like — BuildKit clamps a path that escapes the context back to the
# context root, so it merely copied app/latest's own files into the app dir.)
RUN mkdir -p /var/www/${APP_NAME}/config \
    && mkdir -p /var/www/${APP_NAME}/cache \
    && mkdir -p /var/www/${APP_NAME}/public \
    && mkdir -p /var/www/${APP_NAME}/mnt/public/media \
    && chown -R www-data:www-data /var/www/${APP_NAME} \
    && chmod -R 775 /var/www/${APP_NAME}/config \
    && chmod -R 775 /var/www/${APP_NAME}/cache \
    && a2enmod rewrite headers \
    && a2dissite 000-default.conf \
    && a2ensite vhost.conf

# --- Pre-warm the Composer metadata cache ---
# This stack bakes no application (the project is bind-mounted at runtime), so
# /composer/cache would ship EMPTY: the entrypoint's React enablement and the web
# installer's module step would each re-enumerate every GitHub `vcs` repository
# through the API — ~12 min before Apache even starts, during which the published
# port answers with an empty response.
# So resolve the graph here in a throwaway dir: --no-install fetches METADATA only,
# which is the expensive part (~7 MB; package archives are seconds). The cache is
# keyed per repository URL, so it serves any project mounted later, not just this
# resolve. Optional token, to stay off the 60 req/h unauthenticated limit:
#   GITHUB_TOKEN=ghp_xxx docker build --secret id=github_token,env=GITHUB_TOKEN .
# Never fatal — a failed pre-warm only means a slower first boot.
ARG WITH_REACT=1
RUN --mount=type=secret,id=github_token \
    export COMPOSER_ALLOW_SUPERUSER=1 \
    && GITHUB_TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)" \
    && if [ -n "$GITHUB_TOKEN" ]; then \
         export COMPOSER_AUTH="{\"github-oauth\":{\"github.com\":\"${GITHUB_TOKEN}\"}}" ; \
       fi \
    && ( mkdir -p /tmp/warm && cd /tmp/warm \
         && composer create-project melisplatform/melis-platform-skeleton . \
              --no-interaction --no-progress --no-install --no-scripts \
         && if [ "$WITH_REACT" = "1" ]; then \
              composer config repositories.melis-core           vcs https://github.com/melisplatform/melis-core \
              && composer config repositories.melis-react-api      vcs https://github.com/melisplatform/melis-react-api \
              && composer config repositories.melis-react-override vcs https://github.com/melisplatform/melis-react-override \
              && composer require --no-update --no-interaction --no-scripts \
                   "melisplatform/melis-core:dev-melis-react as 5.3.999" \
                   "melisplatform/melis-react-api:dev-melis-react" \
                   "melisplatform/melis-react-override:dev-melis-react" ; \
            fi \
         && composer update --dry-run --no-interaction --no-scripts --no-progress ) \
       || echo "[melis-docker-react] WARNING: Composer cache pre-warm incomplete — the first boot will be slower." \
    ; rm -rf /tmp/warm \
    && chown -R www-data:www-data /composer \
    && du -sh /composer/cache

COPY ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

## EXPOSE
EXPOSE 80
# Container is healthy once Apache serves the app. The vite override waits on this
# before mounting into vendor/. Probe /melis/ and NOT /: `/` is the PUBLIC site and
# only exists once a site is installed, so a back-office-only install (or a demo site
# whose module failed to install) answers 500 there, the container is wrongly marked
# unhealthy and vite then never starts at all. /melis/ is served in every state — it
# 302s to /melis/setup before the install and to /melis/login after.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS http://localhost/melis/ -o /dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
