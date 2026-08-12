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
| [`app/latest/`](app/latest/) | **Legacy** dev path: mounts an existing Melis project (`../../../`) into a PHP-apache build. React BO on by default (`WITH_REACT=1`), like the other stacks. | Existing projects |
| [`dev/`](dev/) | Per-PHP-version **base images** only (no compose). `dev-{apache,fpm}-{8.1,8.2,8.3,8.4,8.5}`. | Image building blocks |
| [`local-proxy/`](local-proxy/) | Shared **nginx-proxy** (opt-in) so several stacks share `:80` by hostname. | Running many projects locally |

**`MELIS_MODULE` is set by the wizard, not only by hand** (added 2026-08-11). The site
module name typed at the wizard's modules step is applied on the **Finish** step: PHP drops
a request file, and a root watcher started by each `entrypoint.sh`
(`conf/melis-module-applier.sh`) rewrites the stack `.env` **and** the live server config
(Apache `SetEnv` + a `conf-enabled` drop-in, or an fpm pool `env[]`), then reloads in place —
`apache2ctl graceful` / `SIGUSR2`, never a container restart (gotcha 12 makes restarts
destructive here). This does not script the install — the wizard stays authoritative; it only
lets the wizard write a value that used to require hand-editing `.env` + a `down && up`.
Nothing happens until a request file appears, and an invalid name is rejected twice (PHP, then
the shell applier) since the endpoint is pre-auth. **The watcher stops once the platform is
installed** (added 2026-08-12): it exits as soon as `config/melis.install` reads truthy — same
test as melis-installer's `Module.php`, so an empty or `0` marker doesn't count — and never
starts at all on an already-installed platform. Without that it stayed alive for the
container's lifetime, i.e. a root process watching a www-data-writable path long after
`finalizeSetup` removed the only route that writes it. The check sits at the END of the loop
body: the Finish step requests the module adoption JUST BEFORE calling `finalizeSetup`, so a
pending request must still be served on the iteration that sees the marker.

All paths finish the same way: the **native Melis web installer** at
http://localhost:8080 (`/melis/setup`) sets up the DB schema, admin user and the
optional demo site. **We never script the Melis install** — the web wizard is
authoritative; scripting it is fragile and was a deliberate non-goal.
Since melis-installer v6.0.2 the same wizard also exists as a **React version at
`/melis-react/setup`** (same `SetupReactApi` endpoints); see the gate note in
[React back-office](#react-back-office-melis-react--this-repos-delta) step 2 —
it only works if the React modules are loaded pre-install.

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
shows not-yet-migrated legacy tools in an iframe pool. Everything ships on Packagist
as **stable 6.x releases** (since 2026-07-30 — no dev branches involved):

- **`melis-core` ^6.0** — the SPA source (`ui-react/`) **and the committed
  production build** (`public/ui-react/`, served by MelisAssetManager at
  `/MelisCore/ui-react/`). Because the build is committed, serving `/melis-react`
  needs **no Node.js in the PHP images**. Pulled in by the skeleton, not by
  `enable-react.sh`. **Since v6.0.2 (2026-08-10) melis-core `require`s the two
  modules below itself**, so nothing else has to name them.
- **`melis-react-api` ^6.0** — JSON API module, routes under `/melis/react-api/*`.
- **`melis-react-override` ^6.0** — the `/melis-react/*` SPA route (public via
  `excluded_routes`; `SpaController` serves melis-core's `public/ui-react/index.html`)
  + the legacy-tool iframe mechanism (overrides MelisCore's `PluginViewController`).

**How this repo enables it** (`conf/enable-react.sh` + `conf/enable-react.php`,
identical in `install/`/`prebuilt/`/`fpm/`, both idempotent):

1. **A version floor on melis-core, nothing else** (changed 2026-08-10): if
   `vendor/melisplatform/melis-react-{api,override}` are missing it runs
   `composer require melisplatform/melis-core:^6.0.2` — v6.0.2 requires both React
   modules, so they arrive as transitive deps. If they are already on disk the step
   is skipped entirely. **Never name the two modules here again**: melis-core owns
   that constraint now, and a second copy of it only drifts.
   Why the floor exists at all: `create-project` installs from the skeleton's
   **committed `composer.lock`**, and skeleton v6.0.0's lock pinned melis-core
   **v6.0.1** (pre-React-deps), so a fresh install came up without them.
   **Skeleton v6.0.1 (2026-08-10) regenerated that lock** — it now pins melis-core
   v6.0.2 + `melis-react-api`/`melis-react-override` v6.0.1 — so with
   `SKELETON_VERSION=^6.0` the modules arrive from `create-project` and the Composer
   run above self-skips; the config patch in step 2 is all that actually runs. The
   floor stays for `app/latest` (the user's own lock) and for any older pin.
   **No `repositories` entries, no inline alias, no `-W`** — everything is on
   Packagist at stable 6.x tags, so a plain require resolves and Composer never
   enumerates refs through the GitHub API. Do not add `vcs` entries back.
   No GitHub authentication of any kind — the `COMPOSER_AUTH`/`GITHUB_TOKEN`
   plumbing was removed 2026-07-30 (see the token section below).
   (Until 2026-07-30 this pulled melis-core's `dev-melis-react` branch aliased as
   `5.3.999` with `-W`, because the React build lived only on that branch and the
   5.x modules capped melis-core below 6.0. The 6.x line removed both needs.)
2. `enable-react.php` patches `config/application.config.php`: appends the two
   modules **after** `getModules()` (so the override wins the config merge) —
   **never** in `config/melis.module.load.php`, which the Modules tool rewrites and
   would drop them. The entry is **gated on `melis.module.load.php` listing
   `MelisCore` (installed) OR `MelisInstaller` (pre-install)** — widened from
   MelisCore-only on **2026-08-11**. Both states need the modules: melis-installer
   **v6.0.2 ships the React install wizard** at `/melis-react/setup`, whose route
   (`meliscore-melis-react-spa`, `MelisReactOverride`'s `SpaController`) it
   whitelists in its pre-install redirect guard (`melis-installer/src/Module.php`
   `$excludedRoutes`) — so with the old gate `/melis-react/*` returned **404 inside
   the legacy installer layout** until the legacy wizard had finished. The old
   comment claimed loading the modules pre-install would fatal the wizard; verified
   on 6.0.2/6.0.3 that it does **not** — `/melis/setup` and `/melis-react/setup`
   both return 200 with only the installer modules active. The gate stays (rather
   than becoming unconditional) so a module list that is neither state doesn't load
   them blindly. `enable-react.php` also **migrates an already-patched config**
   in place from the old gate to the new one, so existing projects heal on the next
   boot (still idempotent, still exits 0 when nothing to do).

Where it runs: `install/` → entrypoint step 2b on first boot (`WITH_REACT=1`
default, in `.env`); `prebuilt/`+`fpm/` → Dockerfile right after the skeleton bake
(`ARG WITH_REACT=1`) + a defensive entrypoint re-run for app volumes seeded from
pre-React images;
`app/latest/` → entrypoint step 2, **`WITH_REACT=1` by default** like the others
(changed 2026-07-28 on request; it was `0`). Mind what that means there: the app dir
is the user's own pre-existing project (bind-mounted from `../../../`), so the first
boot rewrites *their* `composer.json`/`composer.lock`/`application.config.php` on the
host — the README and `.env.example` tell them to commit first, and `WITH_REACT=0`
opts out. Nothing is baked there (the image is runtime-only), but its Dockerfile
does run the same **cache pre-warm** as `install/`, for the same reason: without it
the entrypoint's React enablement resolves cold and Apache doesn't start for ~12 min,
during which the published port returns an empty response (observed).

## No GitHub token — everything resolves from Packagist (done 2026-07-30)

`GITHUB_TOKEN` and all its plumbing were **removed** on 2026-07-30. Do not
reintroduce it, and do not add a `vcs` repository to any stack — that is what would
bring the whole problem back (see gotcha 9). What changed, all upstream of this repo:

- **The three React packages are public and on Packagist** at stable 6.x
  (`melis-core` v6.0.1, `melis-react-api` / `melis-react-override` v6.0.1). So the old
  `fatal: could not read Username for 'https://github.com'` failure is gone, and
  `enable-react.sh` needs no `repositories` entries.
- **The four laminas forks are on Packagist as `melisplatform/laminas-*`**, each
  `replace`-ing its upstream package (`replace: {"laminas/laminas-X": "self.version"}`)
  so every `laminas/laminas-X` constraint in the tree is satisfied by the fork and
  upstream is *excluded* rather than installed alongside. Versions: mail `2.26.1`,
  mime `2.13.1`, crypt `3.13.1`, file `2.14.1`.
- **The skeleton dropped its `repositories` block** and requires the forks by name.
  Released as **v6.0.0**, which this repo targets via `SKELETON_VERSION=^6.0` — a build
  ARG + compose env in all four stacks. **`SKELETON_VERSION=` (empty) = latest stable**,
  which is now also the 6.x line. Pin to 5.3.x only if you need the old line: that one
  still declares the four `vcs` repos and is slow / rate-limit-prone without a token.
  The 6.x skeleton also pins `config.platform.php = 8.3.0` — needed, or its lock picks
  `symfony/console` v8 (php >=8.4.1) and gotcha 10 lands in the lock file.

Verified end-to-end with **no token and no credentials** (2026-07-30), on stable 6.x:
`create-project melis-platform-skeleton:^6.0`, then `enable-react.sh`'s require, then
the wizard's own `composer update --root-reqs` adding cms/front/engine — all green.
melis-core v6.0.1 with its committed React build AND the `ui-react/` source (so vite
works too), exactly one psr-4 path per namespace for all four laminas forks with no
`vendor/laminas/laminas-*` duplicate.

**The crypt trap, for the record** — it failed SILENTLY, which is why it took a real
install to see. The skeleton first required `melisplatform/laminas-crypt: ^4.0`.
melis-core requires `laminas/laminas-crypt: ^3.11`, which `4.1.1`'s `replace` (=4.1.1)
does not satisfy, so the solver backtracked to **`4.1.0` — which carries no `replace`**
— and then installed upstream `laminas/laminas-crypt 3.12.0` alongside it:

    'Laminas\\Crypt\\' => array(
        $vendorDir . '/melisplatform/laminas-crypt/src',   // fork 4.1.0
        $vendorDir . '/laminas/laminas-crypt/src',         // upstream 3.12.0
    ),

Two copies of one namespace, no error. `^3.13` did not help either while `3.13.0` was
the newest 3.x tag (no `replace`). Fixed by tagging **`3.13.1`** off the `3.13.x`
branch with the rename + `replace`, and setting the skeleton to `^3.13`.
Check after any change here — exactly one path is correct:
`grep -A2 "Laminas..Crypt" vendor/composer/autoload_psr4.php`.

**Why crypt stays on the 3.x line:** crypt 4.x removes exactly one class,
`Laminas\Crypt\Symmetric\Mcrypt`, and melis-core instantiates it in LIVE code at
`MelisAuthController.php:706` — the legacy-password migration path, reached on login
when the stored password is not a 60-char bcrypt hash AND
`/meliscore/datas/default/accounts/use_mcrypt` is on. Fresh installs never hit it; a
carried-over database does. So relaxing melis-core to `^3.11 || ^4.0` is not a
constraint tweak, it needs that login path ported off Mcrypt (`ext-mcrypt` was dropped
in PHP 7.2). Note the duplicate above did NOT paper over it either:
`SymmetricInterface` was re-typed in 4.x (`encrypt(string): string`,
`setKey(string): static`, …), so `Mcrypt` from 3.12.0 against the 4.1.0 interface
fatals on declaration incompatibility.

Still-open item upstream: `melisplatform/laminas-crypt` `4.1.0` is published **without**
`replace`, so it remains selectable by a `^4.0` constraint and would silently duplicate
again. Either delete that tag or retag it with `replace`. `4.1.1` is correctly formed
and worth keeping as the forward path.

The `url.https://github.com/.insteadOf git@github.com:` git config (gotcha 6) is kept
deliberately: it costs nothing and still covers the `SKELETON_VERSION=` path, whose
skeleton declares `git@github.com:` fork URLs.

**Vite dev server**: a `node:${NODE_VERSION:-22}-alpine` service on
`${VITE_PORT:-5173}` running `npm ci && npm run dev` in
`vendor/melisplatform/melis-core/ui-react`. `node_modules` deliberately lives in the
app tree itself (bind mount / `melis_app`) — **never in its own named volume**, see
the vite gotcha below.
`MELIS_TARGET=http://php` (`http://web` for fpm — its php service is FPM-only) and
`MELIS_PROXY_HOST=localhost` (Melis' domain routing redirect-loops when the proxied
Host header carries a port).
- **`install/` and `app/latest/` ship it in `docker-compose.yml` itself — always
  on**: both bind-mount their code from the host (`./melis` / `../../../`), so they
  are the stacks where you actually develop the React UI. Opt out with
  `docker compose up -d php db`. Neither has a `docker-compose.vite.yml`, so the
  Makefile guards `VITE=1` with a `wildcard` check (a no-op for them).
  `app/latest`'s vite was merged in from its override on 2026-07-30; note its
  `node_modules` lands inside the **user's own** project tree (under `vendor/`,
  git-ignored). Its supervisor loop carries an extra guard: a missing
  `composer.json` in the app dir means a detached bind mount (gotcha 12), not a
  first boot — that stack never creates a project — so it warns and waits instead
  of `npm ci`-ing into a phantom dir. `make doctor STACK=app/latest` checks php
  **and** vite, since the two are staged independently.
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
It needs no credentials: with the fork-free skeleton everything resolves from
Packagist. (Historically it took `GITHUB_TOKEN` via a Compose build secret, because
unauthenticated it hit the 60 req/h GitHub API limit and gave up in ~2 s — easy to
mistake for a fast success when timing things.)

**`laminas/laminas-serializer` needs no pin any more (removed 2026-07-30).**
`enable-react.sh` used to add `laminas/laminas-serializer:2.17`, because melis-core
allows `^2.17 || ^3.0` and a React-only resolve locked 2.18.0, while melis-front
required *exactly* `2.17`; the wizard's `--root-reqs` partial update could not
downgrade it, so resolution failed and gotcha 8 played out (modules activated but
absent). **melis-front v6.0.1 relaxed that to `^2.17`**, and 2.18.0 is a metadata-only
release — its `src/` is byte-identical to 2.17.0 (verified by diffing the tags), so
nothing functional changes. Verified end-to-end on 6.x with no pin: the wizard's
partial update now exits 0 with serializer 2.18.0 and melis-front v6.0.1 installed.
If a future module reintroduces an exact pin, the symptom is
`the package is fixed to X (lock file version) by a partial update` — check with
`composer why laminas/laminas-serializer`.

React-specific gotchas (each cost a debugging round — respect them):
- **`composer require` MUST use `--no-scripts` in `enable-react.sh`.** The
  skeleton's `post-update-cmd` hook (`MelisDbDeploy\DbDeployOnComposerUpdate`)
  fatals pre-install ("Call to a member function query() on null" — no DB yet) and
  fails the whole require. Nothing is lost: the wizard's own Composer runs and its
  dbdeploy pass publish + apply all schema deltas during the install.
  (`create-project` never fires `post-update-cmd`, which is why vanilla boots fine.)
- **Never mount a named volume at `ui-react/node_modules`, and never make the vite
  service exit/restart to recover.** (Reversed 2026-07-29 — the old rule was the
  opposite and was wrong; it cost this bug twice.) Composer REPLACES
  `vendor/melisplatform/melis-core` every time it touches the package: first boot
  (`enable-react.sh`), the **web installer's own `composer update` — long after php
  is healthy, which is why `depends_on: service_healthy` cannot prevent this** — and
  any later require/update. Two consequences:
  - A volume mounted *inside* that directory pins the deleted inode in the vite
    container's mount namespace. The path then resolves to the new directory with
    **no `node_modules` at all**, and vite serves `Cannot find module
    .../vite/dist/node/chunks/dist.js` forever. Only re-creating the container fixes
    it. So `node_modules` lives in the app tree (bind mount / `melis_app`) — nothing
    is mounted there, so a Composer wipe merely deletes it.
  - Recovery is an **in-place supervisor loop** in the service `command`: a watchdog
    polls the ABSOLUTE `node_modules/vite/package.json` (the cwd is a deleted inode
    by then), kills vite, re-runs `cd $A` onto the new directory, `npm ci`s and
    restarts it — container untouched. Do **not** `exit` and lean on `restart:`: on
    Rancher Desktop/WSL each restart re-stages the bind mount and a restart-looping
    container gets a **degenerate staging dir** (`/var/www/melis` holding only an
    empty path skeleton while the host tree is intact) → infinite loop, observed at
    `RestartCount 35`. `restart: unless-stopped` stays as a crash net only.
  - `npm ci` is skipped when `node_modules/.package-lock.json` is present, newer than
    `package-lock.json`, **and** `node_modules/vite/package.json` exists — that last
    clause is what makes a partial wipe heal instead of being declared fresh.
- **fpm nginx**: the static-asset `location` must fall back to `/index.php`, not
  `=404` — module assets (legacy `/MelisXxx/...` AND `/MelisCore/ui-react/*`) live
  in `vendor/`, not under `public/`, and are streamed by MelisAssetManager via PHP.
- The React modules must **never** end up in `config/melis.module.load.php` (the
  Modules tool would silently drop them on its next save).
- Enabling React costs **no** GitHub API calls: all three packages come from
  Packagist. Do not reintroduce `vcs` repositories for them.
- **Rancher Desktop / WSL: pre-create `install/melis` before the first `up`.**
  If the bind-mount source doesn't exist, Rancher's mount helper stages a SEPARATE
  empty dir per container — php and vite silently don't share the app dir and the
  skeleton vanishes on recreate. `make env` (hence `make up`) now creates it, plus a
  `.melis-mount` sentinel inside it. A missing source dir is only ONE way to get a
  phantom mount: see **gotcha 12** for the restart case, which is far more common and
  bites a stack that has been working for hours.
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
   already-locked transitive dep (melis-front USED to pin `laminas/laminas-serializer`
   to exactly `2.17` — relaxed to `^2.17` in v6.0.1), and any packagist hiccup during
   requirement resolution.
   Mitigated by `conf/melis-installer-guard.php` (below); the real fixes are upstream
   (check the exit code; don't activate a module `getModulePath()` can't find).
9. **No `vcs` repositories — this is what defused gotcha 8's main trigger.** RESOLVED
   2026-07-30; kept because reintroducing a `vcs` repo brings the whole failure back.
   The skeleton used to declare four `vcs` repositories (the melisplatform
   `laminas-mail/mime/crypt/file` forks) and the lock really did resolve those four
   packages from them, so **every** Composer resolution the installer ran enumerated
   their refs through the GitHub API. Unauthenticated that is **60 requests/hour per
   public IP**; once spent, Composer can't prompt under `--no-interaction` and throws
   `Could not authenticate against github.com` (`AuthHelper.php` line 145) — *before*
   `updateFile()`, so `composer.json` is never written, the following `composer update`
   only bumps the 6 skeleton packages, and gotcha 8 plays out. Observed live.
   Now: the forks are on Packagist as `melisplatform/laminas-*` (each `replace`-ing its
   upstream package), the skeleton requires them by name, and **no stack declares a
   `vcs` repository**. Zero GitHub API calls, so `GITHUB_TOKEN` was removed entirely.
   Caveat: `SKELETON_VERSION=` (empty → released skeleton) still points at a skeleton
   WITH those repositories, so that path is slow and rate-limit-prone until the release
   lands. Same for `app/latest` if the user's own project still declares them.
   **`use-github-api false` was never a token-free workaround** — the git driver fails
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
12. **Rancher Desktop / WSL: a host bind mount does NOT survive a restart, and the
   detachment is silent.** The `docker` CLI talks to a `wsl-helper docker-proxy` running
   in *your* WSL distro; for every bind it creates
   `/mnt/wsl/rancher-desktop/run/docker-mounts/<uuid>` and bind-mounts the host path
   into it, which propagates to the `rancher-desktop` distro where dockerd runs (that
   tree is a **shared** tmpfs). Those binds are staged at container-**create** time and
   are gone after `wsl --shutdown`, a Rancher Desktop restart, or a host reboot. A
   container that **dockerd** brings back on its own — a `restart:` policy, `docker
   start`, `docker compose restart` — never goes through the proxy, so it comes back
   attached to an **empty** staging dir while reporting `Up (healthy)`. Each container
   is staged separately, so php and vite can disagree with each other *and* with the
   host. Symptoms seen: every URL 302ing to `/melis/setup` and `/melis-react` 404ing on
   an install that had completed hours earlier — because the served tree still had
   `MelisInstaller` in `melis.module.load.php`, so the React gate in
   `application.config.php` was false. `install/entrypoint.sh` had meanwhile run
   `composer create-project` into the phantom dir, creating a whole second Melis tree.
   Note `st_dev:st_ino` of a detached staging dir **matches the host's** — inode
   comparison is useless as a check; write a marker file and look for it on the host
   (that is what `make doctor` does).
   Mitigations, all shipped:
   - `restart: "no"` on every service that host-binds the app dir (`install/` php+vite,
     `app/latest/` php) so the stack stays visibly down instead of coming back blind.
     `db` keeps its policy — named volumes are immune.
   - `entrypoint.sh` step 0 refuses to bootstrap into a phantom dir. It needs two
     signals because a phantom dir and a genuine first run are indistinguishable from
     inside the container: `.melis-mount` / `composer.json` (both ride the bind, so
     invisible from a phantom) prove the mount, and `.melis-bootstrapped` in the
     `melis-state` **named** volume proves a previous successful boot. Neither of the
     first two + the third = broken mount, hard exit. Escape hatch `MELIS_MOUNT_CHECK=0`.
   - `app/latest/` just requires `composer.json`: that stack never creates a project,
     so its absence is proof enough.
   - `make doctor STACK=install|app/latest` checks it on demand.
   Recovery is always `docker compose down && docker compose up -d` — a restart cannot
   re-stage the mount, only a create can.
13. **The wizard's "Apache" step blocks on nginx+FPM unless you declare the modules.**
   Both wizards (`InstallerController::apacheSetupChecker()`, and the React one via
   `SetupWizardService::checkApache()`) require `mod_headers`/`mod_alias`/`mod_deflate`:
   with `apache_get_modules()` they read Apache's real module list, and **without it**
   — every non-mod_php SAPI, i.e. `fpm/` — they fall back to `getenv('mod_xxx') == "On"`.
   That fallback is the installer's own escape hatch for non-Apache servers, so `fpm/`
   sets the three to `On` in `docker-compose.yml` (`clear_env = no` carries them into the
   workers) and turns `gzip on` in `conf/default.conf`; nginx covers all three natively.
   The apache stacks need nothing: `alias` and `deflate` are enabled by default in the
   Debian php:*-apache images and `headers` is `a2enmod`'d in their Dockerfiles.

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
  to silence `AH00558`. The probe hits **`/melis/`, never `/`** — `/` is the public
  site and only exists once a site is installed, so a back-office-only install (or one
  where the demo site's module failed, which the installer guard turns into a dropped
  module) answers 500 there. That marked php unhealthy and left vite stuck in `Created`
  forever on `depends_on: service_healthy`. Observed. `/melis/` answers in every state:
  302 to `/melis/setup` before the install, 302 to `/melis/login` after.

## CI (GitHub Actions, all multi-arch `linux/amd64,linux/arm64`)

- **`docker-image.yml`** — builds `dev/` base images, matrix `{apache,fpm} × {8.1..8.5}`,
  pushes `melisplatform/melis-docker-react:dev-{variant}-{php}` on `master` only.
- **`prebuilt-image.yml`** — builds the baked images: `prebuilt/` → `latest`/`php8.3`,
  `fpm/` → `fpm-latest`/`fpm-php8.3`; pushes on `master` pushes and `v*` tags.
- **`dockerhub-description.yml`** — syncs `DOCKERHUB.md` to the Docker Hub overview.
- PRs **build-only** (no push, no secrets needed). Pushing requires repo secrets
  `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`. Pushing a `.github/workflows/*` change
  needs the `workflow` scope on the `gh` token.

## How to test a change locally

```bash
# Pre-built (validated E2E): build the baked image, then run image + db
cd prebuilt && docker build -t melisplatform/melis-docker-react:latest . \
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
