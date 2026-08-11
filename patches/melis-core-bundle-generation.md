# melis-core: `generateBundle()` silently produces EMPTY bundles

Local fix applied to `vendor/melisplatform/melis-core` **v6.0.3**, to be opened upstream.
`vendor/` is gitignored, so the next `composer install` reverts it — reapply with:

```bash
cd vendor/melisplatform/melis-core
patch -p1 < ../../../melis-docker-react/patches/melis-core-bundle-generation.patch
```

Everything below is in `src/Service/MelisCoreModulesService.php`.

## Symptom

After a fresh install (React **or** legacy wizard — the trigger is common to both),
`etc/bundles/css/bundle-all.css` is **0 byte** and `etc/bundles/js/bundle-all.js` is **12 byte**,
containing only `;;;;;;;;;;;;` — one `;` per asset that failed to load.

Observed 2026-08-11 on `app/latest`:

```
09:38:04  etc/bundles/css/bundle-all.css      0 B
09:38:04  etc/bundles/js/bundle-all.js       12 B
10:26:52  module/MelisModuleConfig/config/app.interface.php   ← 'host' => 'localhost'
```

Consequences:

- `MelisWebPackService::getAssets(true)` prefers the bundle as soon as the file EXISTS, so a
  platform with `build_bundle => true` serves an empty stylesheet to the whole back-office.
- `MelisGenerateBundleListener` only regenerates when *neither* bundle-all file exists, so the
  empty files suppress every future rebuild — it never self-heals.
- The React back-office also consumes it (`melis-react-override`'s widget CSS is built from the
  same asset list), which is how this was found: legacy dashboard widgets rendered unstyled with
  their hidden JSON config node showing as raw text.

## Cause

`generateBundle()` does not read assets from disk — it fetches the platform's **own URLs over
HTTP** (`combineAssets()`, `minifyCss()`, `minifyJs()` all go through `getFileContent()`), and
the host comes from `getSafeAssetHost()`. Two ways that returns something unreachable:

1. No `meliscore/datas/<env>/host` configured yet — exactly the case right after an install,
   before `app.interface.php` is generated — so it falls back to `$_SERVER['HTTP_HOST']`. Behind
   a container port mapping or a proxy that is the *published* address (`localhost:8084` while
   Apache listens on `:80` inside), which the server cannot connect back to.
2. The per-module files written by `minifyCss()`/`minifyJs()` live in `etc/bundles/`, **outside
   the document root**, so fetching `/bundles/...` always 404s regardless of the host.

Every fetch returns empty → CSS concatenates to nothing, JS to one `;` per asset. `combineAssets()`
then writes that result, and the poison is permanent.

## Fix (3 changes)

1. **`getFileContent()` reads from disk first.** New `resolveAssetPath()` maps an asset URL to a
   file: document root → `etc/` (covers `/bundles/...`) → the module's `public/` dir via
   `config/melis.modules.path.php`, the same mapping MelisAssetManager uses. HTTP stays as the
   fallback for anything not resolvable. Also much faster: the full bundle run drops to ~0.2 s.
2. **`getSafeAssetHost()` keeps the hostname, fixes the port.** The fallback now pairs the request
   *hostname* with `SERVER_PORT` (the port the server actually listens on) instead of returning
   `HTTP_HOST` verbatim. The hostname must be preserved — Melis routes by domain, so replacing
   `melis.com` with `localhost` could land on another vhost. IPv6 literals keep their brackets.
   | `HTTP_HOST` | `SERVER_PORT` | result |
   |---|---|---|
   | `melis.com` | 80 / 443 | `melis.com` |
   | `melis.com:8443` | 8080 | `melis.com:8080` |
   | `localhost:8084` | 80 | `localhost` |
   | `[::1]:8084` | 80 | `[::1]` |
   | *(empty)* | 80 | `SERVER_NAME` |
3. **`combineAssets()` refuses to write an empty bundle.** If the concatenation is empty once the
   `;` separators are ignored, it returns without writing, leaving the previous bundle (or none) in
   place so the listener can retry. This is what makes the failure recoverable instead of terminal.

None of the three changes anything when bundling already works — they only remove the ways it can
fail silently.

## Verification

Re-ran `POST /melis/MelisCore/Modules/bundle` on the broken install:

```
before:  bundle-all.css        0 B     bundle-all.js         12 B
after:   bundle-all.css  1 366 503     bundle-all.js  5 100 784
         bundle-all-login.css 647 698  bundle-all-login.js 354 258
```

`/melis/get-css-bundles` serves the real 1.37 MB; `bundle-all.css` contains `col-md-10`,
`media-object`, `alert-gray`, `.hidden{`; back-office `/melis/` 200, `/melis-react` 200, both
bundle routes 200.
