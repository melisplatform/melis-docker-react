# `app/latest` — legacy dev stack (mount an existing Melis project)

The oldest of the runnable paths. Unlike [`install/`](../../install/),
[`prebuilt/`](../../prebuilt/) and [`fpm/`](../../fpm/), this stack **does not
provision a Melis project** — it bind-mounts one you already have:

```
docker-compose.yml:  ../../../  →  /var/www/${APP_NAME}
```

`../../../` is relative to `app/latest`, so it resolves to the directory that
*contains* this repo. Clone `melis-docker-react` directly into your Melis project
root:

```
my-melis-project/            <- mounted as the application
├── composer.json
├── config/
├── public/
└── melis-docker-react/
    └── app/latest/          <- ../../../ == my-melis-project
```

The image provides only the runtime: Apache + PHP (8.3 by default) + the Melis
extensions + Composer.

## Run it

```bash
# 1. clone into your Melis project root (not the other way round)
cd /path/to/my-melis-project
git clone https://github.com/melisplatform/melis-docker-react.git melis-docker-react

# 2. configure
cd melis-docker-react/app/latest
cp .env.example .env
#    edit APP_NAME + DB creds to match your project

# 3. optional but recommended: boot once with WITH_REACT=0 (the default)
docker compose up -d --build     # confirms the mount + DB work

# 4. OPTIONAL — enable the React back-office.
#    Make sure your project is committed first: this step rewrites your
#    composer.json, composer.lock and config/application.config.php.
#    Then edit .env by hand:   WITH_REACT=1
docker compose up -d
```

From the repo root, `make up-build STACK=app/latest` is equivalent to step 3.

Before committing, add these to your **project's** `.gitignore` — the stack creates
them inside your working copy:

```gitignore
melis-docker-react/    # this repo, now nested in your project
data/logs/             # installer log
```

Do **not** `git add -A` at your project root after a boot: the container also writes
`cache/` and may touch `config/`.

Open <http://localhost:8080> and follow the native Melis web installer
(DB host = `<MELIS_CONTAINER_NAME>-db`, **without** `:port`) — or read
[Your existing database](#your-existing-database) first if you want to bring your
own data instead.

## Your existing database

The `db` service is a **fresh, empty MySQL** — it does not contain your data, and
nothing imports it for you.

There is a second catch: Melis reads its DB credentials from **inside your project**,
at `config/autoload/platforms/<MELIS_PLATFORM>.php`, *not* from `.env`. The `MYSQL_*`
variables configure the container; they do not reconfigure your application. So a
project installed against `localhost` keeps pointing at `localhost`, which does not
exist on this network.

To run against your own data:

```bash
# 1. .env: MELIS_PLATFORM must match the platform file your project already has
#          (e.g. MELIS_PLATFORM=local  ->  config/autoload/platforms/local.php)

# 2. point that file at the container's DB — bare hostname, NO :port
#      'hostname' => 'melis-dev-db',      # = <MELIS_CONTAINER_NAME>-db
#      'username' => 'melis',
#      'password' => 'root',
#      'database' => 'melis-dev',         # match MYSQL_* in .env

# 3. import your dump
docker compose up -d db
docker compose exec -T db mysql -umelis -proot melis-dev < /path/to/your-dump.sql

# 4. start everything
docker compose up -d
```

A `host:port` value in `hostname` makes Melis build a double-port URL and breaks —
this was originally this stack's bug (gotcha 1 in [CLAUDE.md](../../CLAUDE.md)).

Your media files live in `mnt/public/media`, which is inside the bind mount, so they
come along with your code automatically.

If you don't need existing data, just run the web installer instead — it writes the
platform file for you with the correct container hostname.

## React back-office (`/melis-react`)

This is step 4 of [Run it](#run-it), described in full.

Supported here, but **off by default** — this is the one stack where the
application directory is *your own codebase* rather than a skeleton this repo
generated. Enabling React runs `composer require` against it, so it rewrites your
`composer.json`, `composer.lock` and `config/application.config.php` **on the
host**. Commit your work first.

```bash
# .env
WITH_REACT=1
```

then `docker compose up -d --force-recreate php`. The first boot pulls the
`melis-react` branches of `melis-core`, `melis-react-api` and
`melis-react-override` and patches `application.config.php`; `/melis-react` goes
live once the platform is installed. The step is idempotent (later boots skip it)
and never fatal — if it fails you keep the legacy back-office and can retry by
restarting the container.

> **No GitHub token is needed.** All three React packages are public and resolved
> from Packagist, so this step makes no GitHub API calls.

To undo: `git checkout composer.json composer.lock config/application.config.php`
in your project, `composer install`, and set `WITH_REACT=0`.

### Vite dev server (optional)

Only useful with `WITH_REACT=1`, and only for *developing* the React UI — using
`/melis-react` needs no Node.js, since PHP serves melis-core's committed
production build.

```bash
docker compose -f docker-compose.yml -f docker-compose.vite.yml up -d
# or:  make up VITE=1 STACK=app/latest
# → http://localhost:5173  (HMR, proxies /melis, /assets, /Melis* to php)
```

Because this stack's code is on the host, the sources it serves are the same
`vendor/melisplatform/melis-core/ui-react` tree you edit in your IDE. After
editing, `npm run build` regenerates `public/ui-react/` — that is what
`/melis-react` actually serves.

## Notes

- `conf/vhost.conf` hardcodes `/var/www/melis-dev`, so changing `APP_NAME` away
  from `melis-dev` also means editing that file.
- The installer guard (`conf/melis-installer-guard.php`) is loaded via
  `auto_prepend_file`, same as the other stacks — it logs the Composer output the
  web installer discards and repairs a module list referencing modules that failed
  to install. See the root [CLAUDE.md](../../CLAUDE.md).
- Shared local proxy: add `-f docker-compose.proxy.yml` (or `make up PROXY=1`).
