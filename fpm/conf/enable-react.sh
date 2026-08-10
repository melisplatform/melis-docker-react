#!/bin/bash
# melis-docker-react — enable the React back-office (/melis-react) on a Melis skeleton.
#
# The React back-office ships as three public Packagist packages, all on stable 6.x
# tags since 2026-07-30 (no dev branch, no inline alias):
#   - melisplatform/melis-core        : ships the SPA source (ui-react/) AND the
#     COMMITTED production build (public/ui-react/, served by MelisAssetManager at
#     /MelisCore/ui-react/) — so serving /melis-react needs no Node.js at runtime.
#   - melisplatform/melis-react-api    : JSON API module under /melis/react-api/*.
#   - melisplatform/melis-react-override: /melis-react SPA route (public via
#     excluded_routes) + the iframe mechanism that shows legacy tools in the shell.
#
# Since melis-core v6.0.2 the last two are melis-core's OWN requirements, so this
# script never names them any more (2026-08-10). All it may still have to do is
# raise melis-core itself: a skeleton whose committed composer.lock predates 6.0.2
# (v6.0.0's lock pins melis-core v6.0.1) installs a core that does not pull them.
# Once the skeleton lock carries 6.0.2+, the Composer step below is a no-op.
#
# This script (idempotent — exits fast once enabled):
#   1. makes sure melis-core is >= 6.0.2, which brings both React modules in as
#      transitive deps. No `repositories` entries — everything is indexed on
#      Packagist, so Composer never touches the GitHub API;
#   2. patches config/application.config.php (see enable-react.php next to this
#      file) so the two modules load once the platform is installed.
#
# Usage: enable-react.sh [APP_DIR]     (default /var/www/$APP_NAME)
set -euo pipefail

APP_DIR="${1:-/var/www/${APP_NAME:-melis}}"
CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

# Already enabled? (module installed + config patched)
if [ -d vendor/melisplatform/melis-react-override ] \
    && grep -q "MelisReactOverride" config/application.config.php 2>/dev/null; then
    echo "[melis-docker-react] React back-office already enabled — skipping."
    exit 0
fi

echo "[melis-docker-react] Enabling the React back-office (/melis-react)..."

export COMPOSER_ALLOW_SUPERUSER=1

# No GitHub authentication here, and no `composer config repositories.*` — by design.
# Everything resolves from PACKAGIST, so Composer never enumerates a repository's refs
# through the GitHub API and there is no 60 req/hour limit to hit. Adding a `vcs` entry
# back would re-introduce exactly the problem GITHUB_TOKEN used to work around. Don't.
#
# No `-W` and no inline alias any more: with the 6.x line every package agrees on
# `melis-core ^6.0`, so a plain require resolves. (Until 2026-07-30 this had to pull
# melis-core's `dev-melis-react` branch aliased as 5.3.999, because the React build
# lived only on that branch and the 5.x modules capped melis-core below 6.0.)
# The two React modules are NOT named here: melis-core >= 6.0.2 requires them itself.
# Naming them would only re-add a root requirement Composer already satisfies, and
# would drift the moment melis-core changes its own constraint. The version floor is
# the whole contract — `^6.0.2` is a caret range, so 6.1/6.x still resolve.
# --no-scripts is REQUIRED: this runs before the platform is installed, and the
# skeleton's post-update-cmd hook (MelisDbDeploy\DbDeployOnComposerUpdate) fatals
# trying to reach the not-yet-configured database ("Call to a member function
# query() on null"), which would fail the whole require. Skipping the hooks here
# loses nothing: the web installer's own Composer runs (no --no-scripts) and its
# dbdeploy pass publish + apply every module's schema deltas during the install —
# same as the vanilla flow, where create-project never fires post-update-cmd.
# NOTE — the `laminas/laminas-serializer:2.17` pin that used to live here was REMOVED
# on 2026-07-30, once melis-front v6.0.1 relaxed its own constraint from an exact
# `2.17` to `^2.17`. Background, in case it ever needs restoring: melis-core allows
# `^2.17 || ^3.0`, so this require (which runs before the wizard adds the CMS modules)
# resolves serializer on its own and locks the newest match, 2.18.0. While melis-front
# demanded exactly `2.17`, the wizard's later `composer update --root-reqs` — a PARTIAL
# update, which may not downgrade an already-locked package — failed with "the package
# is fixed to 2.18.0 (lock file version) by a partial update". The installer ignores
# that failure (gotcha 8), leaving MelisEngine/MelisFront activated but absent: a
# bootstrap fatal on every URL. Verified fixed end-to-end on 6.x (front v6.0.1 + 2.18.0).
if [ ! -d vendor/melisplatform/melis-react-override ] \
    || [ ! -d vendor/melisplatform/melis-react-api ]; then
    echo "[melis-docker-react] React modules absent — raising melisplatform/melis-core to ^6.0.2..."
    composer require --no-interaction --no-progress --prefer-dist --no-scripts \
        "melisplatform/melis-core:^6.0.2"
else
    echo "[melis-docker-react] React modules already installed by melis-core — no Composer run needed."
fi

php "$CONF_DIR/enable-react.php" "$APP_DIR/config/application.config.php"
php -l "$APP_DIR/config/application.config.php" >/dev/null

echo "[melis-docker-react] React back-office enabled — /melis-react goes live once the web"
echo "[melis-docker-react] installer has completed."
