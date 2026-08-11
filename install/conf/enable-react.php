<?php
/**
 * melis-docker-react — patch config/application.config.php to load the React
 * back-office modules (MelisReactApi + MelisReactOverride).
 *
 * Why application.config.php and not config/melis.module.load.php: the back-office
 * "Modules" tool rewrites melis.module.load.php from its own registry and would
 * silently DROP the React modules (killing /melis-react). Appending them after
 * getModules() in application.config.php also lets MelisReactOverride win the
 * config merge (its PluginViewController override) — the pattern validated on dev6.
 *
 * The injected entry is gated on melis.module.load.php listing MelisCore (installed
 * platform) OR MelisInstaller (pre-install). The React modules are needed in BOTH
 * states: melis-installer >= 6.0.2 ships the React setup wizard (/melis-react/setup,
 * whitelisted as route `meliscore-melis-react-spa` in its pre-install redirect
 * guard), and that route is defined by MelisReactOverride — so gating on MelisCore
 * alone made /melis-react/* 404 until the legacy wizard had finished. Verified
 * 2026-08-11: loading both modules pre-install does NOT fatal the wizard
 * (/melis/setup and /melis-react/setup both 200 with only the installer modules
 * active). The gate stays non-empty rather than unconditional so a module list
 * that is neither state (e.g. mid-rewrite/truncated) doesn't load them blindly.
 *
 * CLI only, idempotent. Usage: php enable-react.php /path/to/application.config.php
 */

if (PHP_SAPI !== 'cli') {
    exit(1);
}

$file = $argv[1] ?? '';
$src  = @file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "[enable-react] cannot read {$file}\n");
    exit(1);
}
if (strpos($src, 'MelisReactOverride') !== false) {
    // Already patched — but a config written before 2026-08-11 carries the old
    // MelisCore-only gate, which 404s /melis-react/setup (the React install wizard)
    // on a not-yet-installed platform. Widen it in place; still idempotent.
    $upgraded = $src;
    $notes    = [];

    $oldGate = "&& in_array('MelisCore', \$melisLoad, true)";
    $newGate = "&& (in_array('MelisCore', \$melisLoad, true) || in_array('MelisInstaller', \$melisLoad, true))";
    if (strpos($upgraded, $oldGate) !== false) {
        $upgraded = str_replace($oldGate, $newGate, $upgraded);
        $notes[]  = 'widened the module gate to cover the pre-install React setup wizard';
    }

    // A config written before the WITH_REACT opt-out existed has no way to disable the
    // React back-office short of editing this file. Add the condition in place.
    $optOut = "&& getenv('WITH_REACT') !== '0'";
    $anchor = "            ? ['MelisReactApi', 'MelisReactOverride']";
    if (strpos($upgraded, $optOut) === false && strpos($upgraded, $anchor) !== false) {
        $upgraded = str_replace($anchor, "            " . $optOut . "\n" . $anchor, $upgraded);
        $notes[]  = 'added the WITH_REACT=0 opt-out to the module gate';
    }

    if ($upgraded !== $src) {
        $tmp = $file . '.enable-react.tmp';
        if (@file_put_contents($tmp, $upgraded) === false || !@rename($tmp, $file)) {
            @unlink($tmp);
            fwrite(STDERR, "[enable-react] cannot rewrite {$file}\n");
            exit(1);
        }
        echo "[enable-react] " . implode('; ', $notes) . "\n";
    }
    exit(0);
}

$needle = 'MelisCore\MelisModuleManager::getModules()';
$inject = $needle . ",\n"
    . "        // React back-office (melis-docker-react). Declared here, NOT in\n"
    . "        // config/melis.module.load.php (the Modules tool rewrites that file and\n"
    . "        // would drop them), and AFTER getModules() so MelisReactOverride wins the\n"
    . "        // config merge. Gated on the module list naming MelisCore (installed) or\n"
    . "        // MelisInstaller (pre-install): the React setup wizard at /melis-react/setup\n"
    . "        // is served by MelisReactOverride's SPA route, so the modules must load\n"
    . "        // BEFORE the install too (melis-installer >= 6.0.2 whitelists that route).\n"
    . "        // WITH_REACT=0 opts out without editing this file.\n"
    . "        (is_array(\$melisLoad = @include __DIR__ . '/melis.module.load.php')\n"
    . "            && (in_array('MelisCore', \$melisLoad, true) || in_array('MelisInstaller', \$melisLoad, true))\n"
    . "            && getenv('WITH_REACT') !== '0'\n"
    . "            ? ['MelisReactApi', 'MelisReactOverride']\n"
    . "            : [])";

$count   = 0;
$patched = str_replace($needle, $inject, $src, $count);
if ($count !== 1) {
    fwrite(STDERR, "[enable-react] unexpected application.config.php shape "
        . "(getModules() matched {$count} times, expected 1) — not patched\n");
    exit(1);
}

// Write atomically: a request served mid-write would fatal on a truncated config.
$tmp = $file . '.enable-react.tmp';
if (@file_put_contents($tmp, $patched) === false || !@rename($tmp, $file)) {
    @unlink($tmp);
    fwrite(STDERR, "[enable-react] could not write {$file}\n");
    exit(1);
}

echo "[enable-react] patched {$file}: MelisReactApi + MelisReactOverride will load"
    . " once the platform is installed.\n";
