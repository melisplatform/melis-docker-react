#!/usr/bin/env bash
# =============================================================================
#  melis-module-applier — applies the MELIS_MODULE chosen in the install wizard
# -----------------------------------------------------------------------------
#  The site module name is picked during SETUP, but MELIS_MODULE is a DEPLOYMENT
#  variable (vhost + .env). PHP cannot write either one: Apache config belongs to
#  root, the stack .env belongs to the host user (the entrypoint deliberately
#  leaves it out of its chown, see .env.example), and you cannot change the
#  environment of a process that is already running anyway.
#
#  So this script runs as root. The entrypoint starts it in the background just
#  before `exec apache2-foreground`. It watches for a request file dropped by PHP
#  (www-data), and when one shows up it:
#     1. re-checks the name — the endpoint is public, so the value is untrusted;
#     2. rewrites the MELIS_MODULE= line of the stack .env, so the value survives
#        a `make down && make up`;
#     3. rewrites `SetEnv MELIS_MODULE` in the vhost, so the value is live from
#        the next request on, with no container restart (on Rancher/WSL a restart
#        comes back with an empty bind mount, see CLAUDE.md);
#     4. runs `apache2ctl graceful`, letting in-flight requests finish;
#     5. writes an acknowledgement file that the wizard polls.
#
#  Nothing here is destructive: only the MELIS_MODULE line is touched in each
#  file, and nothing is written until the name passes validation. With no request
#  file, the script does nothing at all.
#
#  It stops on its own once the platform is installed (see the loop at the end).
# =============================================================================
set -u

APP_DIR="${APP_DIR:-/var/www/${APP_NAME:-melis}}"
STACK_DIR="${MELIS_STACK_DIR:-}"
VHOST_FILE="${MELIS_VHOST_FILE:-/etc/apache2/sites-available/vhost.conf}"
REQUEST_FILE="$APP_DIR/data/.melis-module-request"
APPLIED_FILE="$APP_DIR/data/.melis-module-applied"
LOCK_FILE="/run/melis-module-applier.lock"
# "Install finished" marker, written by finalizeSetup (InstallerController).
# The watcher stops as soon as it appears — see the loop at the end of the file.
INSTALL_MARKER="$APP_DIR/config/melis.install"
POLL_SECONDS="${MELIS_MODULE_POLL_SECONDS:-2}"
# apache (mod_php: SetEnv + graceful) or fpm (env[] in a pool + SIGUSR2 to the master).
RELOAD_MODE="${MELIS_RELOAD_MODE:-apache}"
FPM_POOL_FILE="${MELIS_FPM_POOL_FILE:-/usr/local/etc/php-fpm.d/zz-melis-module.conf}"

log() { echo "[melis-module-applier] $*"; }

# Acknowledgement the wizard reads: "<applied|failed> <module>".
ack() {
    printf '%s %s\n' "$1" "${2:-}" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
    chown www-data:www-data "$APPLIED_FILE" 2>/dev/null || true
    chmod 664 "$APPLIED_FILE" 2>/dev/null || true
}

# Rewrites "KEY=value" in a file, touching ONLY that line. The content is written
# back by truncating the file (`>`), not with `sed -i` or a rename: the .env has to
# keep its inode and its owner on the host side.
set_key() {
    local file="$1" key="$2" value="$3" tmp
    [ -f "$file" ] || return 1
    tmp="$(mktemp)" || return 1
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        awk -v key="$key" -v value="$value" '
            $0 ~ "^[[:space:]]*" key "=" { print key "=" value; next } { print }
        ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        cat "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# The value actually being served: the one in the vhost if it is written there as a
# literal (a previous run put it there), otherwise the one from the container
# environment. Trusting $MELIS_MODULE alone would wrongly skip the work when going
# back to the value the container started with.
current_module() {
    local from_vhost=''
    if [ "$RELOAD_MODE" = "fpm" ] && [ -f "$FPM_POOL_FILE" ]; then
        from_vhost="$(sed -n 's/^[[:space:]]*env\[MELIS_MODULE\][[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$FPM_POOL_FILE" | tail -n 1)"
    elif [ -f "$VHOST_FILE" ]; then
        from_vhost="$(sed -n 's/^[[:space:]]*SetEnv[[:space:]]\+MELIS_MODULE[[:space:]]\+"\([^"]*\)".*/\1/p' "$VHOST_FILE" | tail -n 1)"
    fi
    case "$from_vhost" in
        ''|*'${'*) printf '%s' "${MELIS_MODULE:-}" ;;
        *) printf '%s' "$from_vhost" ;;
    esac
}

apply() {
    local module="$1"

    # The name comes from a page served before login and ends up inside an Apache
    # config file: allow a strict character set only, and never expand it unquoted.
    case "$module" in
        *[!A-Za-z0-9_-]* | '')
            log "rejected: invalid module name"
            ack failed ""
            return
            ;;
    esac
    if [ "${#module}" -gt 64 ]; then
        log "rejected: module name too long"
        ack failed ""
        return
    fi

    # Already the current value: acknowledge without reloading Apache.
    if [ "$(current_module)" = "$module" ]; then
        log "MELIS_MODULE is already '$module' — nothing to do"
        ack applied "$module"
        return
    fi

    local ok=1

    if [ -n "$STACK_DIR" ] && [ -f "$STACK_DIR/.env" ]; then
        if set_key "$STACK_DIR/.env" MELIS_MODULE "$module"; then
            log "wrote MELIS_MODULE=$module to $STACK_DIR/.env"
        else
            log "WARNING: could not write $STACK_DIR/.env"
            ok=0
        fi
    else
        log "WARNING: no .env reachable (STACK_DIR='$STACK_DIR') — the value will not survive a down/up"
    fi

    if [ "$RELOAD_MODE" = "fpm" ]; then
        # PHP-FPM inherits the container environment (clear_env = no). Override it with
        # an extra pool file, then SIGUSR2 the master (PID 1) to reload without downtime.
        printf '[www]\nenv[MELIS_MODULE] = "%s"\n' "$module" > "$FPM_POOL_FILE" || ok=0
        if kill -USR2 1 2>/dev/null; then
            log "php-fpm reloaded (SIGUSR2) with MELIS_MODULE=$module"
        else
            log "ERROR: could not signal php-fpm"
            ok=0
        fi
    else
        # The vhost reads ${MELIS_MODULE} from the Apache process environment, which was
        # frozen at startup. Replace that expansion with the literal value.
        if [ -f "$VHOST_FILE" ]; then
            local tmp
            tmp="$(mktemp)"
            awk -v value="$module" '
                /^[[:space:]]*SetEnv[[:space:]]+MELIS_MODULE[[:space:]]/ {
                    match($0, /^[[:space:]]*/)
                    printf "%sSetEnv MELIS_MODULE \"%s\"\n", substr($0, 1, RLENGTH), value
                    next
                }
                { print }
            ' "$VHOST_FILE" > "$tmp" && cat "$tmp" > "$VHOST_FILE"
            rm -f "$tmp"
        fi

        # Safety net for stacks whose vhost has no SetEnv line (install/prebuilt):
        # conf-enabled is included at server level, and when the vhost sets the variable
        # itself the vhost wins. So the two writes complement each other.
        printf 'SetEnv MELIS_MODULE "%s"\n' "$module" > /etc/apache2/conf-enabled/zz-melis-module.conf 2>/dev/null || true

        if apache2ctl configtest >/dev/null 2>&1; then
            apache2ctl graceful >/dev/null 2>&1 || ok=0
            log "Apache reloaded (graceful) with MELIS_MODULE=$module"
        else
            log "ERROR: Apache configtest failed, no reload"
            ok=0
        fi
    fi

    if [ "$ok" = "1" ]; then
        ack applied "$module"
    else
        ack failed "$module"
    fi
}

# Is the platform installed? Read it the same way melis-installer does in Module.php
# (`(bool) trim(file_get_contents(...))`): the file must exist AND hold something PHP
# considers true, so neither empty nor "0". finalizeSetup writes 1.
platform_installed() {
    [ -f "$INSTALL_MARKER" ] || return 1
    case "$(tr -d '[:space:]' < "$INSTALL_MARKER" 2>/dev/null)" in
        '' | 0) return 1 ;;
        *) return 0 ;;
    esac
}

# An installed platform has no wizard left: the route that drops request files lives
# in MelisInstaller, which finalizeSetup unplugs. Nothing to watch for.
if platform_installed; then
    log "platform already installed ($INSTALL_MARKER) — nothing to watch"
    exit 0
fi

log "watching $REQUEST_FILE"
while true; do
    if [ -f "$REQUEST_FILE" ]; then
        module="$(head -n 1 "$REQUEST_FILE" | tr -d '[:space:]')"
        rm -f "$REQUEST_FILE"
        # flock: Apache serves the healthcheck and the browser at the same time, so
        # allow only one apply at a time.
        (
            flock -w 30 9 || exit 1
            apply "$module"
        ) 9>"$LOCK_FILE"
    fi
    # Install finished: stop, instead of leaving a root process running for the life of
    # the container watching a file that www-data can write. This check comes AFTER the
    # block above on purpose — the wizard's last step asks for the module JUST BEFORE
    # calling finalizeSetup, so a pending request still has to be served.
    if platform_installed; then
        log "platform installed — stopping the watcher"
        exit 0
    fi
    sleep "$POLL_SECONDS"
done
