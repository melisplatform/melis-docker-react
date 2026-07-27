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
 * The injected entry is gated on the platform being INSTALLED: pre-install,
 * melis.module.load.php lists only the installer modules (no MelisCore), so the
 * MelisCore services the React modules build on don't exist yet — loading them
 * then would fatal the install wizard. Once the installer rewrites the module
 * list (MelisCore appears), the React modules load on the very next request.
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
    exit(0); // already patched
}

$needle = 'MelisCore\MelisModuleManager::getModules()';
$inject = $needle . ",\n"
    . "        // React back-office (melis-docker-react). Declared here, NOT in\n"
    . "        // config/melis.module.load.php (the Modules tool rewrites that file and\n"
    . "        // would drop them), and AFTER getModules() so MelisReactOverride wins the\n"
    . "        // config merge. Gated on MelisCore being active: before the web installer\n"
    . "        // finishes, melis.module.load.php only lists the installer modules and\n"
    . "        // MelisCore's services don't exist yet — loading the React modules that\n"
    . "        // early would fatal the install wizard.\n"
    . "        (is_array(\$melisLoad = @include __DIR__ . '/melis.module.load.php')\n"
    . "            && in_array('MelisCore', \$melisLoad, true)\n"
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
