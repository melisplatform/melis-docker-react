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

# 0) Bind-mount sanity check — REFUSE to bootstrap into a phantom app dir.
#
#    On Rancher Desktop/WSL the docker CLI talks to a `wsl-helper docker-proxy`
#    running in YOUR distro; for every bind mount it creates
#    /mnt/wsl/rancher-desktop/run/docker-mounts/<uuid> and bind-mounts the host path
#    into it, which propagates to the rancher-desktop distro where dockerd runs.
#    Those binds do NOT survive a WSL shutdown / Rancher restart, and a container
#    that dockerd brings back on its own (restart policy, `docker start`) never goes
#    through the proxy's create path — so it comes back with the staging dir EMPTY.
#    Without this check step 1 below sees "no composer.json", cheerfully runs
#    create-project into that phantom dir, and you get a second, divergent Melis
#    tree that Apache serves while your host tree sits there untouched. Diagnosed
#    the hard way: every URL redirecting to /melis/setup and /melis-react 404ing on
#    an install that had completed hours earlier.
#
#    Two independent proofs the mount is real; either is enough:
#      - .melis-mount   — written by `make env` on the host (and by us after a
#                         successful bootstrap), so it can only be visible here if
#                         the bind is live;
#      - composer.json  — any already-bootstrapped tree.
#    Neither + evidence of a previous successful boot (a marker in a NAMED volume,
#    which dockerd manages and therefore can never go phantom) = broken mount.
#    A genuine first run has no marker, so it proceeds normally.
#    Escape hatch: MELIS_MOUNT_CHECK=0.
MOUNT_MARKER="/melis-state/.melis-bootstrapped"
if [ "${MELIS_MOUNT_CHECK:-1}" = "1" ] && [ ! -f .melis-mount ] && [ ! -f composer.json ] \
   && [ -f "$MOUNT_MARKER" ]; then
  cat >&2 <<EOF
[melis-docker-react] FATAL: $APP_DIR is empty, but this stack has booted successfully before.

  The host bind mount (./melis) is detached — the container is looking at an empty
  staging directory, not at your project. This happens on Rancher Desktop/WSL after
  a WSL shutdown, a Rancher Desktop restart, or when dockerd restarts the container
  by itself instead of \`docker compose up\` re-creating it.

  Your code on the host is fine. Re-create the containers so the mount is staged again
  (a restart is NOT enough — only a create goes through the staging helper):

      cd install && docker compose down && docker compose up -d      # or: make up STACK=install

  If you deleted ./melis on purpose to start clean, recreate it first
  (\`mkdir -p melis && touch melis/.melis-mount\`, which is what \`make env\` does), or
  wipe the volumes with \`docker compose down -v\`.
  To bypass this check entirely, set MELIS_MOUNT_CHECK=0 in .env.
EOF
  exit 1
fi

# 1) Bootstrap a fresh Melis skeleton on first run (empty app dir / no composer.json)
if [ ! -f composer.json ]; then
  echo "[melis-docker-react] No Melis project found in $APP_DIR — creating a fresh skeleton..."
  # The vite override (docker-compose.vite.yml) mounts a named volume at
  # vendor/melisplatform/melis-core/ui-react/node_modules, which pre-creates that
  # empty path here and makes create-project refuse the "non-empty" directory.
  # rmdir -p only removes EMPTY dirs and stops at the first non-empty one, so real
  # data is never touched.
  rmdir -p vendor/melisplatform/melis-core/ui-react/node_modules 2>/dev/null || true
  # SKELETON_VERSION (build ARG / compose env): empty = latest stable, otherwise a
  # Composer version or branch, e.g. ^6.0. See the Dockerfile.
  composer create-project \
    "melisplatform/melis-platform-skeleton${SKELETON_VERSION:+:$SKELETON_VERSION}" . \
    --no-interaction --no-progress
fi

# 1b) The app dir is proven good — record it for step 0 of the next boot. The
#     sentinel rides the bind mount (so it is invisible from a phantom staging dir);
#     the marker rides a named volume (so it survives one). Both are needed: the
#     marker alone can't tell "mount broke" from "fresh dir", the sentinel alone
#     can't tell "mount broke" from "never ran".
touch .melis-mount 2>/dev/null || true
mkdir -p "$(dirname "$MOUNT_MARKER")" 2>/dev/null || true
touch "$MOUNT_MARKER" 2>/dev/null || true

# 2) Make sure dependencies are installed (e.g. mounted project without vendor/)
if [ ! -d vendor ]; then
  echo "[melis-docker-react] Installing composer dependencies..."
  composer install --no-interaction --no-progress
fi

# 2b) React back-office (/melis-react): pulls the public `melis-react` branches of
#     melis-core (which ships the committed React build) + the MelisReactApi and
#     MelisReactOverride modules, and patches config/application.config.php.
#     Idempotent (skips once enabled); opt out with WITH_REACT=0 in .env. Not fatal
#     on failure: the legacy back-office still works — fix the cause and restart the
#     container to retry. No GitHub credentials are involved (all Packagist).
if [ "${WITH_REACT:-1}" = "1" ]; then
  bash /melis-conf/enable-react.sh "$APP_DIR" \
    || echo "[melis-docker-react] WARNING: React enablement failed — continuing with the legacy back-office only. See the errors above, then restart the container to retry."
fi

# 2c) Hand the Composer cache these root-run steps just filled to www-data. The web
#     installer runs Composer as www-data; without a readable+writable COMPOSER_HOME
#     it disables caching and re-downloads every repository's metadata (~12 min in
#     the wizard's module step when the skeleton still declares laminas vcs repos).
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

# ---------------------------------------------------------------------------
# Applier MELIS_MODULE : le wizard d'installation peut demander l'adoption du
# module de site qu'on y a choisi (voir conf/melis-module-applier.sh). PHP tourne
# en www-data et ne peut écrire ni la conf du serveur (root) ni le .env de la
# stack (propriété de l'hôte) : il dépose une requête, ce watcher root l'applique
# et recharge le serveur à chaud — sans redémarrer le conteneur, qui reviendrait
# avec un bind mount vide sur Rancher/WSL (cf. gotcha 12).
#
# Démarré en tâche de fond AVANT le `exec` : il ne remplace pas PID 1, ne touche
# à rien tant qu'aucune requête n'est déposée, et son absence ne casse rien (le
# wizard signale simplement que la valeur n'a pas pu être appliquée).
# ---------------------------------------------------------------------------
if [ -f /melis-conf/melis-module-applier.sh ]; then
  APP_DIR="$APP_DIR" \
  MELIS_STACK_DIR="${MELIS_STACK_DIR:-/melis-stack}" \
  MELIS_RELOAD_MODE="apache" \
  MELIS_VHOST_FILE="/etc/apache2/sites-available/000-default.conf" \
    bash /melis-conf/melis-module-applier.sh &
fi

exec apache2-foreground
