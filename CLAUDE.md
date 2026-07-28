# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

`melis-docker-react` — the Docker tooling for **Melis Platform** (a PHP/Laminas
CMS, modules `melisplatform/*`, version line 5.3.x) **with the new React
back-office (`/melis-react`) enabled by default**. Forked from `melis-docker`
(same five paths, same conventions); the React delta is described in
[React back-office](#react-back-office-melis-react--this-repos-delta) below.
It ships Dockerfiles, docker-compose stacks and CI to install/run Melis with one
command. It does **not** contain Melis itself — the application code comes from
the Packagist skeleton `melisplatform/melis-platform-skeleton` (Melis CE), pulled
via Composer.

There is no application source, no test suite, no build step to run here — the
"code" is Dockerfiles, compose files, shell entrypoints and GitHub Actions. Verify
changes by building/running the relevant stack, not by unit tests.

## The five paths (each is self-contained in its own folder)

| Folder | What it does | Audience |
|---|---|---|
| [`prebuilt/`](prebuilt/) | Pulls a **pre-built** image that bakes the skeleton at build time + a MySQL service. No build on the user's machine. | Fastest "just run it" |
| [`install/`](install/) | **Turnkey build**: builds locally, `composer create-project` the skeleton at first run into `./melis` (editable on host) + MySQL. | Devs who want code locally |
| [`fpm/`](fpm/) | Production-style **nginx + PHP-FPM + MySQL**, skeleton baked into the image. | More production-like topology |
| [`app/latest/`](app/latest/) | **Legacy** dev path: mounts an existing Melis project (`../../../`) into a PHP-apache build. React BO supported but opt-in (`WITH_REACT=1`). | Existing projects |
| [`dev/`](dev/) | Per-PHP-version **base images** only (no compose). `dev-{apache,fpm}-{8.1,8.2,8.3,8.4,8.5}`. | Image building blocks |
| [`local-proxy/`](local-proxy/) | Shared **nginx-proxy** (opt-in) so several stacks share `:80` by hostname. | Running many projects locally |

All paths finish the same way: the **native Melis web installer** at
http://localhost:8080 (`/melis/setup`) sets up the DB schema, admin user and the
optional demo site. **We never script the Melis install** — the web wizard is
authoritative; scripting it is fragile and was a deliberate non-goal.

## Architecture conventions

- **Stack baseline:** PHP **8.3** (mod_php for apache variants, php-fpm for fpm),
  Apache 2.4 / nginx 1.27, **MySQL 8.4 LTS**.
- **PHP version is configurable** in the runnable stacks (`install/`, `prebuilt/`,
  `fpm/`): `ARG PHP_VERSION=8.3` → `FROM php:${PHP_VERSION}-{apache,fpm}`, wired into
  compose build args and `.env` (`PHP_VERSION=`). 8.4 is experimental but runs;
  8.5 builds the image but Melis won't install (Laminas deps cap at 8.4) — use 8.3/8.4.
- **Root `Makefile`** wraps the common compose ops: `make up|up-build|down|destroy|
  logs|shell|ps STACK=install|prebuilt|fpm|app/latest`, plus `proxy-up`, `PROXY=1`,
  and `adminer` (DB GUI on :8082). `make help` lists all.
- **Xdebug** is opt-in in `install/` via `ARG WITH_XDEBUG=1` (`.env` `WITH_XDEBUG=1`):
  pecl xdebug + config (mode debug,develop; trigger; IDE port 9003). Off by default.
- **Required PHP extensions:** `pdo_mysql` + `intl` are mandatory, plus
  `mysqli, gd, zip, mbstring, xml, curl, exif, opcache`. `gd` is configured
  `--with-freetype --with-jpeg`; `intl` needs `libicu-dev`.
- **Composer is required in the image** — not just for bootstrap but because the
  Melis web installer adds modules (cms/front/engine) via Composer at install time.
- Each folder keeps its own `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`,
  `.env.example`, `conf/`, `README.md`. Keep them consistent across folders when
  changing shared logic (extensions, MySQL wait loop, collation, perms).

## React back-office (`/melis-react`) — this repo's delta

The React BO is the one developed in the sibling `../ocidev6` project (chantier 3):
a Vite + React 19 + TS + Tailwind v4 SPA that talks to Melis over a JSON API and
shows not-yet-migrated legacy tools in an iframe pool. Everything ships on public
GitHub **`melis-react` branches**:

- **`melis-core@melis-react`** — the SPA source (`ui-react/`) **and the committed
  production build** (`public/ui-react/`, served by MelisAssetManager at
  `/MelisCore/ui-react/`). Because the build is committed, serving `/melis-react`
  needs **no Node.js in the PHP images**.
- **`melis-react-api@melis-react`** — JSON API module, routes under `/melis/react-api/*`.
- **`melis-react-override@melis-react`** — the `/melis-react/*` SPA route (public via
  `excluded_routes`; `SpaController` serves melis-core's `public/ui-react/index.html`)
  + the legacy-tool iframe mechanism (overrides MelisCore's `PluginViewController`).

**How this repo enables it** (`conf/enable-react.sh` + `conf/enable-react.php`,
identical in `install/`/`prebuilt/`/`fpm/`, both idempotent):

1. `composer config repositories.*` for the three GitHub repos, then
   `composer require -W "melisplatform/melis-core:dev-melis-react as 5.3.999"
   melis-react-api:dev-melis-react melis-react-override:dev-melis-react`. The inline
   alias keeps every `^5.3` constraint satisfied AND stops the installer's own
   `composer update --root-reqs` from rolling melis-core back to a stable dist.
   `GITHUB_TOKEN` is passed via `COMPOSER_AUTH` env only (never written to disk).
2. `enable-react.php` patches `config/application.config.php`: appends the two
   modules **after** `getModules()` (so the override wins the config merge) —
   **never** in `config/melis.module.load.php`, which the Modules tool rewrites and
   would drop them. The entry is **gated on `MelisCore` being present in
   `melis.module.load.php`**: pre-install only the installer modules are active and
   loading the React modules would fatal the wizard; the installer rewrites that
   file at the end, so the React BO activates on the first post-install request.

Where it runs: `install/` → entrypoint step 2b on first boot (`WITH_REACT=1`
default, in `.env`); `prebuilt/`+`fpm/` → Dockerfile right after the skeleton bake
(`ARG WITH_REACT=1`; GitHub token via BuildKit secret `github_token`, not a build
arg) + a defensive entrypoint re-run for app volumes seeded from pre-React images;
`app/latest/` → entrypoint step 2, **`WITH_REACT=1` by default** like the others
(changed 2026-07-28 on request; it was `0`). Mind what that means there: the app dir
is the user's own pre-existing project (bind-mounted from `../../../`), so the first
boot rewrites *their* `composer.json`/`composer.lock`/`application.config.php` on the
host — the README and `.env.example` tell them to commit first, and `WITH_REACT=0`
opts out. Nothing is baked there (the image is runtime-only), but its Dockerfile
does run the same **cache pre-warm** as `install/`, for the same reason: without it
the entrypoint's React enablement resolves cold and Apache doesn't start for ~12 min,
during which the published port returns an empty response (observed).

**Two of the three React repos are PRIVATE** (`melis-react-api`,
`melis-react-override`; `melis-core` is public). `GITHUB_TOKEN` therefore needs the
**`repo` scope** whenever `WITH_REACT=1` — it is not merely a rate-limit lift there.
Without it Composer's GitHub API call 404s, it falls back to the git driver, and the
require dies with `fatal: could not read Username for 'https://github.com'`. The
"no scopes needed" note in the `.env.example` files applies only to the
`WITH_REACT=0` case (the four public laminas forks).

**Vite dev server**: a `node:${NODE_VERSION:-22}-alpine` service on
`${VITE_PORT:-5173}` running `npm ci && npm run dev` in
`vendor/melisplatform/melis-core/ui-react` (`node_modules` in its own named volume).
`MELIS_TARGET=http://php` (`http://web` for fpm — its php service is FPM-only) and
`MELIS_PROXY_HOST=localhost` (Melis' domain routing redirect-loops when the proxied
Host header carries a port).
- **`install/` ships it in `docker-compose.yml` itself — always on**, since that's
  the stack for developing the React UI (code bind-mounted from `./melis`). Opt out
  with `docker compose up -d php db`. It has **no** `docker-compose.vite.yml`, so
  the Makefile guards `VITE=1` with a `wildcard` check (no-op there).
- `prebuilt/` and `fpm/` keep it opt-in via `docker-compose.vite.yml` (`-f …` or
  `make up VITE=1`) — their code lives in a named volume, not on the host.

Production `/melis-react` never needs Vite — after editing the source,
`npm run build` regenerates `melis-core/public/ui-react/` (that's what PHP serves).

**Shared Composer home (`COMPOSER_HOME=/composer`) — do not remove.** The web
installer runs Composer *inside an HTTP request*, i.e. as `www-data`, whose HOME
(`/var/www`) is root-owned. Composer then prints "Cannot create cache directory
… Proceeding without cache" and re-fetches **every** repository's metadata on
every run. With this project's **7 `vcs` repositories** (4 laminas forks + 3 React
repos), each of which forces enumeration of every branch/tag through the GitHub
API, the wizard's `downloadModules` step took **11m51s — 706 s of it in "Loading
composer repositories", 4 s actually installing packages** (measured; ~2 s CPU,
the rest network round-trips). Fix, in all three stacks: `ENV COMPOSER_HOME=/composer`
+ `chown www-data` at build, `chown -R` again in the entrypoint after its root-run
Composer steps, and the guard's repair runs reuse `getenv('COMPOSER_HOME')`. The
image build pre-warms that cache, so even a first install reads from disk.
`install/`'s `composer-cache` volume mounts at `/composer/cache` for the same reason.

**`install/` additionally pre-warms that cache at build time** — it bakes no
skeleton, so `/composer/cache` would otherwise ship empty. Its Dockerfile resolves
the same graph in a throwaway `/tmp/warm` with `create-project --no-install` +
`update --dry-run`: **metadata only**, which is precisely the expensive part
(`repo/` is 7.0 MB and identical to prebuilt's; prebuilt's extra 134 MB is `files/`,
package archives worth ~4 s). Costs ~12 min once at build; measured effect on a
later resolve as `www-data`: **735 s → 31.8 s**. Never fatal — a failed pre-warm
only means a slower first install. Relying on the entrypoint alone is not enough:
it skips Composer entirely when it finds an existing project in the mounted
`./melis`, which leaves the cache empty and the wizard slow (observed).
`docker compose up --build` passes `GITHUB_TOKEN` to it via a Compose **build
secret** (`secrets: github_token: environment: GITHUB_TOKEN`) — unauthenticated the
pre-warm hits the 60 req/h limit and gives up. A Composer run with no token fails in
~2 s, which is easy to mistake for a fast success when timing things.

React-specific gotchas (each cost a debugging round — respect them):
- **`composer require` MUST use `--no-scripts` in `enable-react.sh`.** The
  skeleton's `post-update-cmd` hook (`MelisDbDeploy\DbDeployOnComposerUpdate`)
  fatals pre-install ("Call to a member function query() on null" — no DB yet) and
  fails the whole require. Nothing is lost: the wizard's own Composer runs and its
  dbdeploy pass publish + apply all schema deltas during the install.
  (`create-project` never fires `post-update-cmd`, which is why vanilla boots fine.)
- **The vite service must EXIT (not loop) while waiting for `ui-react/`** and be
  restarted by its `restart:` policy: the React enablement REPLACES
  `vendor/melisplatform/melis-core` after the container starts, orphaning a cwd or
  `node_modules` volume mounted on the old directory — an in-place wait loop then
  never sees `package.json` and hangs forever.
- **fpm nginx**: the static-asset `location` must fall back to `/index.php`, not
  `=404` — module assets (legacy `/MelisXxx/...` AND `/MelisCore/ui-react/*`) live
  in `vendor/`, not under `public/`, and are streamed by MelisAssetManager via PHP.
- The React modules must **never** end up in `config/melis.module.load.php` (the
  Modules tool would silently drop them on its next save).
- `GITHUB_TOKEN` matters even more here: 7 GitHub `vcs` repos total (4 laminas
  forks + 3 React repos) vs 60 unauthenticated API requests/hour.
- **Rancher Desktop / WSL: pre-create `install/melis` before the first `up`.**
  If the bind-mount source doesn't exist, Rancher's mount helper stages a SEPARATE
  empty dir per container — php and vite silently don't share the app dir and the
  skeleton vanishes on recreate. `make env` (hence `make up`) now creates it.
- Vite **dev mode** (not the committed build) logs a scan error for
  `@melis-ai-engine` — melis-core's ui-react source composes the AI assistant from
  the optional `melis-ai-engine` module, which this skeleton doesn't install. The
  dev server still runs; only the assistant is unavailable in dev. `/melis-react`
  (committed build) is unaffected.

## Hard-won gotchas — respect these (they cost real debugging)

1. **`MYSQL_HOST` / `MYSQL_HOSTNAME` must NOT contain `:port`.** Use `melis-db`,
   never `melis-db:3306`. A `host:port` value makes Melis' flyway/JDBC build a
   double-port URL and breaks. (Was the legacy `app/latest` bug.)
2. **Do DB readiness checks via PHP/mysqli, not the `mysql` CLI.** The MariaDB
   client (`default-mysql-client`) rejects MySQL 8.x's self-signed TLS cert.
   Entrypoints wait on MySQL with PHP. When passing creds to `php -r`, pass them as
   **environment** (prefix `DB_HOST=… php -r …`), not as `$argv` — the original
   entrypoints passed them as args, `getenv()` returned empty, the loop spun
   forever and **Apache never started (HTTP 000)**. Also set
   `mysqli_report(MYSQLI_REPORT_OFF)` (PHP 8.1+ throws instead of returning false)
   and bound the retry (~3 min) so Apache always comes up.
3. **DB collation must be `utf8mb4_general_ci`.** The Melis installer rejects
   `utf8mb4_unicode_ci` at "Test database connection". Set it in both the compose
   `--collation-server` and the entrypoint `CREATE DATABASE`.
4. **MySQL 8.4 removed `--default-authentication-plugin`** — don't pass it; rely on
   the server default (`caching_sha2_password`), which PHP 8.x connects to natively.
5. **`prebuilt/`: never bind-mount a host dir over `/var/www/melis`** — it would
   mask the baked code. Use the **named volume** `melis-app` (seeded from the image
   on first run). `fpm/clear_env=no` so PHP-FPM sees `getenv(MYSQL_*)`.
6. **PHP 7.x is incompatible** with current Melis (`require php: ^8.1|^8.3`). **PHP 8.4**
   runs Melis (every dependency allows `~8.4`) and is the experimental ceiling. **PHP 8.5
   is NOT a hard incompatibility** — Melis was driven through a full install to the
   working back-office on 8.5 (verified end-to-end 2026-06-13), but only after several
   fixes; out of the box it does not complete. `latest` stays on 8.3; `dev-*-8.5` images
   build (pure PHP base, forward-looking). The complete 8.5 recipe:
   - **(infra, shipped) git over HTTPS:** on 8.5 Composer must resolve the public
     melisplatform Laminas forks from their **VCS source** (locked dist versions don't
     satisfy 8.5), which are declared as `git@github.com:` (SSH) URLs — the image has no
     ssh client/keys, so module download fails ("cannot run ssh"). Fix shipped in
     `install/prebuilt/fpm` Dockerfiles: `git config --system url.https://github.com/.insteadOf git@github.com:`.
     This was THE hard blocker; once fixed, all modules (cms/front/engine + demo) install.
   - **(infra, shipped) don't display errors:** php.ini sets `display_errors=Off` +
     `error_reporting` excluding `E_DEPRECATED` — 8.5 emits many deprecations from
     Melis/Laminas/phing; if displayed they pollute installer AJAX (the DB-test JSON) and
     clutter the back-office. (Melis also re-sets these at runtime from its config, incl.
     the generated `module/MelisModuleConfig/config/app.interface.php` `local` block.)
   - **(upstream Melis) error display is forced on:** Melis re-applies error config at
     runtime (`melis-core` `Module.php` `ini_set`), and the value that wins the
     `meliscore.datas.default.errors` config merge is **`melis-installer`'s**
     `config/app.interface.php` (`display_errors=1`, `error_reporting=E_ALL & ~E_USER_DEPRECATED`
     — does not exclude core `E_DEPRECATED`). So it overrides our php.ini `display_errors=Off`
     for back-office pages → 8.5 deprecations are displayed. Upstream fix: set
     `display_errors=0` / exclude `E_DEPRECATED` in melis-installer (and melis-core) config.
   - **(upstream Melis, NOT done here) code is not 8.5-deprecation-clean:**
     `melis-installer` uses deprecated `PDO::MYSQL_ATTR_INIT_COMMAND` (→ `Pdo\Mysql::ATTR_INIT_COMMAND`);
     `melis-core` `MelisCoreToolService` uses `ReflectionProperty::setAccessible()`;
     `laminas-cache` uses deprecated `SplObjectStorage::contains/attach/detach`;
     `phing/phing` (dbdeploy) emits dozens of deprecations. All are E_DEPRECATED (noise,
     non-fatal) — Melis runs despite them. Even latest (core 5.3.36, installer 5.3.4) are
     not clean. Composer constraints also still cap at `~8.4` (bypassed by the wizard,
     which already passes `--ignore-platform-reqs`).
   - **Trap:** the wizard runs `composer update` mid-install, which **upgrades the Melis
     packages and overwrites any vendor patch** — so the deprecation fixes must land
     upstream, not as post-hoc vendor edits.
   See `melisplatform/melis-core#24`.
7. **PHP 8.5 build gotcha: don't `docker-php-ext-install opcache`** — on 8.5 Zend
   OPcache is built into core (no shared module), so it fails with
   `cp: cannot stat 'modules/*'`. All Dockerfiles gate it on `version_compare(...,
   "8.5", "<")` so opcache is installed only on < 8.5 (it's already loaded on 8.5).

8. **The web installer silently ignores its own Composer failures — this bricks the
   platform.** `addModulesToComposerAction` / `downloadModulesAction`
   (`melis-installer`) return a plain `ViewModel` whatever Composer's exit code is,
   so the response is **HTTP 200** even when nothing was installed; the wizard JS
   chains on `.done()` and carries on. `activateModulesAction` then force-pushes
   `MelisEngine`/`MelisFront` into `config/melis.module.load.php` **without checking
   they exist on disk**. The next request dies at bootstrap with
   `Module (MelisEngine) could not be initialized` → **every** URL 500s, `/melis/setup`
   and the back-office login included, so the install can't be recovered from the UI.
   `reprocessDbDeploy` is usually the first request to hit it — it is a symptom, not
   the cause. Reproduced end-to-end; the Composer error text is in the discarded
   response body. Two known triggers: the installer runs `composer update --root-reqs`
   (a **partial** update) which fails outright when a new module needs a version of an
   already-locked transitive dep (`melis-front` pins `laminas/laminas-serializer` to
   exactly `2.17`), and any packagist/GitHub hiccup during requirement resolution.
   Mitigated by `conf/melis-installer-guard.php` (below); the real fixes are upstream
   (check the exit code; don't activate a module `getModulePath()` can't find).
9. **Set `GITHUB_TOKEN` — this is the trigger behind gotcha 8.** The skeleton declares
   four `vcs` repositories (the melisplatform `laminas-mail/mime/crypt/file` forks) and
   the lock genuinely resolves those four packages from them, so **every** Composer
   resolution the installer runs queries the GitHub API for all four. Unauthenticated
   that is **60 requests/hour per public IP**; once spent, Composer can't prompt under
   `--no-interaction` and throws `Could not authenticate against github.com`
   (`AuthHelper.php` line 145) — *before* `updateFile()`, so `composer.json` is never
   written, the following `composer update` only bumps the 6 skeleton packages, and
   gotcha 8 plays out. Observed live. A classic token with **no scopes** lifts the limit
   to 5000/h; `GITHUB_TOKEN` in `.env` → the guard writes `auth.json`.
   **`use-github-api false` is NOT a token-free workaround** — the git driver then fails
   with `No valid composer.json was found in any branch or tag of …/laminas-crypt`.
   Tested; do not re-add it.
10. **`--ignore-platform-reqs` defeats `config.platform.php`** — the flag ignores the
   pin too, so the solver is free to pick packages needing a newer PHP: `symfony/console`
   v8 (PHP >= 8.4.1) lands on a PHP 8.3 image and its 8.4-only syntax
   (`new Foo()->bar()`) is a **ParseError**, a hard fatal on every request. The pin only
   helps runs that omit the flag, which is why the guard's repair resolves **without**
   it first and only falls back to it (the PHP 8.5 case) if that fails.
11. **`display_errors = Off` in php.ini is not enough.** Melis re-applies its own error
   config at runtime (`melis-core` `Module.php` `ini_set`, with `melis-installer`'s
   `app.interface.php` winning the merge at `display_errors=1`), so PHP notices get
   rendered *into* responses — and several wizard steps are `$.get(..., 'json')`, where
   a leading `<br /><b>Warning</b>…` breaks the parse and kills the step. `php_admin_flag
   display_errors Off` (vhost) / `php_admin_flag[display_errors] = off` (fpm pool) is
   PHP_INI_SYSTEM-locked and **cannot** be overridden by `ini_set` — verified. The guard
   additionally installs a logging error handler on installer URLs, which covers the
   published pre-built image (whose Apache config can't be changed without a rebuild).

## The installer guard (`*/conf/melis-installer-guard.php`)

Loaded via `auto_prepend_file` in each stack's `conf/php.ini` (CLI is exempt). It:
pins `config.platform.php` once per boot; keeps PHP diagnostics out of installer
replies; tees every `/melis/MelisInstaller/Installer/*` response to
`data/logs/melis-installer.log` (the Composer output the wizard throws away); and,
when `melis.module.load.php` lists a module that isn't on disk, retries the install
with `-W` (`--with-all-dependencies`, which resolves the conflicts `--root-reqs`
cannot) and, failing that, drops the module from the list so the platform still boots.
It never installs anything the user didn't pick — it only reacts to what the installer
already wrote into the module list. Hot path is two `stat()` calls.

`prebuilt/` runs the **published** image, so its baked `entrypoint.sh` / vhost can't be
changed without a rebuild: its `docker-compose.yml` mounts `./conf` at `/melis-conf`
(plus `PHP_INI_SCAN_DIR`) so php.ini and the guard apply without one. Mount the
**directory** — a single-file bind mount is silently detached when an editor replaces
the file's inode, and then blocks the container from starting at all.

## Shared local proxy (opt-in, `local-proxy/` + `*/docker-compose.proxy.yml`)

`nginxproxy/nginx-proxy` on a shared external `webproxy` network owns `:80` and
routes by container `VIRTUAL_HOST`. Each runnable stack has a
`docker-compose.proxy.yml` override that: declares `VIRTUAL_HOST`/`VIRTUAL_PORT`,
joins `webproxy`, and **drops the published host port via the Compose `!reset []`
tag**. Activated by adding `-f docker-compose.proxy.yml`; without it, stacks behave
exactly as before (published on `HOST_PORT`). The proxy targets the `php` service
(install/prebuilt/app-latest) or the nginx `web` service (fpm — php is FPM-only).
Default hosts: `melis-{prebuilt,install,fpm,app}.local`. To run several at once,
set distinct `MELIS_CONTAINER_NAME` + `VIRTUAL_HOST` per `.env`. Mirrors the setup
in the sibling `../melis-platform-website` project. Validate edits with
`docker compose -f docker-compose.yml -f docker-compose.proxy.yml config`.

## Security / hygiene

- **Never commit a real `.env` or any secret** — `.env.example` only. `.gitignore`
  ignores `**/.env`, `install/melis/`, `.claude/settings.local.json`, `.DS_Store`.
- DB ports are bound to `127.0.0.1` (not exposed on the LAN).
- Web services have a `HEALTHCHECK`; Apache gets an explicit `ServerName localhost`
  to silence `AH00558`.

## CI (GitHub Actions, all multi-arch `linux/amd64,linux/arm64`)

- **`docker-image.yml`** — builds `dev/` base images, matrix `{apache,fpm} × {8.1..8.5}`,
  pushes `melisplatform/melis-docker:dev-{variant}-{php}` on `master` only.
- **`prebuilt-image.yml`** — builds the baked images: `prebuilt/` → `latest`/`php8.3`,
  `fpm/` → `fpm-latest`/`fpm-php8.3`; pushes on `master` pushes and `v*` tags.
- **`dockerhub-description.yml`** — syncs `DOCKERHUB.md` to the Docker Hub overview.
- PRs **build-only** (no push, no secrets needed). Pushing requires repo secrets
  `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`. Pushing a `.github/workflows/*` change
  needs the `workflow` scope on the `gh` token.

## How to test a change locally

```bash
# Pre-built (validated E2E): build the baked image, then run image + db
cd prebuilt && docker build -t melisplatform/melis-docker:latest . \
  && cp -n .env.example .env && docker compose up -d
# Turnkey: builds + composer create-project on first run (slow first time)
cd install && cp -n .env.example .env && docker compose up --build
# nginx + php-fpm
cd fpm && cp -n .env.example .env && docker compose up --build   # default 8080
```
Then open http://localhost:8080 — expect `/` → 302 → `/melis/setup` → 200, and
drive the wizard (DB host = `melis-db` **without port**, db/user/pass = `melis`).
Baked images are ~1.5 GB each; `docker rmi` test images when done.

## Notes

- [`HANDOFF.md`](HANDOFF.md) is the detailed session log / decision record — read it
  for the full backstory, upstream PRs (melis-installer #19/#20/#21) and roadmap.
- The repo lives next to a private `../demo` (the Melis demo on OCI/Kubernetes);
  the gotchas above are shared lessons from that deployment.
- Cloud sync (iCloud/Dropbox) occasionally drops `* 2.ext` / `* 3.ext` duplicate
  files in the tree. They are not part of the build — delete them. Find with:
  `find . -not -path './.git/*' \( -name '* [0-9].*' -o -name '* [0-9]' \)`.
