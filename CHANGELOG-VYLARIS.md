# Changelog of VylarisSpace

All notable changes of the fork are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The changelog of the original project stays untouched in `CHANGELOG.md`.

## 0.1.0 - unreleased

Base: HestiaCP 1.10.5.

### Added

- Phase 0: brand foundation in `VYLARIS.md` (decisions, logo usage, brand colours, semantic palette), trimmed logo files in `web/images/vylaris/`, theme entries `vylaris` and `vylaris-dark` with shared design tokens.
- Phase 1: the themes `vylaris` (light) and `vylaris-dark` with styling for all UI components (typography, top bar and menu, toolbar and lists, cards and statistics, forms and buttons, feedback dialogs, login). The Inter variable font (SIL OFL) is self-hosted. The web terminal takes its colours from the active theme.
- Phase 1: preview and audit tooling in `test/vylaris-preview` (stub rendering of the real templates, Playwright screenshots, contrast, colour, focus, overflow and touch target audit, comparison of two audit runs).
- Phase 3: the `hestia.conf` key `UPSTREAM_UPDATES` (default `no`), see below.
- Phase 3: `NOTICE` with attribution, the note on the original name restriction and the third-party components.
- Phase 3: `CHANGELOG-VYLARIS.md` and the phase notes in `VYLARIS.md`.
- Phase 4: tooling for an own apt repository in `src/vylaris/` (signing key, `reprepro` layout, publish with signature check, rollback and promote, server setup with apt pins) and the runbook in `VYLARIS-PACKAGING.md`. Stage 1 (hybrid): the repository carries only the package `hestia`.
- Phase 4: the `hestia.conf` key `VYLARIS_UPDATES` (default `no`, set to `yes` by the installers when a repository was configured) and the own update path: `bin/v-update-sys-vylaris`, `bin/v-add-cron-vylaris-autoupdate`, `bin/v-delete-cron-vylaris-autoupdate`, and the Updates page with installed and available version and the buttons "Check for Updates" and "Update Now" for the own channel.
- Phase 4: installer options `--vylaris-repo`, `--vylaris-key`, `--vylaris-key-fingerprint`, `--vylaris-repo-auth` (and the environment variables `VYLARIS_REPO_URL`, `VYLARIS_REPO_KEY`, `VYLARIS_REPO_KEY_FPR`, `VYLARIS_REPO_AUTH`), `--allow-insecure-http` / `-I` (or `VYLARIS_ALLOW_INSECURE_HTTP=yes`, tests only) and `--allow-upstream-hestia` for developers. `src/vylaris/client-setup.sh` makes an existing server trust the repository with the same checks.
- Phase 4: the workflow `.github/workflows/build-packages.yml` builds the `hestia` package (Ubuntu 24.04) and can publish it to the repository host when the repository variable `VYLARIS_PUBLISH` is `true`.
- Phase 4: package guard. `src/deb/hestia/control` has the field `Vylaris-Edition: VylarisSpace`; the new `src/deb/hestia/prerm` refuses a `hestia` package without it on `dpkg -i`; the apt hook `/etc/apt/apt.conf.d/90vylarisspace-guard` and the new `bin/v-check-package-source` refuse it before apt unpacks anything. Override: `/etc/hestiacp/allow-foreign-hestia` or `VYLARIS_ALLOW_FOREIGN_HESTIA=yes`. `src/hst_autocompile.sh` ships the hook and the prerm and stops without the marker, `.github/workflows/build-packages.yml` checks them in the built package, `src/vylaris/repo-publish.sh` refuses to publish or promote a `hestia` deb without the marker.
- Phase 4: the preinst saves shipped files that were changed on the server (`dpkg --verify hestia`, content changes and deleted files) to `/root/hst_backups/modified-shipped-files-DDMMYYYYHHMMSS/` before the upgrade replaces them. Limits: 1 MiB per file, 20 MiB, 500 files, 200 MB free.
- Phase 4: tests. `test/vylaris-upgrade/` (real installer and update in Docker, before and after comparison), `test/vylaris-upgrade-unit/` (version steps, `hestia.conf` rewrite, postinst guard, download helpers; `run-in-docker.sh`), `test/vylaris-guard/` (package guard in Docker; `check-version-steps.sh` runs in CI).
- Phase 4: section 15 "What an update touches" in `VYLARIS-PACKAGING.md`.

### Changed

- Phase 1: new installs default to the `vylaris` theme. The product name is shown as VylarisSpace.
- Phase 3: user-visible branding (UI strings, e-mails, installer and console banners, 2FA issuer, default `APP_NAME`, logos and favicon) now uses the product name VylarisSpace. Internal identifiers keep the name `hestia`, see `VYLARIS.md`.
- Phase 3: two-factor authentication QR codes are generated on the server. The TOTP secret is no longer sent to an external QR service.
- Phase 3: the legacy themes `default`, `dark`, `flat` and `vestia` are hidden from the theme selection of customers and admins. Their files stay in place.
- Phase 3: help and "More info" links are controlled by one helper and hidden by default (`HIDE_DOCS`).
- Phase 3: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, the issue templates and the descriptions in `src/deb/*/control` are rewritten for the fork. Security reports go through GitHub's private vulnerability reporting.
- Phase 3: the BATS workflow runs only when started manually.
- Phase 3: the configuration of the internal documentation site no longer contains upstream links, donation and team entries or search credentials.
- Phase 4: the installers refuse to run without a package source (`--vylaris-repo` or `--with-debs`), write the key, source list and apt pins of the own repository, and no longer compare versions with the upstream project. `install/hst-install.sh` no longer downloads the installer from upstream.
- Phase 4: `src/hst_autocompile.sh` builds the `hestia` package from the local checkout (`~localsrc`) without downloads, bundles the PHP libraries (`web/inc/vendor`, `web/src/vendor`; Composer fetches them from Packagist and GitHub at build time, so the build host needs `composer`), removes development files and Markdown documentation of the libraries from the package (licence files stay), writes `SHA256SUMS`, and works without a terminal. Source locations of the other packages are configurable by environment variables.
- Phase 4: `bin/v-add-sys-dependencies` does not run Composer when the bundled `vendor` folders are complete.
- Phase 4: the Updates page offers "Check for Updates", "Update Now" and the automatic update toggle for the own channel when `VYLARIS_UPDATES` is `yes`. The upstream update buttons are intentionally not available in hybrid mode.
- Phase 4: formatting fixes that the linters (biome, prettier) reported in files touched by phase 4.
- Phase 4: `func/upgrade.sh` runs version steps only up to the base version of the installed package (`upgrade_base_version`, `1.10.5-101+ubuntu24.04` is `1.10.5`). Before, `install/upgrade/versions/1.10.6.sh` ran on every own update because the package says 1.10.5, and its `UPGRADE_REBUILD_USERS='true'` rebuilt all users each time. A new revision of a released version no longer runs the step of the installed version again (a `~alpha` or `~beta` build still does). The rebuild now happens when the base version rises.
- Phase 4: `func/syshealth.sh` no longer cuts a `hestia.conf` value at `#` when it repairs duplicated keys (`syshealth_normalize_config_file`). Values with `|`, `&` or a backslash in a duplicated key no longer break the rewrite. Comment and empty lines pass through unchanged.
- Phase 4: `src/deb/hestia/postinst` runs the upgrade procedure only for `configure`. dpkg also calls it with `abort-upgrade`, `abort-remove` and `abort-deconfigure` after a failed or refused upgrade, which started the procedure again. `update_whitelabel_logo` runs right after the version steps, before the steps that need the network.
- Phase 4: `upgrade_b2_tool`, `upgrade_phpmyadmin`, `upgrade_phppgadmin` and `upgrade_cloudflare_ip` in `func/upgrade.sh` download to a temporary place and replace the installed copy only after the download was checked. A failed download prints a warning and keeps the installed version. Before, a failed Backblaze download removed the old tool, and a failed phpMyAdmin download removed `doc/html` first and left tarballs in the current directory.

### Removed

- Phase 3: upstream links shown to users (documentation, forum, GitHub issues and releases), the donation block and the upstream tagline.
- Phase 3: the Crowdin workflow and configuration, and the donation file in `.github`.
- Phase 4: the version check of the installers against the upstream release branch.

### Security

- Phase 3: upstream update channels do not run by default. With `UPSTREAM_UPDATES='no'` the Updates page, the autoupdate cron job and the update commands stop without network access and print a message. The cron job is not installed by default.
- Phase 3: the TOTP secret of a two-factor setup stays on the server.
- Phase 4: apt pins (`/etc/apt/preferences.d/vylarisspace`) allow the package `hestia` from the own repository only, so an upstream release cannot replace the fork through apt. The pin file has four stanzas in this order (apt uses the first that matches): upstream `origin apt.hestiacp.com` at -1, upstream `release o=apt.hestiacp.com` at -1, the own repository by host (`origin REPO_HOST`, an empty origin for a `file://` test repository) at 1001, and `origin *` at -1. The own stanza is bound to the host, not to the `Origin` of the Release file (any repository can claim an Origin). The repository is signed with a new key; the upstream key `install/deb/deb_signing.key` is not used for it.
- Phase 4: key trust. https is required (`http` only with `--allow-insecure-http` or `VYLARIS_ALLOW_INSECURE_HTTP=yes`). A key that is downloaded is accepted only with the fingerprint of its primary key; a local key file may omit it and the fingerprint is printed. A key file must contain exactly one primary key and no secret key, and an expired, revoked, disabled or invalid key is refused.
- Phase 4: repository credentials are read once, written to `/etc/apt/auth.conf.d/vylarisspace.conf` (mode 0600) and removed from the environment. They go only over https to the exact same host and port (strict host and port routing, no prefix match, redirects may not leave https). `set -x` tracing is switched off while credentials may be present. Error messages mask the user info of URLs.
- Phase 4: `UPSTREAM_UPDATES` and `VYLARIS_UPDATES` cannot both be `yes`: `v-change-sys-config-value` refuses to enable one while the other is on, and `v-update-sys-hestia-git` refuses to run while `VYLARIS_UPDATES` is `yes` (it installs with `dpkg -i`, which ignores the pins).
- Phase 4: `bin/v-update-sys-vylaris` checks the pin file (the four stanzas in order, the host of the own source list in the own stanza) and refuses to update when it is missing or edited (exit code 10, log entry). `v-update-sys-vylaris status` prints `pin_ok=yes|no`. It installs only a newer version that is offered by the own source only.
- Phase 4: customer servers need no access to Packagist or GitHub for the PHP libraries (they are fetched at build time).
- Phase 4: the package guard refuses a package named `hestia` without the marker on `dpkg -i` (prerm) and on apt paths (hook), so an upstream `hestia` package cannot replace the panel by accident and remove the VylarisSpace themes, logos and update scripts.

### Known limits

- Phase 4: `hestia-nginx`, `hestia-php` and `hestia-web-terminal` still come from the upstream package source (stage 2 is a plan). The pins block only the package `hestia`, so these three receive their updates from the upstream repository through the normal system `apt upgrade`. Nothing has run against a real repository host or on a production server yet, and the `Maintainer` and `Homepage` fields in `src/deb/*/control` are unchanged.
- Phase 4: the pins protect the choice of the candidate and upgrades. An explicit `apt-get install hestia=VERSION` or `dpkg -i` still installs from a blocked source. The host of the own repository has to be dedicated to it, because the pin trusts the host; moving the repository to another host means running `client-setup.sh` again.
- Phase 4: the host pin was checked with apt 2.8.4 and unsigned local test repositories, not in the four distribution chroots and not with https and basic auth.
- Phase 4: a server is protected by the package guard only after it has installed the first build that contains it. A foreign package that ships its own `prerm` exiting 0 passes `dpkg -i` (the apt hook still stops it on apt paths). Builds from before the guard have no marker; a server with the guard refuses a downgrade to them until `/etc/hestiacp/allow-foreign-hestia` exists. `apt-get remove hestia` is not blocked. The guard was tested with stand-in packages in Docker (Ubuntu 24.04, Ubuntu 22.04, Debian 12), not with `unattended-upgrades`, `aptitude`, Debian 13, Ubuntu 26.04 or arm64. Renaming the package is the only block that does not depend on scripts and is an open owner decision.
- Phase 4: the CI check `test/vylaris-guard/check-version-steps.sh` prints a notice on the current tree, because `install/upgrade/versions/1.10.6.sh` exists while `src/deb/hestia/control` says 1.10.5. The step stays dormant (the upgrade code caps the steps at the package version); the check fails with `--strict` for release builds.
- Phase 4: the upgrade harness `test/vylaris-upgrade/` was not run again after the changes above, and the new postinst has not run through a real dpkg upgrade (the preinst has, with a stand-in package). The unit tests passed in an Ubuntu 24.04 container.
- Phase 4: an update still restarts services and replaces `/etc/nginx/conf.d/cloudflare.inc` from `api.cloudflare.com` (a third party, not gated by `UPSTREAM_UPDATES`; own `real_ip_from` lines belong in another include). The phpMyAdmin and Backblaze downloads are not gated either and have no checksum check. `upgrade_filemanager`, `v-add-sys-snappymail` and `v-add-sys-roundcube` in `bin/` may remove the installed copy before the download is checked; they were not changed.
- Phase 4: the saved copy of modified shipped files sees content changes and deleted files, not changes of mode or owner, and is skipped on a server without `data/users/admin`. Files in `web/images/custom` are kept but the panel templates reference `/images/vylaris/*`, so they do not change the panel pages.
