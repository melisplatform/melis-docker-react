#!/bin/bash
# Melis legacy dev-stack entrypoint (app/latest).
#
# UNLIKE install/entrypoint.sh this NEVER creates a project: this stack mounts an
# EXISTING Melis project from the host (../../../ → /var/www/$APP_NAME). It only:
#   - optionally installs vendor/ if the mounted project has none;
#   - enables the React back-office (WITH_REACT=1 by default; set 0 to opt out);
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

# 0) Bind-mount sanity check. This stack NEVER creates a project, so the mounted
#    tree always has a composer.json — its absence means the bind mount is not
#    pointing where you think. On Rancher Desktop/WSL that is the usual cause: the
#    bind is staged by a `wsl-helper docker-proxy` in your WSL distro at container-
#    CREATE time and does not survive a WSL shutdown / Rancher restart, so a
#    container dockerd brings back by itself gets an EMPTY staging dir. Failing
#    loudly here beats serving an empty document root (or, worse, letting the React
#    enablement rewrite files in a phantom tree). Escape hatch: MELIS_MOUNT_CHECK=0.
if [ ! -f composer.json ] && [ "${MELIS_MOUNT_CHECK:-1}" = "1" ]; then
  cat >&2 <<EOF
[melis-docker-react] FATAL: no composer.json in $APP_DIR — the bind mount looks broken.

  This stack mounts an EXISTING Melis project from ../../../ and never creates one,
  so this directory should not be empty. Most likely the host bind mount is detached
  (Rancher Desktop/WSL stages it at container-create time and loses it on a WSL or
  Rancher restart). Your code on the host is fine.

  Re-create the container so the mount is staged again (a restart is NOT enough —
  only a create goes through the staging helper):

      cd app/latest && docker compose down && docker compose up -d   # or: make up STACK=app/latest

  If the path really is wrong, check the \`../../../\` volume in docker-compose.yml —
  this stack expects to live at <your-melis-project>/melis-docker/app/latest.
  To bypass this check, set MELIS_MOUNT_CHECK=0 in .env.
EOF
  exit 1
fi

# 1) Dependencies: only when the mounted project has none. Never touched otherwise —
#    this is the user's own codebase, not a skeleton we generated.
if [ -f composer.json ] && [ ! -d vendor ]; then
  echo "[melis-docker-react] No vendor/ in the mounted project — running composer install..."
  composer install --no-interaction --no-progress || \
    echo "[melis-docker-react] WARNING: composer install failed — see the errors above."
fi

# 2) React back-office (/melis-react). ON by default, like every other stack.
#    ⚠ Mind what that means HERE specifically: unlike install/ (whose ./melis
#    skeleton we generated ourselves), the app dir is YOUR pre-existing project, so
#    this rewrites its composer.json, composer.lock and config/application.config.php
#    ON THE HOST. Commit your work before the first boot, or set WITH_REACT=0 in .env.
#    Idempotent, and never fatal: a failure leaves the legacy back-office working.
if [ "${WITH_REACT:-1}" = "1" ] && [ -f composer.json ]; then
  bash /melis-conf/enable-react.sh "$APP_DIR" \
    || echo "[melis-docker-react] WARNING: React enablement failed — continuing with the legacy back-office only. See the errors above, then restart the container to retry."
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
#
#    NOT ENOUGH ON ITS OWN if you intend to run the web installer: it also rewrites
#    composer.json/composer.lock and installs modules into vendor/. Step 5b covers those.
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

# 5b) Make the project writable by Apache so the WEB INSTALLER can run. It rewrites
#     composer.json/composer.lock and composer-installs modules into vendor/ — all as
#     www-data. A checkout owned by your user (uid 1000, mode 755) blocks those, and
#     the wizard dies with "./composer.json is not writable".
#
#     Note this CANNOT be done in the Dockerfile: docker-compose bind-mounts your
#     project over the app dir at runtime, masking any ownership baked into the image.
#
#     ⚠ It is a real, permanent ownership change on your host working copy — you may
#     need sudo to edit your files afterwards (`sudo chown -R $(id -u):$(id -g) .`
#     reverses it, until the next boot re-applies this).
#
#     UNCONDITIONAL, like install/entrypoint.sh's `chown -R www-data:www-data
#     "$APP_DIR"`. It used to be guarded by a `test -w` probe on $APP_DIR,
#     composer.json and vendor as an "optimisation" — but those three paths are
#     exactly the ones that are already yours, so the probe passed while whole
#     subtrees underneath were not www-data at all, and the walk never ran:
#       - step 2 (`enable-react.sh`) runs Composer as ROOT, and Composer REPLACES
#         `vendor/melisplatform/melis-core` wholesale every time it touches the
#         package → thousands of root:root files inside your working copy;
#       - anything written by a boot from before the HOST_UID remap stays at
#         uid 33.
#     Neither is visible to the probe. Result: `EACCES: permission denied` in the
#     editor on e.g. vendor/melisplatform/melis-core/ui-react/src/... — the React
#     UI source you are meant to be editing. Observed 2026-07-30.
#
#     With the remap in place (HOST_UID, default 1000) this resolves to YOUR uid,
#     so a walk on every boot is also the repair path for a tree already spoiled
#     by either case above — no `sudo chown` needed.
echo "[melis-docker-react] Making the mounted project writable by www-data (needed by the web installer)."
# Skip this repo itself — it is cloned INSIDE your project (that is how the
# ../../../ bind mount finds it), Melis never writes to it, and chowning it
# would mean needing sudo just to edit .env or docker-compose.yml.
find "$APP_DIR" \( -name 'melis-docker' -o -name 'melis-docker-react' \) -prune \
    -o -exec chown www-data:www-data {} + 2>/dev/null || true

echo "[melis-docker-react] ============================================================"
echo "[melis-docker-react]  Melis (app/latest) is ready. Open http://localhost:${HOST_PORT:-8080}"
echo "[melis-docker-react]  DB to enter in the wizard:  host=${DB_HOST}  db=${DB_NAME}"
echo "[melis-docker-react]                              user=${DB_USER}  pass=${DB_PASS}"
if [ "${WITH_REACT:-1}" = "1" ]; then
  echo "[melis-docker-react]  React back-office: http://localhost:${HOST_PORT:-8080}/melis-react"
else
  echo "[melis-docker-react]  React back-office: disabled (set WITH_REACT=1 in .env to enable)"
fi
echo "[melis-docker-react] ============================================================"

# ---------------------------------------------------------------------------
# Applier MELIS_MODULE : le wizard d'installation peut demander l'adoption du
# module de site qu'on y a choisi (voir conf/melis-module-applier.sh). PHP tourne
# en www-data et ne peut écrire ni la conf Apache (root) ni le .env de la stack
# (propriété de l'hôte) : il dépose une requête, ce watcher root l'applique et
# recharge Apache gracieusement — sans redémarrer le conteneur, qui reviendrait
# avec un bind mount vide sur Rancher/WSL.
#
# Démarré en tâche de fond AVANT le `exec` : il ne remplace pas PID 1, ne touche
# à rien tant qu'aucune requête n'est déposée, et son absence ne casse rien (le
# wizard signale simplement que la valeur n'a pas pu être appliquée).
# ---------------------------------------------------------------------------
if [ -f /melis-conf/melis-module-applier.sh ]; then
  APP_DIR="$APP_DIR" \
  MELIS_STACK_DIR="$APP_DIR/melis-docker-react/app/latest" \
  MELIS_VHOST_FILE="/etc/apache2/sites-available/vhost.conf" \
    bash /melis-conf/melis-module-applier.sh &
fi

exec apache2-foreground
