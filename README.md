# Melis Platform Dockerfiles — React edition

This repository contains Dockerfiles to be used for [Melis Platform](https://www.melistechnology.com/),
with the **new React back-office enabled by default**: on top of the classic back-office
(`/melis`), every runnable stack also serves the React/TypeScript back-office at
**`/melis-react`** (see [React back-office](#react-back-office-melis-react) below).

## Install Melis with Docker — choose your path

| Path | What you get | For whom | Folder |
|------|--------------|----------|--------|
| **Pre-built image** | Pull a ready-to-run Melis (no build) + MySQL, finish via the web installer | Fastest evaluation / "just run it" | [`prebuilt/`](prebuilt/) |
| **Turnkey build** | Builds a fresh Melis skeleton on your host, editable code in `./melis`, + MySQL | Developers who want the code locally | [`install/`](install/) |
| **nginx + PHP-FPM** | Production-style stack (nginx front, PHP-FPM, MySQL), skeleton baked into the image | A more production-like topology | [`fpm/`](fpm/) |
| **Mount existing project** | Mounts an existing Melis project into a PHP-apache build (enabling React rewrites *your* composer.json — commit first) | Projects you already have locally | [`app/latest/`](app/latest/) |
| **Dev base images** | Per-PHP-version base images only (Apache or FPM, PHP 8.1–8.5) | Building your own images | [`dev/`](dev/) |

> All paths finish the same way: the **native Melis web installer** at
> http://localhost:8080 (`/melis/setup`) sets up the DB schema, admin user and the
> optional demo site. The web installer is authoritative — the install is **not**
> scripted.

## Getting Started

Pick one of the paths below. Each folder is self-contained (its own
`docker-compose.yml`, `.env.example`, `conf/` and `README.md`) — see that folder's
README for full details.

> **Note:** Make sure host port **8080** is free (change `HOST_PORT` in `.env` if not).

### Clone the repository
```bash
git clone https://github.com/melisplatform/melis-docker-react.git
```

### Path A — Pre-built image (fastest)
Runs the published image + a MySQL service. No build on your machine.
```bash
cd melis-docker-react/prebuilt
cp .env.example .env
docker compose up -d
```

### Path B — Turnkey build (editable code on your host)
First run does `composer create-project` of the Melis skeleton into `./melis`
(takes a few minutes); the code stays on your host, editable.
```bash
cd melis-docker-react/install
cp .env.example .env
mkdir -p melis        # pre-create the bind mount (required on Rancher Desktop/WSL)
docker compose up --build
```

### Path C — nginx + PHP-FPM (production-style)
```bash
cd melis-docker-react/fpm
cp .env.example .env
docker compose up --build
```

### Path D — Mount an existing Melis project
Unlike the other paths, this one does **not** create a Melis project — it mounts one
you already have. `docker-compose.yml` mounts `../../../`, which is the directory
*containing* this repo, so clone it **inside your Melis project root**:

> ⚠ **Commit your project first.** Like every other path, this one enables the React
> back-office by default (`WITH_REACT=1`) — but here the application directory is
> *your* existing project, so the first boot rewrites your **`composer.json`,
> `composer.lock` and `config/application.config.php` on the host**. Commit (or
> stash) beforehand so you can diff and revert. Prefer a plain legacy Melis? Set
> `WITH_REACT=0` in `.env` before the first `up` and your project is left untouched.

```bash
# 1. clone into your Melis project root (not the other way round)
cd /path/to/my-melis-project
git status                       # commit/stash first — see the warning above
git clone https://github.com/melisplatform/melis-docker-react.git melis-docker-react

# 2. configure
cd melis-docker-react/app/latest
cp .env.example .env
#    edit APP_NAME + DB creds to match your project, and set
#    GITHUB_TOKEN=ghp_...   (the React step resolves 3 GitHub repos)
#    WITH_REACT=0           (only if you do NOT want the React back-office)

# 3. build + start
docker compose up -d --build
```

Before committing, add these to your **project's** `.gitignore` — the stack creates
them inside your working copy:

```gitignore
melis-docker-react/    # this repo, now nested in your project
auth.json              # written by the guard; contains your GITHUB_TOKEN
data/logs/             # installer log
```

The React step is idempotent and never fatal: if it fails you keep the legacy
back-office and can retry by restarting the container. `/melis-react` goes live once
the platform is installed.

> **Set `GITHUB_TOKEN` in `.env` *before* the first build.** The build pre-warms
> Composer's metadata cache, and Compose passes the token to it as a build secret
> (never baked into a layer). Unauthenticated, that pre-warm hits GitHub's 60
> requests/hour limit and gives up — the build still succeeds, but the **first boot
> then spends ~12 minutes** resolving repositories before Apache starts, and
> `http://localhost:8080` returns an empty page the whole time. Watch the build for
> `7.2M /composer/cache`; `WARNING: Composer cache pre-warm incomplete` means the
> token didn't arrive.

> **Windows:** a `start-docker.bat` helper is provided at the repo root for this path.
>
> **Your database is empty.** The `db` service is a fresh MySQL — it does not contain
> your data, and Melis reads its credentials from
> `config/autoload/platforms/<MELIS_PLATFORM>.php` *inside your project*, not from
> `.env`. To use existing data, point that file at the container (`hostname` =
> `<MELIS_CONTAINER_NAME>-db`, **no `:port`**) and import your dump. Full details in
> [`app/latest/README.md`](app/latest/README.md).

### Finish the install
Open http://localhost:8080 and follow the **Melis web installer**. When it asks for
the database, use the values from your `.env`:

| Field | Value |
|-------|-------|
| Host | `melis-db` &nbsp;*(no `:port`)* |
| Database / User / Password | `melis` / `melis` / `melis` |

### Stop a stack
```bash
docker compose down       # keep data
docker compose down -v    # also remove volumes (DB + app), full reset
```

## React back-office (`/melis-react`)

The stacks in this repo enable the **new React/TS back-office** automatically
(`WITH_REACT=1`, the default). It runs **in parallel** with the classic back-office —
nothing about `/melis` changes:

| URL | What you get |
|-----|--------------|
| http://localhost:8080/melis | Classic (legacy) back-office |
| http://localhost:8080/melis-react | **React back-office** (same login) |

How it works: Composer pulls the public `melis-react` branches of
[`melis-core`](https://github.com/melisplatform/melis-core) (which ships a **committed
production build** of the React app, served by MelisAssetManager under
`/MelisCore/ui-react/` — no Node.js needed at runtime),
[`melis-react-api`](https://github.com/melisplatform/melis-react-api) (JSON API under
`/melis/react-api/*`) and
[`melis-react-override`](https://github.com/melisplatform/melis-react-override) (the
`/melis-react` SPA route + an iframe bridge that shows not-yet-migrated legacy tools
inside the React shell). `install/` does this on first boot; `prebuilt/` and `fpm/`
bake it into the image at build time. The two modules stay dormant until the web
installer completes, then activate on the next request.

> **Set `GITHUB_TOKEN` in `.env`** (classic token, no scopes). The React enablement
> adds three GitHub `vcs` repositories on top of the skeleton's four, and the
> unauthenticated GitHub API allows only 60 requests/hour.

Not interested in React? `WITH_REACT=0` in `.env` (turnkey stack), or build the
image with `--build-arg WITH_REACT=0` (pre-built/fpm) — you get a plain legacy Melis.

### Temporary dependency pin — `laminas/laminas-serializer:2.17`

The React enablement additionally requires `laminas/laminas-serializer:2.17`.
**This is a workaround and should be removed once upstream allows it.**

`melis-core` allows `^2.17 || ^3.0`, so resolving it on its own — which is what
enabling React does, before the web installer has added the CMS modules — picks the
newest match, `2.18.0`, and locks it. The installer later adds `melis-front`, which
requires *exactly* `2.17`, using a **partial** update (`--root-reqs`) that may not
downgrade an already-locked package. It fails with:

```
laminas/laminas-serializer[2.17.0] but the package is fixed to 2.18.0
(lock file version) by a partial update and that version does not match
```

and — because the installer ignores Composer's exit code — carries on and activates
modules it never installed, which is a bootstrap fatal on every URL. (The installer
guard repairs that afterwards; the pin avoids the failed step altogether.)

**When can it go?** When `melis-front` stops pinning an exact version. Check with:

```bash
docker compose exec php composer why laminas/laminas-serializer
# melisplatform/melis-front vX.Y.Z requires laminas/laminas-serializer (2.17)  ← still pinned
```

If that constraint becomes a range (e.g. `^2.17`), delete the
`"laminas/laminas-serializer:2.17"` line from `*/conf/enable-react.sh` (four copies:
`install/`, `prebuilt/`, `fpm/`, `app/latest/`). Tracked upstream as the
`melis-front` half of the issue described in [`CLAUDE.md`](CLAUDE.md) gotcha 8.

### Developing the React UI (Vite dev server)

The **turnkey stack ([`install/`](install/)) starts a Vite dev server by default** —
it's the stack meant for working on the React back-office, so `docker compose up`
brings up three services: `php`, `db` and `vite`:

```bash
cd install
cp .env.example .env
mkdir -p melis
docker compose up -d --build
# → http://localhost:8080/melis-react   the React back-office (served by PHP)
# → http://localhost:5173               the same UI with hot reload (Vite)
```

Vite proxies `/melis`, `/assets` and `/Melis*` to the PHP container, so the dev
server talks to your real Melis instance. On first boot it restarts a few times
while the skeleton downloads — that's expected, it's waiting for the sources. Don't
want it? `docker compose up -d php db`, or `docker compose stop vite`.

For the other stacks (`prebuilt/`, `fpm/`) the dev server stays opt-in, since their
code lives in a named volume rather than on your host:

```bash
cd prebuilt
docker compose -f docker-compose.yml -f docker-compose.vite.yml up -d
# or: make up STACK=prebuilt VITE=1
```

The source lives in `vendor/melisplatform/melis-core/ui-react/` (Vite + React 19 +
TypeScript + Tailwind v4) — under `install/melis/` on your host, so your IDE edits it
directly. To ship a change, build it back into the assets `/melis-react` serves:

```bash
cd install && docker compose exec vite npm run build
# output → vendor/melisplatform/melis-core/public/ui-react/
```

## Run several projects at once (shared local proxy)

Each stack publishes a host port (`8080` by default), so running several at once
means juggling port numbers. To avoid that — and any `:80` clash with other local
Docker projects — there's an **opt-in** shared reverse proxy in
[`local-proxy/`](local-proxy/) ([`nginxproxy/nginx-proxy`](https://github.com/nginx-proxy/nginx-proxy)).
It owns `:80` and routes by hostname; each stack declares a `VIRTUAL_HOST` and the
per-stack `docker-compose.proxy.yml` override drops its published port.

```bash
# 1) Once: create the shared network and start the proxy
docker network create webproxy
docker compose -f local-proxy/docker-compose.yml up -d

# 2) Map the *.local hostnames to localhost (one line in /etc/hosts)
#    127.0.0.1  melis-prebuilt.local melis-install.local melis-fpm.local melis-app.local

# 3) Bring up any stack WITH its proxy override (note the two -f flags)
cd prebuilt
cp .env.example .env
docker compose -f docker-compose.yml -f docker-compose.proxy.yml up -d
# → http://melis-prebuilt.local/   (no host port needed)
```

Default hostnames: `melis-prebuilt.local`, `melis-install.local`, `melis-fpm.local`,
`melis-app.local` — override any via `VIRTUAL_HOST` in that stack's `.env`. To run
**several stacks simultaneously**, also give each a distinct `MELIS_CONTAINER_NAME`
so container names don't collide.

> Without the `-f docker-compose.proxy.yml` flag every stack runs exactly as before
> (published on `HOST_PORT`) — the proxy is purely opt-in.

## Published image tags

[View on Docker Hub →](https://hub.docker.com/r/melisplatform/melis-docker)

**Pre-built (skeleton baked):**
- Apache (`mod_php`): `latest`, `php8.3`
- nginx + PHP-FPM: `fpm-latest`, `fpm-php8.3`

**Dev base images** (no app, just the PHP stack) — published from [`dev/`](dev/):
- Apache (`mod_php`): `dev-apache-8.1`, `dev-apache-8.2`, **`dev-apache-8.3`** (recommended), `dev-apache-8.4`, `dev-apache-8.5`
- PHP-FPM: `dev-fpm-8.1`, `dev-fpm-8.2`, `dev-fpm-8.3`, `dev-fpm-8.4`, `dev-fpm-8.5`

> **PHP 8.3** is the default/recommended version (officially supported by Melis 5.3.x).
> **PHP 8.4** is experimental but runs Melis (every dependency allows it). **PHP 8.5**
> base images build, but Melis does **not** run on 8.5 yet — the skeleton's Laminas
> dependencies cap at 8.4, so its `composer install` fails on 8.5. The `dev-*-8.5` tags
> are forward-looking (standalone PHP base) until upstream lifts the cap (see
> melisplatform/melis-core#24). `latest` stays on 8.3. The old PHP **7.x** tags are
> **not compatible** with current Melis.

All images are multi-arch (`linux/amd64`, `linux/arm64`).

## Choosing the PHP version

The buildable stacks (`install/`, `prebuilt/`, `fpm/`) default to **PHP 8.3**. To
build on another version, set `PHP_VERSION` in that stack's `.env` and rebuild:

```bash
cd install
echo "PHP_VERSION=8.4" >> .env     # 8.3 (default, recommended) | 8.4 (experimental)
docker compose up -d --build
```

> **8.4** is experimental but installs and runs Melis. **8.5 is not usable for Melis
> yet**: the skeleton's Laminas dependencies cap at 8.4, so `composer install` fails on
> 8.5 (it fails at run time for `install/`, and at *build* time for `prebuilt/`/`fpm/`
> which bake the skeleton). Use **8.3 or 8.4** to actually run Melis. The standalone
> `dev-*-8.5` base images do build — they're forward-looking. See melis-core#24.

## Handy shortcuts (Makefile)

A root [`Makefile`](Makefile) wraps the common `docker compose` calls. Pick a stack
with `STACK=…` (default `prebuilt`):

```bash
make up STACK=install     # cp .env + start (turnkey build)
make up-build STACK=fpm   # build + start the nginx + php-fpm stack
make logs                 # follow logs        make shell    # shell into php
make down                 # stop (keep data)   make destroy  # stop + wipe volumes
make proxy-up             # shared nginx-proxy  make up PROXY=1  # run a stack behind it
make up VITE=1            # also start the React (Vite) dev server on :5173
make adminer              # web DB client → http://localhost:8082
make help                 # list everything
```

## Troubleshooting / FAQ

**Port 8080 already in use** — change `HOST_PORT` in the stack's `.env`, or run
behind the [shared proxy](#run-several-projects-at-once-shared-local-proxy) and
drop host ports entirely.

**"Test database connection" fails in the web installer** — enter the DB **host
without a port** (e.g. `melis-db`, *not* `melis-db:3306`); a `host:port` value
breaks Melis' flyway/JDBC URL. Credentials are whatever you set in `.env`
(defaults `melis` / `melis` / `melis`). The DB must use collation
`utf8mb4_general_ci` (these compose files already do).

**The installer's "downloading modules" step takes forever** — it shouldn't any
more. That step runs Composer inside the request as `www-data`, which (with a
root-owned `/var/www` as its HOME) used to run with **no cache at all** and
re-downloaded every repository's metadata: ~12 minutes, almost all of it network
round-trips. The images now give Composer a shared, writable `COMPOSER_HOME`
(`/composer`) whose metadata cache is filled at build time (~30 s resolves instead
of ~12 min). If you see it crawl again:

- **Set `GITHUB_TOKEN` in `.env` before building.** The cache pre-warm needs it;
  unauthenticated it hits GitHub's 60 requests/hour limit and quietly gives up
  (the build still succeeds — only the first install is slow).
- **Rebuild after setting it**: `docker compose up -d --build`. An image built
  without the token carries an empty cache.
- Check that step's Composer output in `data/logs/melis-installer.log` (the
  installer guard saves what the wizard discards) for "Proceeding without cache".

**The page won't load on first start** — the first run downloads the Melis skeleton
(turnkey) or seeds the app volume (pre-built) before Apache/nginx answers; give it
a minute. Follow progress with `make logs` (or `docker compose logs -f`).

**Reset everything and start fresh** — `make destroy` (or `docker compose down -v`).
For the turnkey stack also delete the host code: `rm -rf install/melis`.

**Switch PHP version** — see [Choosing the PHP version](#choosing-the-php-version);
remember to rebuild (`--build`). The pre-built image's version is fixed by its tag.

**Connect a DB GUI** — the DB is published on `127.0.0.1:33061` (localhost only), or
run `make adminer` for a browser client at http://localhost:8082.

**Step-debugging (Xdebug)** — the turnkey [`install/`](install/) stack can bake Xdebug
in: set `WITH_XDEBUG=1` in `.env` and rebuild (`docker compose up -d --build`). It
connects back to your IDE on port **9003** and starts on a trigger (browser extension
or `XDEBUG_TRIGGER`). On Linux the compose file already maps `host.docker.internal`.

**Apache warning `AH00558: … ServerName`** — harmless; the images set
`ServerName localhost` to silence it.

## Contributing

Please note that this project is released with a [Contributor Code of Conduct](http://contributor-covenant.org/version/1/2/0/).

By participating in this project you agree to abide by its terms.

Feel free to fork the project, create a feature branch, and send us a pull request!

## Authors

* **Melis Technology** - [www.melistechnology.com](https://www.melistechnology.com/)

See also the list of [contributors](https://github.com/melisplatform/melis-docker/contributors) who participated in this project.

## License

This project is licensed under the OSL-3.0 License - see the [LICENSE](LICENSE) file for details