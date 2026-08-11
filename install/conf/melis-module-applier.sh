#!/usr/bin/env bash
# =============================================================================
#  melis-module-applier — adopte le MELIS_MODULE choisi dans le wizard
# -----------------------------------------------------------------------------
#  Le nom du module de site est une décision de SETUP, mais MELIS_MODULE est une
#  variable de DÉPLOIEMENT (vhost + .env), que PHP ne peut pas écrire : Apache
#  tourne en root, le .env de la stack appartient à l'hôte (l'entrypoint le
#  laisse volontairement hors du chown, cf. .env.example), et l'environnement
#  d'un processus déjà lancé n'est de toute façon pas modifiable de l'extérieur.
#
#  Ce script tourne donc en root, lancé en tâche de fond par l'entrypoint AVANT
#  `exec apache2-foreground`. Il surveille un fichier de requête déposé par PHP
#  (www-data) et, quand il en voit un :
#     1. revalide le nom (l'endpoint est public, la valeur est NON fiable) ;
#     2. réécrit la ligne MELIS_MODULE= du .env de la stack → survit à un
#        `make down && make up` ;
#     3. réécrit le `SetEnv MELIS_MODULE` du vhost → la valeur est vraie pour la
#        requête suivante, sans redémarrer le conteneur (sur Rancher/WSL un
#        restart remonte un bind mount vide, cf. CLAUDE.md) ;
#     4. `apache2ctl graceful` — les requêtes en cours vont au bout ;
#     5. acquitte dans un fichier marqueur que le wizard interroge.
#
#  Aucune de ces étapes n'est destructive : seule la ligne MELIS_MODULE est
#  touchée dans chaque fichier, et rien n'est écrit tant que le nom n'est pas
#  valide. Sans requête, le script ne fait strictement rien.
# =============================================================================
set -u

APP_DIR="${APP_DIR:-/var/www/${APP_NAME:-melis}}"
STACK_DIR="${MELIS_STACK_DIR:-}"
VHOST_FILE="${MELIS_VHOST_FILE:-/etc/apache2/sites-available/vhost.conf}"
REQUEST_FILE="$APP_DIR/data/.melis-module-request"
APPLIED_FILE="$APP_DIR/data/.melis-module-applied"
LOCK_FILE="/run/melis-module-applier.lock"
POLL_SECONDS="${MELIS_MODULE_POLL_SECONDS:-2}"
# apache (mod_php : SetEnv + graceful) ou fpm (env[] dans un pool + SIGUSR2 sur le maître).
RELOAD_MODE="${MELIS_RELOAD_MODE:-apache}"
FPM_POOL_FILE="${MELIS_FPM_POOL_FILE:-/usr/local/etc/php-fpm.d/zz-melis-module.conf}"

log() { echo "[melis-module-applier] $*"; }

# Acquittement lu par le wizard : "<applied|failed> <module>".
ack() {
    printf '%s %s\n' "$1" "${2:-}" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
    chown www-data:www-data "$APPLIED_FILE" 2>/dev/null || true
    chmod 664 "$APPLIED_FILE" 2>/dev/null || true
}

# Réécrit "KEY=value" dans un fichier en ne touchant QUE cette ligne. Le contenu
# est réinjecté par troncature (`>`), pas par `sed -i`/rename : le .env doit
# garder son inode et son propriétaire côté hôte.
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

# Valeur réellement servie : celle du vhost si elle y est littérale (une application
# précédente l'y a écrite), sinon celle de l'environnement du conteneur. Se fier au seul
# $MELIS_MODULE ferait sauter à tort l'application d'un retour à la valeur de démarrage.
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

    # Le nom vient d'une page pré-authentification et atterrit dans une conf
    # Apache : liste blanche stricte, et jamais d'interpolation non quotée.
    case "$module" in
        *[!A-Za-z0-9_-]* | '')
            log "refus du nom de module invalide"
            ack failed ""
            return
            ;;
    esac
    if [ "${#module}" -gt 64 ]; then
        log "refus : nom de module trop long"
        ack failed ""
        return
    fi

    # Déjà la valeur courante → on acquitte sans recharger Apache.
    if [ "$(current_module)" = "$module" ]; then
        log "MELIS_MODULE vaut déjà '$module' — rien à faire"
        ack applied "$module"
        return
    fi

    local ok=1

    if [ -n "$STACK_DIR" ] && [ -f "$STACK_DIR/.env" ]; then
        if set_key "$STACK_DIR/.env" MELIS_MODULE "$module"; then
            log "MELIS_MODULE=$module écrit dans $STACK_DIR/.env"
        else
            log "ATTENTION : impossible d'écrire $STACK_DIR/.env"
            ok=0
        fi
    else
        log "ATTENTION : pas de .env accessible (STACK_DIR='$STACK_DIR') — la valeur ne survivra pas à un down/up"
    fi

    if [ "$RELOAD_MODE" = "fpm" ]; then
        # PHP-FPM hérite de l'environnement du conteneur (clear_env = no) : on le surcharge
        # par un pool complémentaire, puis SIGUSR2 au maître (PID 1) pour un reload à chaud.
        printf '[www]\nenv[MELIS_MODULE] = "%s"\n' "$module" > "$FPM_POOL_FILE" || ok=0
        if kill -USR2 1 2>/dev/null; then
            log "php-fpm rechargé (SIGUSR2) avec MELIS_MODULE=$module"
        else
            log "ERREUR : impossible de signaler php-fpm"
            ok=0
        fi
    else
        # Le vhost lit ${MELIS_MODULE} depuis l'environnement du processus Apache, figé
        # au démarrage : on remplace l'expansion par la valeur littérale.
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

        # Filet pour les stacks dont le vhost ne pose pas SetEnv (install/prebuilt) :
        # conf-enabled est inclus au niveau serveur ; quand le vhost définit lui-même la
        # variable c'est lui qui gagne — les deux écritures sont donc complémentaires.
        printf 'SetEnv MELIS_MODULE "%s"\n' "$module" > /etc/apache2/conf-enabled/zz-melis-module.conf 2>/dev/null || true

        if apache2ctl configtest >/dev/null 2>&1; then
            apache2ctl graceful >/dev/null 2>&1 || ok=0
            log "Apache rechargé (graceful) avec MELIS_MODULE=$module"
        else
            log "ERREUR : configtest Apache en échec, aucun rechargement"
            ok=0
        fi
    fi

    if [ "$ok" = "1" ]; then
        ack applied "$module"
    else
        ack failed "$module"
    fi
}

log "surveillance de $REQUEST_FILE"
while true; do
    if [ -f "$REQUEST_FILE" ]; then
        module="$(head -n 1 "$REQUEST_FILE" | tr -d '[:space:]')"
        rm -f "$REQUEST_FILE"
        # flock : Apache sert le healthcheck et le navigateur en parallèle, une
        # seule application à la fois.
        (
            flock -w 30 9 || exit 1
            apply "$module"
        ) 9>"$LOCK_FILE"
    fi
    sleep "$POLL_SECONDS"
done
