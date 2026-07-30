#!/bin/bash
# Melis pre-built entrypoint.
# The skeleton is already baked into the image, so — unlike the turnkey install
# — we do NOT run composer create-project here. We only:
#   - (defensively) bootstrap if the app dir was emptied by a host mount,
#   - wait for MySQL (via PHP/mysqli — avoids the MariaDB-client TLS issue),
#   - leave DB schema / admin / demo to the Melis web installer.
set -e

APP_DIR="/var/www/${APP_NAME:-melis}"
DB_HOST="${MYSQL_HOST:-db}"
DB_USER="${MYSQL_USER:-melis}"
DB_PASS="${MYSQL_PASSWORD:-melis}"
DB_NAME="${MYSQL_DATABASE:-melis}"

cd "$APP_DIR"

# 0) Defensive: if a host bind-mount hid the baked skeleton, rebuild it. With the
#    default named volume this branch is skipped (the volume is seeded from the image).
if [ ! -f composer.json ]; then
  echo "[melis-docker-react] App dir empty (mounted over the baked image?) — creating a fresh skeleton..."
  # The vite override's node_modules volume pre-creates an empty vendor/... path
  # that would make create-project refuse the "non-empty" directory. rmdir -p only
  # removes EMPTY dirs, so real data is never touched.
  rmdir -p vendor/melisplatform/melis-core/ui-react/node_modules 2>/dev/null || true
  # SKELETON_VERSION comes from the image (build ARG) or compose env; empty = latest
  # stable, otherwise a Composer version or branch (e.g. dev-test/removed-forks).
  composer create-project \
    "melisplatform/melis-platform-skeleton${SKELETON_VERSION:+:$SKELETON_VERSION}" . \
    --no-interaction --no-progress --prefer-dist
fi
if [ ! -d vendor ]; then
  echo "[melis-docker-react] Installing composer dependencies..."
  composer install --no-interaction --no-progress
fi

# 0b) React back-office (/melis-react): baked into the image, so this is a no-op on
#     a normal run. It only does real work when the app volume predates the React
#     variant or the defensive bootstrap above rebuilt the skeleton. Not fatal on
#     failure: the legacy back-office still works. Opt out with WITH_REACT=0.
if [ "${WITH_REACT:-1}" = "1" ] && [ -f /melis-conf/enable-react.sh ]; then
  bash /melis-conf/enable-react.sh "$APP_DIR" \
    || echo "[melis-docker-react] WARNING: React enablement failed — continuing with the legacy back-office only. See the errors above; restart the container to retry."
fi

# 0c) Keep the Composer cache owned by www-data — the web installer runs Composer as
#     that user and, without a readable+writable COMPOSER_HOME, disables caching and
#     re-downloads every repository's metadata (~12 min in the wizard's module step
#     when the skeleton still declares laminas vcs repos). Normally a no-op: the
#     image already chowns it.
chown -R www-data:www-data "${COMPOSER_HOME:-/composer}" 2>/dev/null || true

# 1) Wait for the database (PHP/mysqli — works with MySQL 8.x TLS, unlike the CLI client).
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

# 2) Permissions: the installer writes config/, Melis writes cache/
mkdir -p "$APP_DIR/config" "$APP_DIR/cache" "$APP_DIR/mnt/public/media"
chown -R www-data:www-data "$APP_DIR" || true
chmod -R 775 "$APP_DIR/config" "$APP_DIR/cache" 2>/dev/null || true

echo "[melis-docker-react] ============================================================"
echo "[melis-docker-react]  Melis (pre-built) is ready. Open http://localhost:${HOST_PORT:-8080}"
echo "[melis-docker-react]  and follow the web installer."
echo "[melis-docker-react]  DB to enter in the wizard:  host=${DB_HOST}  db=${DB_NAME}"
echo "[melis-docker-react]                              user=${DB_USER}  pass=${DB_PASS}"
if [ "${WITH_REACT:-1}" = "1" ]; then
  echo "[melis-docker-react]  React back-office (once installed):"
  echo "[melis-docker-react]    http://localhost:${HOST_PORT:-8080}/melis-react"
fi
echo "[melis-docker-react] ============================================================"

exec apache2-foreground
