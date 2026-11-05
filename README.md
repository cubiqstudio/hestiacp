# VylarisSpace

VylarisSpace is a web hosting control panel by VylarisGroupEurope. It manages web domains, mail accounts, DNS zones, databases and backups from one web interface and from the command line on a Debian or Ubuntu server.

VylarisSpace is a modified version of [HestiaCP](https://github.com/hestiacp/hestiacp) and is licensed under GPL-3.0-or-later. See [License and origin](#license-and-origin).

## Status

This is a **private fork under development**. It is not released.

- Phase 0 (brand foundation), phase 1 (design) and phase 3 (branding and safe defaults) are done. Phase 4 (own package repository, stage 1) is implemented but has not run on production infrastructure. See [VYLARIS.md](VYLARIS.md) for the decisions and [CHANGELOG-VYLARIS.md](CHANGELOG-VYLARIS.md) for the list of changes.
- The installers install the panel package `hestia` only from the **own package repository** of VylarisSpace (or from packages you built). Without a package source they refuse to run, so that a server never gets the upstream interface by accident. See [Install](#install).
- Honest limits of this stage: the three other server packages (`hestia-nginx`, `hestia-php`, `hestia-web-terminal`) still come from the upstream HestiaCP package source until the owner builds them (stage 2 in [VYLARIS-PACKAGING.md](VYLARIS-PACKAGING.md)). The apt pins block only the panel package `hestia`, so these three are updated from the upstream repository by the normal system `apt upgrade`. The pins protect the choice of the candidate and upgrades, not an explicit `apt-get install hestia=VERSION`; a package guard in the panel package refuses a `hestia` package that is not a VylarisSpace package, but a server has it only after it has installed the first build that contains the guard. There are no automated tests on real servers yet, and the package repository has no host: the owner has to set one up, on a host name that serves only this repository.
- What an update replaces, keeps and still does on a server (restarts, Cloudflare IP list, third-party downloads, rebuild only on a version bump) is described in [What an update touches](VYLARIS-PACKAGING.md#15-what-an-update-touches). Customisations belong in `web/css/themes/custom`, `web/js/custom_scripts`, `web/images/custom` and templates under new names; every file the package owns is replaced.
- Updates from upstream are switched off (`UPSTREAM_UPDATES='no'` in `hestia.conf`). A server updates only from the own package repository, when `VYLARIS_UPDATES='yes'`. The two keys cannot both be `yes`, and the update buttons of the panel for upstream are intentionally not available.
- The documentation in `docs/` is inherited from upstream, not rewritten and for internal use only.

## Features and services

- Apache2 and NGINX with PHP-FPM
- Multiple PHP versions
- DNS server (Bind) with clustering capabilities
- POP/IMAP/SMTP mail services with anti-virus, anti-spam and webmail
- MariaDB/MySQL and/or PostgreSQL databases
- Let's Encrypt SSL support with wildcard certificates
- Firewall with brute-force attack detection and IP lists (iptables, fail2ban and ipset)

The installers support Debian 12 and 13, and Ubuntu 22.04, 24.04 and 26.04. The package repository tooling creates suites for Debian 12 and 13 and Ubuntu 22.04 and 24.04 only. 32 bit systems are not supported. Use a KVM or LXC virtual server, because OpenVZ 7 or lower may have problems with DNS and the firewall.

## Themes

Two themes are offered to users: `vylaris` (light) and `vylaris-dark`. The older upstream themes stay in the repository (`default.css` is the mandatory base of every theme) but are hidden in the theme selection. Admins can add their own themes under `web/css/themes/custom`. The design rules are in [VYLARIS.md](VYLARIS.md).

## Install

The installer needs a package source. There is no default host, because the owner has not chosen one yet. Copy `install/hst-install.sh` and the file for your system (`install/hst-install-ubuntu.sh` or `install/hst-install-debian.sh`) to the server and run as root. Replace the placeholders in capital letters with your own values:

```bash
# From the own package repository (the repository is set up as described in VYLARIS-PACKAGING.md)
VYLARIS_REPO_AUTH=SERVER_USER:SERVER_TOKEN \
	bash hst-install.sh \
	--vylaris-repo https://REPO_HOST/REPO_PATH \
	--vylaris-key-fingerprint PRIMARY_FINGERPRINT

# From packages you built yourself (offline install, tests)
bash hst-install.sh --with-debs DEB_DIRECTORY
```

`VYLARIS_REPO_AUTH` is only needed for a private repository. `PRIMARY_FINGERPRINT` is the 40 digit fingerprint of the primary signing key. The repository owner reads it from the public key (`gpg --show-keys --with-fingerprint pubkey.asc`) and publishes it out of band; do not take it from the repository server.

| Option                                         | Environment variable              | Meaning                                                                                               |
| ---------------------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `--vylaris-repo URL` (`-R`)                    | `VYLARIS_REPO_URL`                | Package repository of VylarisSpace, `https://`                                                        |
| `--vylaris-key URL_OR_FILE` (`-K`)             | `VYLARIS_REPO_KEY`                | Public key of the repository, default `REPOSITORY_URL/pubkey.gpg`                                     |
| `--vylaris-key-fingerprint FINGERPRINT` (`-F`) | `VYLARIS_REPO_KEY_FPR`            | Refuse the key unless its primary fingerprint matches. Required for a key that is downloaded          |
| `--vylaris-repo-auth USER:PASSWORD` (`-A`)     | `VYLARIS_REPO_AUTH`               | Login for a private repository. The option shows in the process list, prefer the environment variable |
| `--allow-insecure-http` (`-I`)                 | `VYLARIS_ALLOW_INSECURE_HTTP=yes` | Accept an `http://` repository. Tests on trusted networks only, credentials are never sent over http  |
| `--with-debs DIRECTORY` (`-D`)                 |                                   | Install `hestia_*.deb` built from this source                                                         |
| `--allow-upstream-hestia` (`-U`)               |                                   | Developers only: install the upstream `hestia` package (red warning, no pins)                         |

All other installer options (`--help`) are inherited from the base version. Give option values as a separate argument (`--vylaris-repo URL`).

**Safe default.** Without `--vylaris-repo` (or `VYLARIS_REPO_URL`) or `--with-debs` the installer stops before it changes anything and says why. The upstream package would bring the upstream interface instead of VylarisSpace. The installer no longer downloads installer scripts from the upstream project and does not compare versions with it. It still contacts the upstream apt repository (`apt.hestiacp.com`) for hestia-nginx, hestia-php and hestia-web-terminal until stage 2, so that host must be reachable.

**Key trust.** The repository must be https. A key that is downloaded is accepted only with its primary fingerprint. A key given as a local file (`--vylaris-key FILE`) may omit the fingerprint; the installer then prints it as not verified. The key file must contain exactly one primary key and no secret key, and an expired or revoked key is refused. The checks that need no network run first and change nothing. The key download, the fingerprint of a downloaded key and the check that the repository has a suite for your distribution happen later, after `apt-get update` and the installation of the installer dependencies.

**Credentials.** `VYLARIS_REPO_AUTH` is read once, written to `/etc/apt/auth.conf.d/vylarisspace.conf` (mode 0600) and removed from the environment. It is sent only over https and only to the exact host and port of the repository. Tracing (`bash -x`) is switched off while credentials may be present.

**Pins.** The installer sets up the repository key (`/usr/share/keyrings/vylarisspace-keyring.gpg`), the source list and an apt pin file (`/etc/apt/preferences.d/vylarisspace`) that allows the package `hestia` only from the host of the own repository, so that a later upstream release cannot replace it. The pin trusts the host, so the host must serve nothing but this repository. If you move the repository to another host, run `src/vylaris/client-setup.sh` again on every server; `v-update-sys-vylaris` refuses to update while the pin file is missing or does not match. The details and the limits are in [src/vylaris/README.md](src/vylaris/README.md).

## Build the package

The panel package `hestia` is built from a checkout of this repository, on a machine of the target distribution (the version carries the distribution, for example `1.10.5-100+ubuntu24.04`). Node.js and Composer are needed; the build script installs missing build tools with apt, so run it as root:

```bash
bash src/hst_autocompile.sh --hestia --noinstall --keepbuild --pkgrev 100 '~localsrc'
```

The package and a `SHA256SUMS` file are written to `/tmp/hestiacp-src/deb`. The package contains the built assets and the PHP libraries (`web/inc/vendor`), so servers need no Composer or network access for them. Composer fetches the libraries from Packagist and GitHub at build time, so the build host needs network access. Development files and Markdown documentation of the libraries are not shipped, licence files are. Use a package revision of 100 or higher. The workflow `.github/workflows/build-packages.yml` does the same in CI and can publish to the repository.

Setting up the repository (signing key, `reprepro`, publishing, rollback) is in [src/vylaris/README.md](src/vylaris/README.md). The complete runbook, from the key to the first update, is the section "First release walkthrough" in [VYLARIS-PACKAGING.md](VYLARIS-PACKAGING.md).

## Build the assets

The stylesheets and scripts of the web interface are built with Node.js:

```bash
npm ci
npm run build
```

This writes `web/css/themes/*.min.css` and `web/js/dist/`.

## Preview and audit tooling

`test/vylaris-preview` renders the real panel templates with stub data (no running panel needed), takes screenshots per theme and viewport, and audits contrast, colours, focus, overflow and touch targets. Usage, options and the list of audit exceptions are in [test/vylaris-preview/README.md](test/vylaris-preview/README.md).

## Development

Format and lint with `npm run lint`. The upstream development notes in [CONTRIBUTING.md](CONTRIBUTING.md) apply in a reduced form; the BATS test suite can be started manually from the Actions tab of the repository.

## Security

Please report vulnerabilities privately, see [SECURITY.md](SECURITY.md).

## License and origin

VylarisSpace is licensed under the [GNU General Public License v3.0 or later](LICENSE). The modifications by VylarisGroupEurope are released under the same license. HestiaCP is based on VestaCP.

The names and the logo of the original project must not be used for derivatives. VylarisSpace therefore does not show them in its interface, e-mails or user documentation. [NOTICE](NOTICE) has the attribution, the note on the original name restriction and the list of third-party components with their licenses.
