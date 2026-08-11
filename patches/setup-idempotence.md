# Re-running the setup wizard duplicates the site, the admin user and the platform

Local fix applied to `vendor/melisplatform/melis-core` **v6.0.3** and
`vendor/melisplatform/melis-installer` **v6.0.2**, to be opened upstream. `vendor/` is gitignored,
so `composer install` reverts it — reapply with:

```bash
cd vendor/melisplatform/melis-core     && patch -p1 < ../../../melis-docker-react/patches/melis-core-setup-idempotence.patch
cd vendor/melisplatform/melis-installer && patch -p1 < ../../../melis-docker-react/patches/melis-installer-duplicate-site.patch
```

## Symptom

Completing the wizard a second time on a platform that is already installed silently duplicates
everything the last step creates. Observed 2026-08-11 on `app/latest` (legacy wizard run
2026-08-10, React wizard run 2026-08-11):

| Table | Result |
|---|---|
| `melis_cms_site` | 2 rows, both `site_name = MelisDemoCms` — two full page trees (page 1 and page 35), two `melis_cms_site_404` mappings |
| `melis_core_user` | 2 rows, both `usr_login = admin` |
| `melis_core_platform` | 2 rows, both `plf_name = dev` |

The user duplicate is the damaging one: Melis authenticates through
`Laminas\Authentication\Adapter\DbTable` on `usr_login`
(`MelisCoreAuthService::setServiceManager`), which fails an AMBIGUOUS identity — so **nobody can
log into the back-office any more**, whatever the password. It surfaces as the generic
"Failed authentication", which sends you looking for a password problem that isn't there.

## Cause

Everything happens in `InstallerController::submitModuleConfigurationFormAction()` — shared by
both wizards (legacy carousel and React) — and nothing in that path is idempotent:

1. It dispatches every module's `MelisSetupPostDownload::submit`. MelisCore's inserts the admin
   user with a plain `save([...])` (no id ⇒ INSERT) and the platform row the same way.
2. It then calls `marketplaceSite()->installSite(...)->invokeSetup()`, which creates a site +
   page tree every time it runs, without checking whether that site already exists.

Nothing gates the endpoint itself, and `config/melis.install` is only written later by
`finalizeSetup`, so the wizard stays reachable and repeatable — deliberately so while the
installer is being developed.

## Fix

- **melis-installer** — `submitModuleConfigurationFormAction()` skips the site install when a
  `melis_cms_site` row already carries that module name (new `isSiteAlreadyInstalled()`). It
  returns false when `MelisEngineTableSite` isn't available (normal first install, CMS not
  installed yet), so the first run behaves exactly as before.
- **melis-core** — `MelisSetupPostDownloadController::submitAction()` looks the login up first and
  passes the existing id to `save()`, which then UPDATEs instead of inserting; the platform rows
  get the same treatment via a small `$savePlatform()` closure.

Net effect: the first install is unchanged, and a second pass updates the existing records instead
of duplicating them.

## Not covered

Cleaning up rows a previous double-run already created. The duplicate `melis_core_user` row can be
deleted directly (check for references first); a duplicate **site** is best removed with the CMS
Sites tool, which knows every table its page tree touches.

## Related

The React wizard also guards against re-submitting within a single run (`Step33ModuleConfiguration`
does not re-post the module forms once they have been accepted) — that covers going Back/Next over
the configuration step, but not a whole second run of the wizard, which is what the fixes above
address.
