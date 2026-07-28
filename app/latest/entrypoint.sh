#!/bin/bash
# Melis legacy dev-stack entrypoint (app/latest).
#
# UNLIKE install/entrypoint.sh this NEVER creates a project: this stack mounts an
# EXISTING Melis project from the host (../../../ → /var/www/$APP_NAME). It only:
#   - optionally installs vendor/ if the mounted project has none;
#   - optionally enables the React back-office (WITH_REACT=1, OFF by default here);
#   - waits for MySQL (via PHP/mysqli — the MariaDB CLI client rejects MySQL 8.x TLS);
#   - fixes up the few dirs Melis must write to.
# DB schema / admin user / demo site stay the job of the Melis web installer.
set -e

APP_DIR="/var/www/${APP_NAME:-melis}"
DB_HOST="${MYSQL_HOST:-db}"
DB_USER="${MYSQL_USER:-melis}"
DB_PASS="${MYSQL_PASSWORD:-melis}"
DB_NAME="${MYSQL_DATABASE:-melis}"

cd "$APP_DIR"

if [ ! -f composer.json ]; then
  echo "[melis-docker] WARNING: no composer.json in $APP_DIR."
  echo "[melis-docker]   This stack mounts an EXISTING Melis project from ../../../ —"
  echo "[melis-docker]   it does not create one. Check the bind mount in docker-compose.yml,"
  echo "[melis-docker]   or use the install/ stack to bootstrap a fresh skeleton."
fi

# 1) Dependencies: only when the mounted project has none. Never touched otherwise —
#    this is the user's own codebase, not a skeleton we generated.
if [ -f composer.json ] && [ ! -d vendor ]; then
  echo "[melis-docker] No vendor/ in the mounted project — running composer install..."
  composer install --no-interaction --no-progress || \
    echo "[melis-docker] WARNING: composer install failed — see the errors above."
fi

# 2) React back-office (/melis-react). OFF by default in this stack: unlike
#    install/ (whose ./melis skeleton we generated ourselves), the app dir here is
#    YOUR pre-existing project, and enabling React rewrites its composer.json,
#    composer.lock and config/application.config.php on the host. Opt in with
#    WITH_REACT=1 in .env once you're happy for that to happen (commit first).
#    Idempotent, and never fatal: a failure leaves the legacy back-office working.
if [ "${WITH_REACT:-0}" = "1" ] && [ -f composer.json ]; then
  bash /melis-conf/enable-react.sh "$APP_DIR" \
    || echo "[melis-docker] WARNING: React enablement failed — continuing with the legacy back-office only. See the errors above, then restart the container to retry."
fi

# 3) Hand the Composer cache these root-run steps just filled to www-data. The web
#    installer runs Composer *inside an HTTP request*, i.e. as www-data; without a
#    readable+writable COMPOSER_HOME it disables caching and re-fetches every
#    repository's metadata on every run (~12 min in the wizard's module step with
#    this project's GitHub vcs repositories).
chown -R www-data:www-data "${COMPOSER_HOME:-/composer}" 2>/dev/null || true

# 4) Wait for the database (PHP/mysqli — works with MySQL 8.x TLS, unlike the CLI
#    client). Creds go through the ENVIRONMENT, not $argv: passing them as args
#    leaves getenv() empty, the loop spins forever and Apache never starts (HTTP 000).
#    MYSQLI_REPORT_OFF makes a failed connect return false instead of throwing.
echo "[melis-docker] Waiting for MySQL at ${DB_HOST}..."
tries=0
until DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASS="$DB_PASS" \
      php -r 'mysqli_report(MYSQLI_REPORT_OFF); exit(@mysqli_connect(getenv("DB_HOST"),getenv("DB_USER"),getenv("DB_PASS"))?0:1);'; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "[melis-docker] WARNING: MySQL still unreachable after ~3 min — starting Apache anyway; the web installer will retry."
    break
  fi
  sleep 3
done
# Safety net: ensure the database exists with the collation the installer demands
# (utf8mb4_general_ci — it rejects utf8mb4_unicode_ci at "Test database connection").
DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASS="$DB_PASS" DB_NAME="$DB_NAME" php -r '
  mysqli_report(MYSQLI_REPORT_OFF);
  $c=@mysqli_connect(getenv("DB_HOST"),getenv("DB_USER"),getenv("DB_PASS"));
  if($c){mysqli_query($c,"CREATE DATABASE IF NOT EXISTS `".getenv("DB_NAME")."` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci");}
' || true

# 5) Permissions. Deliberately NOT a `chown -R` of the whole app dir: that dir is a
#    bind mount of your host working copy, and on Linux the ownership change is real
#    and permanent on the host. Only the paths Melis actually writes to are touched.
#
#    This list is exactly what the wizard's "Step 1.3: File system rights" checks.
#    A checkout cloned by your own user is mode 755 and owned by you, so Apache
#    (www-data, uid 33) gets r-x only and every one of these reports ✗ — the step
#    that made this fix necessary. Only the directories are chowned, not their
#    contents (`-R` is reserved for the small config trees Melis rewrites wholesale):
#    the wizard tests the directory, and files created later inherit www-data anyway.
mkdir -p \
    "$APP_DIR/config/autoload/platforms" \
    "$APP_DIR/cache" \
    "$APP_DIR/mnt/public/media" \
    "$APP_DIR/data" \
    "$APP_DIR/dbdeploy/data" \
    "$APP_DIR/public" \
    "$APP_DIR/etc/bundles" \
    "$APP_DIR/test" \
    "$APP_DIR/thirdparty" \
    "$APP_DIR/module/MelisSites" \
    "$APP_DIR/module/MelisModuleConfig/config" \
    "$APP_DIR/module/MelisModuleConfig/languages" \
    2>/dev/null || true
# Melis rewrites these wholesale → recurse.
chown -R www-data:www-data \
    "$APP_DIR/config" "$APP_DIR/cache" "$APP_DIR/mnt" \
    "$APP_DIR/module/MelisModuleConfig" 2>/dev/null || true
chmod -R 775 "$APP_DIR/config" "$APP_DIR/cache" 2>/dev/null || true
# Directory itself only — never touch the user's files underneath.
for d in data dbdeploy dbdeploy/data public "etc/bundles" test thirdparty \
         "module" "module/MelisSites"; do
    chown www-data:www-data "$APP_DIR/$d" 2>/dev/null || true
    chmod 775 "$APP_DIR/$d" 2>/dev/null || true
done

echo "[melis-docker] ============================================================"
echo "[melis-docker]  Melis (app/latest) is ready. Open http://localhost:${HOST_PORT:-8080}"
echo "[melis-docker]  DB to enter in the wizard:  host=${DB_HOST}  db=${DB_NAME}"
echo "[melis-docker]                              user=${DB_USER}  pass=${DB_PASS}"
if [ "${WITH_REACT:-0}" = "1" ]; then
  echo "[melis-docker]  React back-office: http://localhost:${HOST_PORT:-8080}/melis-react"
else
  echo "[melis-docker]  React back-office: disabled (set WITH_REACT=1 in .env to enable)"
fi
echo "[melis-docker] ============================================================"

exec apache2-foreground
