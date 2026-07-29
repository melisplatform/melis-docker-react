#!/bin/bash
# Melis turnkey entrypoint.
# - Bootstraps a fresh Melis skeleton if the app directory is empty.
# - Waits for MySQL (via PHP/mysqli — avoids the MariaDB-client TLS issue).
# - Leaves DB schema / admin / demo to the Melis web installer (localhost:8080).
set -e

APP_DIR="/var/www/${APP_NAME:-melis}"
DB_HOST="${MYSQL_HOST:-db}"
DB_USER="${MYSQL_USER:-melis}"
DB_PASS="${MYSQL_PASSWORD:-melis}"
DB_NAME="${MYSQL_DATABASE:-melis}"

cd "$APP_DIR"

# 1) Bootstrap a fresh Melis skeleton on first run (empty app dir / no composer.json)
if [ ! -f composer.json ]; then
  echo "[melis-docker-react] No Melis project found in $APP_DIR — creating a fresh skeleton..."
  # The vite override (docker-compose.vite.yml) mounts a named volume at
  # vendor/melisplatform/melis-core/ui-react/node_modules, which pre-creates that
  # empty path here and makes create-project refuse the "non-empty" directory.
  # rmdir -p only removes EMPTY dirs and stops at the first non-empty one, so real
  # data is never touched.
  rmdir -p vendor/melisplatform/melis-core/ui-react/node_modules 2>/dev/null || true
  composer create-project melisplatform/melis-platform-skeleton . --no-interaction --no-progress
fi

# 2) Make sure dependencies are installed (e.g. mounted project without vendor/)
if [ ! -d vendor ]; then
  echo "[melis-docker-react] Installing composer dependencies..."
  composer install --no-interaction --no-progress
fi

# 2b) React back-office (/melis-react): pulls the public `melis-react` branches of
#     melis-core (which ships the committed React build) + the MelisReactApi and
#     MelisReactOverride modules, and patches config/application.config.php.
#     Idempotent (skips once enabled); opt out with WITH_REACT=0 in .env. Not fatal
#     on failure: the legacy back-office still works — fix the cause (usually a
#     missing GITHUB_TOKEN) and restart the container to retry.
if [ "${WITH_REACT:-1}" = "1" ]; then
  bash /melis-conf/enable-react.sh "$APP_DIR" \
    || echo "[melis-docker-react] WARNING: React enablement failed — continuing with the legacy back-office only. See the errors above, then restart the container to retry."
fi

# 2c) Hand the Composer cache these root-run steps just filled to www-data. The web
#     installer runs Composer as www-data; without a readable+writable COMPOSER_HOME
#     it disables caching and re-downloads every repository's metadata (~12 min in
#     the wizard's module step with this project's 7 vcs repos).
chown -R www-data:www-data "${COMPOSER_HOME:-/composer}" 2>/dev/null || true

# 3) Wait for the database (PHP/mysqli — works with MySQL 8.x TLS, unlike the CLI client).
#    Env vars are exported BEFORE php so getenv() sees them; MYSQLI_REPORT_OFF makes
#    a failed connect return false instead of throwing (PHP 8.1+ default is exceptions).
echo "[melis-docker-react] Waiting for MySQL at ${DB_HOST}..."
tries=0
until DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASS="$DB_PASS" \
      php -r 'mysqli_report(MYSQLI_REPORT_OFF); exit(@mysqli_connect(getenv("DB_HOST"),getenv("DB_USER"),getenv("DB_PASS"))?0:1);'; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "[melis-docker-react] WARNING: MySQL still unreachable after ~3 min — starting Apache anyway; the web installer will retry."
    break
  fi
  sleep 3
done
# Safety net: ensure the (empty) database exists — the installer fills it
DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASS="$DB_PASS" DB_NAME="$DB_NAME" php -r '
  mysqli_report(MYSQLI_REPORT_OFF);
  $c=@mysqli_connect(getenv("DB_HOST"),getenv("DB_USER"),getenv("DB_PASS"));
  if($c){mysqli_query($c,"CREATE DATABASE IF NOT EXISTS `".getenv("DB_NAME")."` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci");}
' || true

# 4) Permissions: the installer writes config/, Melis writes cache/
mkdir -p "$APP_DIR/config" "$APP_DIR/cache" "$APP_DIR/mnt/public/media"
chown -R www-data:www-data "$APP_DIR" || true
chmod -R 775 "$APP_DIR/config" "$APP_DIR/cache" 2>/dev/null || true

echo "[melis-docker-react] ============================================================"
echo "[melis-docker-react]  Melis is ready. Open http://localhost:${HOST_PORT:-8080}"
echo "[melis-docker-react]  and follow the web installer."
echo "[melis-docker-react]  DB to enter in the wizard:  host=${DB_HOST}  db=${DB_NAME}"
echo "[melis-docker-react]                              user=${DB_USER}  pass=${DB_PASS}"
if [ "${WITH_REACT:-1}" = "1" ]; then
  echo "[melis-docker-react]  React back-office (once installed):"
  echo "[melis-docker-react]    http://localhost:${HOST_PORT:-8080}/melis-react"
fi
echo "[melis-docker-react] ============================================================"

exec apache2-foreground
