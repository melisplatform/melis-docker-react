<?php
/**
 * melis-docker — web-installer guard (loaded via php.ini `auto_prepend_file`).
 *
 * WHY THIS EXISTS
 * ---------------
 * The Melis web installer adds the modules you tick (CMS/front/engine, the demo
 * site…) by running Composer *inside* an HTTP request:
 *   /melis/MelisInstaller/Installer/addModulesToComposer   → composer require --no-update
 *   /melis/MelisInstaller/Installer/downloadModules        → composer update --root-reqs
 * Neither action checks Composer's exit code — both return a plain ViewModel, so
 * the response is HTTP 200 whatever happens, and the wizard's JS (which chains on
 * `.done()`) marches on. `activateModulesAction` then writes MelisEngine/MelisFront
 * into config/melis.module.load.php *without checking they exist on disk*.
 *
 * Result when that Composer step fails for any reason (network, GitHub API quota,
 * a lock conflict a partial update can't resolve): the module list references
 * modules that were never installed, and the very next request dies at bootstrap
 * with "Module (MelisEngine) could not be initialized" — every URL 500s, including
 * /melis/setup and the back-office login. The install is unrecoverable from the UI.
 *
 * WHAT THIS DOES
 * --------------
 * 1. Tees every installer response into data/logs/melis-installer.log, so the
 *    Composer output — the error nobody reads — survives the request.
 * 2. Before each request, if config/melis.module.load.php lists a module that is
 *    not on disk, it repairs the situation: it retries the install with
 *    --with-all-dependencies (which resolves the partial-update conflicts the
 *    installer's --root-reqs cannot), and if that still fails it drops the module
 *    from the list so the platform keeps booting and you can retry from the wizard.
 *
 * It never installs or activates anything you did not choose: it only reacts to
 * modules the installer itself has already written into the module list.
 *
 * The check is two stat() calls on the hot path — it only does real work when the
 * module list has changed since it was last verified.
 */

// CLI (entrypoint helpers, composer, dbdeploy) must never trigger any of this.
if (PHP_SAPI === 'cli') {
    return;
}

(static function (): void {
    $app = '/var/www/' . (getenv('APP_NAME') ?: 'melis');
    $moduleLoad = $app . '/config/melis.module.load.php';
    $logDir = $app . '/data/logs';
    $log = $logDir . '/melis-installer.log';

    $write = static function (string $line) use ($logDir, $log): void {
        if (!is_dir($logDir)) {
            @mkdir($logDir, 0775, true);
        }
        @file_put_contents($log, $line, FILE_APPEND);
    };

    // ------------------------------------------------- 0. composer platform ---
    // Melis runs Composer inside the web installer and always passes
    // --ignore-platform-reqs, so the solver has no idea which PHP it is resolving
    // for and can install packages that need a NEWER one — e.g. symfony/console v8
    // (PHP >= 8.4.1) onto a PHP 8.3 image, whose 8.4-only syntax is a ParseError:
    // a hard fatal on every request, back-office included. Pinning the platform
    // makes --ignore-platform-reqs harmless. Once per container boot; an explicit
    // pin already in composer.json is left alone.
    $pinStamp = sys_get_temp_dir() . '/melis-platform-pinned';
    if (!is_file($pinStamp) && is_file($app . '/composer.json')) {
        @touch($pinStamp);
        // Reuse the shared, www-data-writable Composer home (COMPOSER_HOME, set in
        // the Dockerfile) so this run hits the cache the image/entrypoint already
        // filled. Falling back to a private temp home means no cache at all: every
        // vcs repository's refs get re-enumerated over the GitHub API (minutes).
        $home = getenv('COMPOSER_HOME') ?: sys_get_temp_dir() . '/melis-guard-composer';
        @mkdir($home, 0775, true);
        $cfg = static function (string $args) use ($home, $app): array {
            $out = [];
            @exec(sprintf('COMPOSER_HOME=%s composer config %s --working-dir=%s 2>/dev/null',
                escapeshellarg($home), $args, escapeshellarg($app)), $out);
            return $out;
        };

        // (a) THE fix for the installer's "Could not authenticate against github.com".
        //     The skeleton declares four `vcs` repositories (the melisplatform
        //     laminas-mail/mime/crypt/file forks) and the lock really does resolve
        //     laminas-mail/mime/crypt/file from them, so EVERY Composer resolution
        //     the installer runs queries the GitHub API for all four. Unauthenticated
        //     that is 60 calls/hour per public IP; once spent, Composer cannot prompt
        //     for credentials under --no-interaction and throws — *before* it writes
        //     composer.json, so `addModulesToComposer` silently installs nothing and
        //     the platform ends up with modules activated but absent.
        //     A token raises the limit to 5000/hour and also covers dist downloads.
        //     Set GITHUB_TOKEN in .env (a classic token with no scopes is enough for
        //     public repos). auth.json is what the in-process Composer reads.
        //     NB: `use-github-api false` looks like a token-free alternative — it is
        //     not. The git driver then fails with "No valid composer.json was found in
        //     any branch or tag of .../laminas-crypt". Verified; do not re-add it.
        $token = (string) getenv('GITHUB_TOKEN');
        if ($token !== '' && !is_file($app . '/auth.json')) {
            @file_put_contents($app . '/auth.json',
                json_encode(['github-oauth' => ['github.com' => $token]], JSON_PRETTY_PRINT) . "\n");
            @chmod($app . '/auth.json', 0600);
            @chown($app . '/auth.json', 'www-data');
            error_log('[melis-docker] wrote auth.json from GITHUB_TOKEN — the installer'
                . ' will not hit the unauthenticated GitHub API limit');
        } elseif ($token === '') {
            error_log('[melis-docker] no GITHUB_TOKEN set: Composer will use the'
                . ' unauthenticated GitHub API (60 req/hour per IP). If the installer'
                . ' reports "Could not authenticate against github.com", set one in .env.');
        }

        // (c) Pin the platform so a plain resolve targets this PHP. NOTE: this does
        //     NOT protect the installer's own runs — --ignore-platform-reqs, which
        //     Melis always passes, ignores the pin too. It matters for the repair
        //     below, which deliberately resolves without that flag first.
        if (trim(implode('', $cfg('platform.php'))) === '') {
            $version = PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '.' . PHP_RELEASE_VERSION;
            $cfg('platform.php ' . escapeshellarg($version));
            error_log('[melis-docker] pinned Composer platform.php to ' . $version);
        }
    }

    // ---------------------------------------------------------------- 1. tee ---
    $uri = $_SERVER['REQUEST_URI'] ?? '';
    if (strpos($uri, '/melis/MelisInstaller/Installer/') !== false) {
        // Keep PHP diagnostics OUT of the wizard's replies. Melis re-enables
        // display_errors at runtime (melis-installer's app.interface.php wins the
        // config merge with display_errors=1), so a notice gets printed *into* the
        // response — and several wizard steps are $.get(..., 'json'), where a
        // leading "<br /><b>Warning</b>..." makes the parse fail and the step die.
        // conf/vhost.conf locks this with php_admin_flag, which ini_set() cannot
        // override, but that only applies to images built from this repo; this
        // covers the published pre-built image too. Errors are logged, not lost.
        set_error_handler(static function (int $no, string $str, string $file = '', int $line = 0): bool {
            if ((error_reporting() & $no) !== 0) {
                error_log(sprintf('[melis-docker][installer] %s in %s:%d', $str, $file, $line));
            }
            return true; // handled — PHP must not render it into the response
        });

        $write("\n===== " . date('c') . ' ' . $uri . " =====\n");
        ob_start(static function (string $chunk) use ($write): string {
            if ($chunk !== '') {
                // strip the ANSI-ish markup Melis wraps composer output in
                $write(preg_replace('#<[^>]*>#', '', $chunk));
            }
            return $chunk;
        }, 8192);
    }

    // ------------------------------------------------------------- 2. repair ---
    if (!is_file($moduleLoad)) {
        return;
    }

    // Hot path: skip unless the module list changed since the last verification.
    $stamp = sys_get_temp_dir() . '/melis-module-load.verified';
    $mtime = @filemtime($moduleLoad);
    if ($mtime !== false && @file_get_contents($stamp) === (string) $mtime) {
        return;
    }

    $modules = @include $moduleLoad;
    if (!is_array($modules)) {
        return;
    }

    // A module is "present" if it lives under module/ or ships in an installed
    // melisplatform package (extra.module-name in composer's installed.json).
    $present = [];
    foreach (['', '/MelisSites', '/AIModules'] as $sub) {
        foreach ((array) @glob($app . '/module' . $sub . '/*', GLOB_ONLYDIR) as $dir) {
            $present[basename($dir)] = true;
        }
    }
    $installed = @json_decode((string) @file_get_contents($app . '/vendor/composer/installed.json'), true);
    foreach (($installed['packages'] ?? $installed ?? []) as $pkg) {
        if (!empty($pkg['extra']['module-name'])) {
            $present[trim($pkg['extra']['module-name'])] = true;
        }
    }

    $missing = array_values(array_filter($modules, static fn($m) => !isset($present[$m])));
    if ($missing === []) {
        @file_put_contents($stamp, (string) $mtime);
        return;
    }

    // Module name -> Composer package. Kebab-case covers the marketplace naming
    // (MelisCmsNews -> melis-cms-news); these few predate that convention.
    $aliases = [
        'MelisDbDeploy' => 'melisplatform/melis-dbdeploy',
        'MelisComposerDeploy' => 'melisplatform/melis-composerdeploy',
        'MelisMarketPlace' => 'melisplatform/melis-marketplace',
    ];
    $packages = [];
    foreach ($missing as $m) {
        $packages[] = $aliases[$m]
            ?? 'melisplatform/' . strtolower(preg_replace('/([a-z0-9])([A-Z])/', '$1-$2', $m));
    }

    // Only one repair at a time. Apache serves the healthcheck and the browser
    // concurrently, and two Composer runs against the same vendor/ (or two dbdeploy
    // passes against the same changelog) corrupt each other.
    $lock = @fopen(sys_get_temp_dir() . '/melis-guard.lock', 'c');
    if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) {
        return; // another request is already repairing; let it finish
    }

    $write(sprintf(
        "\n===== %s GUARD: %s activated but not installed =====\n",
        date('c'),
        implode(', ', $missing)
    ));
    error_log('[melis-docker] installer left these modules activated but not installed: '
        . implode(', ', $missing) . ' — attempting repair, see ' . $log);

    // Retry the install ourselves. -W (--with-all-dependencies) is the difference
    // that matters: the installer uses --root-reqs, a *partial* update, which fails
    // outright when a new module needs a version of an already-locked transitive
    // dependency (e.g. melis-front pins laminas/laminas-serializer to exactly 2.17).
    @set_time_limit(0);
    @ini_set('memory_limit', '-1');
    $home = getenv('COMPOSER_HOME') ?: sys_get_temp_dir() . '/melis-guard-composer';
    @mkdir($home, 0775, true);
    $run = static function (string $extra) use ($home, $packages, $app): array {
        $out = [];
        $exit = 1;
        @exec(sprintf(
            'COMPOSER_HOME=%s COMPOSER_ALLOW_SUPERUSER=1 composer require %s '
            . '--working-dir=%s -W %s --prefer-dist --no-scripts --no-progress '
            . '--no-interaction 2>&1',
            escapeshellarg($home),
            implode(' ', array_map('escapeshellarg', $packages)),
            escapeshellarg($app),
            $extra
        ), $out, $exit);
        return [$exit, $out];
    };

    // Resolve for the PHP we actually run first. Melis passes --ignore-platform-reqs
    // everywhere, but that flag ignores config.platform too, so the solver becomes
    // free to pick packages requiring a NEWER PHP — that is how symfony/console v8
    // (PHP >= 8.4.1) lands on a PHP 8.3 image and turns every request into a
    // ParseError. Only fall back to it if a clean resolve is impossible, which is the
    // PHP 8.5 case (Melis' own constraints still cap at ~8.4).
    [$exit, $output] = $run('');
    if ($exit !== 0) {
        $write("$ composer require " . implode(' ', $packages) . " (strict)\n"
            . implode("\n", $output) . "\nexit=$exit — retrying with --ignore-platform-reqs\n");
        [$exit, $output] = $run('--ignore-platform-reqs');
    }
    $write("$ composer require " . implode(' ', $packages) . "\n"
        . implode("\n", $output) . "\nexit=$exit\n");

    if ($exit === 0) {
        error_log('[melis-docker] repair succeeded — ' . implode(', ', $packages) . ' installed.');
        // Installing the code is only half of it: a Melis module also ships schema
        // deltas, and the installer already ran its dbdeploy step. Without these the
        // platform boots and then dies on the first query ("Table melis_cms_page_seo
        // doesn't exist"). Same discovery + apply the installer performs.
        try {
            require_once $app . '/vendor/autoload.php';
            $dataDir = $app . '/dbdeploy/data';
            if (is_dir($dataDir) && class_exists(\MelisDbDeploy\Service\MelisDbDeployDeployService::class)) {
                $copied = 0;
                foreach ($packages as $pkg) {
                    foreach ((array) @glob($app . '/vendor/' . $pkg . '/install/dbdeploy/*.sql') as $sql) {
                        if (!file_exists($dataDir . '/' . basename($sql)) && @copy($sql, $dataDir . '/' . basename($sql))) {
                            $copied++;
                        }
                    }
                }
                if ($copied > 0) {
                    $cwd = getcwd();
                    chdir($app);
                    $total = count((array) glob($dataDir . '/*.sql'));
                    // applyDeltaPath moves in batches — repeat until the changelog
                    // catches up (bounded; the installer's own version recurses forever).
                    for ($pass = 0; $pass < 20; $pass++) {
                        $svc = new \MelisDbDeploy\Service\MelisDbDeployDeployService();
                        if (false === $svc->isInstalled()) {
                            $svc->install();
                        }
                        $svc->applyDeltaPath(realpath('dbdeploy/data'));
                        if ($svc->changeLogCount() >= $total) {
                            break;
                        }
                    }
                    chdir($cwd);
                    $write("dbdeploy: copied $copied delta(s), changelog now "
                        . (new \MelisDbDeploy\Service\MelisDbDeployDeployService())->changeLogCount() . "/$total\n");
                    error_log('[melis-docker] applied ' . $copied . ' schema delta(s) for the repaired modules');
                }
            }
        } catch (\Throwable $e) {
            $write('dbdeploy failed: ' . $e->getMessage() . "\n");
            error_log('[melis-docker] schema deltas could not be applied: ' . $e->getMessage());
        }
        @file_put_contents($stamp, (string) @filemtime($moduleLoad));
        flock($lock, LOCK_UN);
        return;
    }

    // Still missing: drop them so the platform boots. Without this the next request
    // is a hard bootstrap fatal and nothing — not even the installer — is reachable.
    $kept = array_values(array_filter($modules, static fn($m) => !in_array($m, $missing, true)));
    $php = "<?php\nreturn " . var_export($kept, true) . ";\n";
    if (@file_put_contents($moduleLoad, $php) !== false) {
        $write("GUARD: repair failed, dropped from module list: " . implode(', ', $missing) . "\n");
        error_log('[melis-docker] repair FAILED. Dropped ' . implode(', ', $missing)
            . ' from the module list so the platform still boots. Re-run the wizard\'s'
            . ' module step, or install them manually. Composer output: ' . $log);
    }
    @file_put_contents($stamp, (string) @filemtime($moduleLoad));
    flock($lock, LOCK_UN);
})();
