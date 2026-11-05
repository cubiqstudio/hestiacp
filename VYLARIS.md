# VylarisSpace

Private fork of [HestiaCP](https://github.com/hestiacp/hestiacp) by VylarisGroupEurope.

## Phase status

| Phase | Content                                                                | Status      |
| ----- | ---------------------------------------------------------------------- | ----------- |
| 0     | Brand foundation, logos, tokens                                        | done        |
| 1     | Design: themes `vylaris` and `vylaris-dark`, preview and audit tooling | done        |
| 3     | Branding and safe defaults (see below)                                 | done        |
| 4     | Own package repository, stage 1, hardened (see below)                  | implemented |

Packaging (own package repository) is described in [VYLARIS-PACKAGING.md](VYLARIS-PACKAGING.md). The changes are listed in [CHANGELOG-VYLARIS.md](CHANGELOG-VYLARIS.md).

## License

HestiaCP is licensed under **GPL-3.0-or-later**. This fork stays under the same license.

- The `LICENSE` file and the copyright notices of the original authors stay in place.
- Own changes are also released under GPL-3.0-or-later.
- The source code has to be made available only if the fork (or a build of it) is passed on to third parties. Private use on your own servers does not require publication.
- Naming: the product is shown as "VylarisSpace". The names and the logo of the original project are not used in the UI of this fork (the original README forbids that for derivatives). Source code, license headers, internal identifiers and the credits in `NOTICE` keep the original name.
- `NOTICE` has the attribution, the third-party components and the note on the original name restriction.

## Phase 0 decisions

| Topic         | Decision                                                            |
| ------------- | ------------------------------------------------------------------- |
| Product name  | VylarisSpace                                                        |
| Themes        | `vylaris` (light) and `vylaris-dark` (dark)                         |
| Base approach | Theme override on top of `default.css`, no edits to upstream themes |
| Fonts         | Self-hosted only (no external CDNs, GDPR friendly)                  |
| Accessibility | WCAG 2.2 AA contrast for text and UI components                     |

## Logos

Source files live in `web/images/vylaris/` (trimmed, transparent PNG).

| File                     | Content                                   | Use on            |
| ------------------------ | ----------------------------------------- | ----------------- |
| `logo-full-on-light.png` | Mark + "Vylaris Group Europe", black text | light backgrounds |
| `logo-full-on-dark.png`  | Same, white text                          | dark backgrounds  |
| `logo-mark-on-light.png` | Mark only, black part                     | light backgrounds |
| `logo-mark-on-dark.png`  | Mark only, white part                     | dark backgrounds  |

The supplied files named "Dark" contain black parts and are therefore meant for light backgrounds. The files named "Light" contain white parts and are meant for dark backgrounds. They are mapped by content, not by file name.

## Brand colors (sampled from the logo)

| Token       | Value     | Origin                                     |
| ----------- | --------- | ------------------------------------------ |
| `brand-300` | `#3e9afa` | top of the V gradient                      |
| `brand-400` | `#3792f7` | V gradient / "Group"                       |
| `brand-500` | `#2679f5` | V gradient (main brand blue)               |
| `brand-600` | `#1f64e0` | interactive blue (buttons, links on light) |
| `brand-700` | `#0e52d1` | "Europe"                                   |
| `brand-800` | `#0a49c1` | "Europe" (dark end)                        |
| `ink`       | `#000000` | wordmark                                   |

`brand-500` is the pure logo blue. White text on it only reaches 4.09:1, so filled buttons use `brand-600` (5.31:1).

## Semantic palette

| Role                            | Light theme | Dark theme |
| ------------------------------- | ----------- | ---------- |
| Background                      | `#f6f8fb`   | `#0b0e14`  |
| Surface                         | `#ffffff`   | `#121722`  |
| Surface raised                  | `#ffffff`   | `#181f2c`  |
| Border                          | `#e3e8ef`   | `#232c3c`  |
| Text                            | `#1b2433`   | `#e6eaf2`  |
| Text muted                      | `#5b6678`   | `#98a2b5`  |
| Primary                         | `#1f64e0`   | `#3792f7`  |
| Primary on dark surface (links) | n/a         | `#5aa9fa`  |
| Success                         | `#15803d`   | `#34d399`  |
| Warning                         | `#b45309`   | `#fbbf24`  |
| Danger                          | `#b91c1c`   | `#f87171`  |
| Info                            | `#1f64e0`   | `#5aa9fa`  |

Measured contrast (WCAG): text on background 15.6:1 (light) and 16.0:1 (dark); muted text 5.5:1 and 7.0:1; primary link on dark 6.1:1 to 7.3:1; white on `brand-600` 5.3:1.

## Architecture of the themes

- `default.css` is always loaded first, a theme file is loaded on top (`web/templates/includes/css.php`).
- `web/css/src/themes/*.css` is built to `web/css/themes/*.min.css` by `npm run build`.
- Shared Vylaris code lives in the subfolder `web/css/src/themes/vylaris/` (not built as an entry on its own) and is imported by `vylaris.css` and `vylaris-dark.css`.

## Preview and audit tooling

`test/vylaris-preview` renders the real panel templates with stub data and fixtures (no running panel), takes screenshots per theme and viewport with Playwright and audits contrast, foreign colours, focus, overflow and touch targets. Reports can be compared with an earlier run. See `test/vylaris-preview/README.md`. The harness does not change `web/css/themes` or `package.json`.

## Phase 3: branding and safe defaults

### Naming rules

- Product name: **VylarisSpace** (one word). Company: **VylarisGroupEurope**.
- Prefer reading the runtime name (`$_SESSION["APP_NAME"]` in the panel, `APP_NAME` from `hestia.conf` in scripts) over hardcoding. Fall back to "VylarisSpace".
- Everything customers and admins see or receive is branded: UI strings, e-mails and notifications, installer and console banners and summary screens, the 2FA issuer, default values such as `APP_NAME`, logos and favicon.

### What stays "Hestia" internally, and why

Renaming these would break the running system or make merges from upstream impossible. They are not visible to customers.

- Paths and users: `/usr/local/hestia`, system users `hestiaweb` and `hestiamail`, `hestia.conf` and other config file names.
- Services and packages: systemd service names, deb package names (`hestia`, `hestia-nginx`, `hestia-php`, `hestia-web-terminal`).
- Commands and code: `v-*` command names, PHP namespaces (`Hestia\`, `Hestiacp\quoteshellarg`), environment variables (`HESTIA`, `HESTIA_CMD`), the `hestia-sso*.php` files.
- API and session: the `Hestia-Exit-Code` API header (client contract), the `HESTIASID` cookie, `hestia_token`.
- Translations: the gettext domain `hestiacp` is the name of the `.mo` files. Messages that contained the old name lose their translation and fall back to English until they are translated again.
- Firewall: the `HESTIA` iptables chain and the `hestia-<chain>` fail2ban names.
- Marker strings that scripts search for at runtime (for example `# Hestia SFTP Chroot`, `//Add Hestia SSO code here`, `modified by Hestia`, `# Configuration added by Hestia`) and the `Hestia` keys in `v-list-sys-*` output.
- License headers, `LICENSE`, vendor copyrights and the credits in `NOTICE`.

### Updates (`UPSTREAM_UPDATES`)

The upstream update channels would replace this fork with upstream HestiaCP. The new key `UPSTREAM_UPDATES` in `hestia.conf` defaults to `no`:

- The installers write it, `func/syshealth.sh` adds it when it is missing, `v-list-sys-config` lists it and `v-change-sys-config-value` accepts it.
- `UPSTREAM_UPDATES` and the own channel `VYLARIS_UPDATES` cannot both be `yes`: `v-change-sys-config-value` refuses (see phase 4).
- With `no`, the Updates page and button, the autoupdate cron job (it is not installed by default), `v-update-sys-hestia`, `v-update-sys-hestia-all`, `v-update-sys-hestia-git`, the download part of `v-update-white-label-logo`, `v-change-sys-release` and every other code path that downloads or installs from the upstream package source or repositories stop without network access and print one line: "Upstream updates are disabled (UPSTREAM_UPDATES=no) - VylarisSpace is updated through its own package source."
- Since phase 4 the installers no longer take the panel package from the upstream source. See the next section.

### Two-factor authentication

The QR code is generated locally. The TOTP secret never leaves the server (no request to an external QR service). The issuer shown in the authenticator is the product name.

### Links and help

All upstream links shown to users are removed: documentation, forum, GitHub issues and releases, the donation block and the upstream tagline. No replacement contact line or support URL is added. Help and "More info" links come from one helper (`docs_url()`) that returns an empty string when `HIDE_DOCS` is `yes`, and `HIDE_DOCS` defaults to `yes` for new installs.

### Themes

Only `vylaris` and `vylaris-dark` (and custom themes under `web/css/themes/custom`) are offered in the theme dropdowns of customers and admins. The legacy themes `default`, `dark`, `flat` and `vestia` are hidden; their files and CSS stay untouched because `default.css` is the mandatory base.

## Phase 4: own package repository (stage 1, hybrid)

Decisions (the engineering details are in [VYLARIS-PACKAGING.md](VYLARIS-PACKAGING.md)):

- The own apt repository carries only the package `hestia` (the panel). `hestia-nginx`, `hestia-php` and `hestia-web-terminal` still come from the upstream package source, signed by upstream. Building them is stage 2 and remains a plan.
- Because the package name and the base version are the same as upstream's, apt pinning is mandatory. `/etc/apt/preferences.d/vylarisspace` has four stanzas for the package `hestia`, in this order (apt uses the first that matches): the upstream origin `apt.hestiacp.com` at -1, the upstream `release o=apt.hestiacp.com` at -1, the own repository by **host** (`Pin: origin REPO_HOST`, an empty origin for a `file://` test repository) at 1001, and `origin *` at -1. The pin is bound to the host, not to the path and not to the `Origin` field of the Release file (any repository can claim an Origin), so the host of the own repository has to be dedicated to it. Moving the repository to another host means running `src/vylaris/client-setup.sh` again. An explicit `apt-get install hestia=VERSION` still installs from a blocked source: the pins protect the candidate selection and upgrades only.
- Versions are the base version plus the package revision from 100 on, for example `1.10.5-100+ubuntu24.04`. Never lower than upstream's base version.
- The signing key is new and is created on the owner's infrastructure with `src/vylaris/make-signing-key.sh`. No key, password or host is stored in the repository. The repository URL, key and credentials are configured by the owner (`VYLARIS_REPO_URL`, `VYLARIS_REPO_KEY`, `VYLARIS_REPO_KEY_FPR`, `VYLARIS_REPO_AUTH`, installer options `--vylaris-repo`, `--vylaris-key`, `--vylaris-key-fingerprint`, `--vylaris-repo-auth`). There is no default host.
- Key trust: the repository must be https (`http` only with `--allow-insecure-http` or `VYLARIS_ALLOW_INSECURE_HTTP=yes`, for tests). A key that is downloaded needs the fingerprint of its primary key (`--vylaris-key-fingerprint` or `VYLARIS_REPO_KEY_FPR`), published by the owner out of band (`gpg --show-keys --with-fingerprint pubkey.asc` on the owner's machine). A local key file may omit it, the script then prints the fingerprint. A key file must hold exactly one primary key, no secret key, and must not be expired or revoked.
- Credentials (`VYLARIS_REPO_AUTH`) are read once, written to `/etc/apt/auth.conf.d/vylarisspace.conf` (mode 0600) and removed from the environment. They are only sent over https to the exact same host and port. Tracing is switched off while credentials may be present. The command line option shows the password in the process list, so prefer the environment variable. Error messages mask the user info of URLs.
- The installers refuse to run without a package source, so a server never gets the upstream interface by accident. `--allow-upstream-hestia` exists for developers. The installers no longer compare versions with, or download scripts from, the upstream project. Checks that need no network run first and change nothing; the key download, the fingerprint of a downloaded key and the check for the suite follow after `apt-get update` and the installation of the installer dependencies.
- `UPSTREAM_UPDATES` stays `no`. The new key `VYLARIS_UPDATES` (default `no`, set to `yes` by the installers when a repository was configured) controls the own update path: `bin/v-update-sys-vylaris`, a cron job, and the Updates page with the installed and the available version and the buttons "Check for Updates" and "Update Now". The two keys exclude each other: `v-change-sys-config-value` refuses to enable one while the other is `yes`, and `v-update-sys-hestia-git` refuses to run while `VYLARIS_UPDATES` is `yes`. The upstream update buttons of the panel are intentionally not available in hybrid mode.
- `v-update-sys-vylaris` refuses (exit code 10) when the pin file is missing or edited and updates only from the own source; `status` prints `pin_ok=yes|no`. Restore the file by running `client-setup.sh` again.
- Stage-1 trade-off: the pins block only the package `hestia`. `hestia-nginx`, `hestia-php` and `hestia-web-terminal` receive their updates from the upstream repository through the normal system `apt upgrade`. That keeps the upstream repository a trusted root for them until stage 2.
- The package bundles the PHP libraries (`web/inc/vendor`). Composer fetches them from Packagist and GitHub at build time (the build host needs `composer`), servers do not fetch them at runtime. Development files and Markdown documentation of the libraries are not shipped, licence files are.
- CI: `.github/workflows/build-packages.yml` builds the package and can publish it to the repository host.

Open items for the owner: host name and public or private operation, the `Maintainer` and `Homepage` fields in `src/deb/*/control`, the legal review of distribution (GPL source offer, package names), stage 2.

### Repository and documentation

- Credits live in `NOTICE` and this file, not in the UI.
- `README.md`, `CONTRIBUTING.md` and `SECURITY.md` are rewritten for the fork. Security reports go to the repository owner through GitHub's private vulnerability reporting.
- The translation workflow (Crowdin) and the donation file are removed from the repository. The BATS workflow runs only when started manually.
- The `docs/` site is internal only. Its configuration no longer contains upstream links, donation entries or search credentials.
- Debian package descriptions use the new name. The `Maintainer` and `Homepage` fields in `src/deb/*` are unchanged until the owner provides contact data.
