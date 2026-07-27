#!/bin/bash
# melis-docker-react — enable the React back-office (/melis-react) on a Melis skeleton.
#
# The React back-office lives on public GitHub `melis-react` branches:
#   - melisplatform/melis-core        : ships the SPA source (ui-react/) AND the
#     COMMITTED production build (public/ui-react/, served by MelisAssetManager at
#     /MelisCore/ui-react/) — so serving /melis-react needs no Node.js at runtime.
#   - melisplatform/melis-react-api    : JSON API module under /melis/react-api/*.
#   - melisplatform/melis-react-override: /melis-react SPA route (public via
#     excluded_routes) + the iframe mechanism that shows legacy tools in the shell.
#
# This script (idempotent — exits fast once enabled):
#   1. adds the three GitHub repos to composer.json and requires the branches
#      (melis-core pinned with an inline alias so every other module's ^5.3
#      constraint stays satisfied, and so the web installer's later
#      `composer update --root-reqs` cannot roll it back to a stable dist);
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
    echo "[melis-docker] React back-office already enabled — skipping."
    exit 0
fi

echo "[melis-docker] Enabling the React back-office (/melis-react)..."

export COMPOSER_ALLOW_SUPERUSER=1

# GitHub token: passed to Composer via COMPOSER_AUTH (environment only — never
# written to disk, so it cannot leak into an image layer or the app volume).
if [ -n "${GITHUB_TOKEN:-}" ]; then
    export COMPOSER_AUTH="{\"github-oauth\":{\"github.com\":\"${GITHUB_TOKEN}\"}}"
else
    echo "[melis-docker] WARNING: no GITHUB_TOKEN set. With the three React repos this"
    echo "[melis-docker]   project now resolves 7 GitHub 'vcs' repositories, all on the"
    echo "[melis-docker]   unauthenticated API limit (60 req/h per IP). If this step fails"
    echo "[melis-docker]   with 'Could not authenticate against github.com', set"
    echo "[melis-docker]   GITHUB_TOKEN in .env and restart."
fi

composer config repositories.melis-core            vcs https://github.com/melisplatform/melis-core
composer config repositories.melis-react-api       vcs https://github.com/melisplatform/melis-react-api
composer config repositories.melis-react-override  vcs https://github.com/melisplatform/melis-react-override

# -W (--with-all-dependencies): switching melis-core to the branch may have to move
# transitive deps that a partial update would refuse to touch (same lesson as the
# installer guard). The alias 5.3.999 satisfies any ^5.3 / >=5.3.x constraint while
# staying below the <6.0 cap.
# --no-scripts is REQUIRED: this runs before the platform is installed, and the
# skeleton's post-update-cmd hook (MelisDbDeploy\DbDeployOnComposerUpdate) fatals
# trying to reach the not-yet-configured database ("Call to a member function
# query() on null"), which would fail the whole require. Skipping the hooks here
# loses nothing: the web installer's own Composer runs (no --no-scripts) and its
# dbdeploy pass publish + apply every module's schema deltas during the install —
# same as the vanilla flow, where create-project never fires post-update-cmd.
composer require --no-interaction --no-progress --prefer-dist -W --no-scripts \
    "melisplatform/melis-core:dev-melis-react as 5.3.999" \
    "melisplatform/melis-react-api:dev-melis-react" \
    "melisplatform/melis-react-override:dev-melis-react"

php "$CONF_DIR/enable-react.php" "$APP_DIR/config/application.config.php"
php -l "$APP_DIR/config/application.config.php" >/dev/null

echo "[melis-docker] React back-office enabled — /melis-react goes live once the web"
echo "[melis-docker] installer has completed."
