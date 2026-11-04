# VylarisSpace

Private fork of [HestiaCP](https://github.com/hestiacp/hestiacp) by VylarisGroupEurope.

## Phase status

| Phase | Content                                                                | Status      |
| ----- | ---------------------------------------------------------------------- | ----------- |
| 0     | Brand foundation, logos, tokens                                        | done        |
| 1     | Design: themes `vylaris` and `vylaris-dark`, preview and audit tooling | done        |
| 3     | Branding and safe defaults (see below)                                 | in progress |

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
- With `no`, the Updates page and button, the autoupdate cron job (it is not installed by default), `v-update-sys-hestia`, `v-update-sys-hestia-all`, `v-update-sys-hestia-git`, the download part of `v-update-white-label-logo`, `v-change-sys-release` and every other code path that downloads or installs from the upstream package source or repositories stop without network access and print one line: "Upstream updates are disabled (UPSTREAM_UPDATES=no) - VylarisSpace is updated through its own package source."
- The installer still takes packages from the upstream source until the own package repository exists (`VYLARIS-PACKAGING.md`) and prints a warning. `--with-debs` installs self-built packages.

### Two-factor authentication

The QR code is generated locally. The TOTP secret never leaves the server (no request to an external QR service). The issuer shown in the authenticator is the product name.

### Links and help

All upstream links shown to users are removed: documentation, forum, GitHub issues and releases, the donation block and the upstream tagline. No replacement contact line or support URL is added. Help and "More info" links come from one helper (`docs_url()`) that returns an empty string when `HIDE_DOCS` is `yes`, and `HIDE_DOCS` defaults to `yes` for new installs.

### Themes

Only `vylaris` and `vylaris-dark` (and custom themes under `web/css/themes/custom`) are offered in the theme dropdowns of customers and admins. The legacy themes `default`, `dark`, `flat` and `vestia` are hidden; their files and CSS stay untouched because `default.css` is the mandatory base.

### Repository and documentation

- Credits live in `NOTICE` and this file, not in the UI.
- `README.md`, `CONTRIBUTING.md` and `SECURITY.md` are rewritten for the fork. Security reports go to the repository owner through GitHub's private vulnerability reporting.
- The translation workflow (Crowdin) and the donation file are removed from the repository. The BATS workflow runs only when started manually.
- The `docs/` site is internal only. Its configuration no longer contains upstream links, donation entries or search credentials.
- Debian package descriptions use the new name. The `Maintainer`, `Homepage` and copyright fields in `src/deb/*` are unchanged until the owner provides contact data.
