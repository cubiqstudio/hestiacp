# VylarisSpace

VylarisSpace is a web hosting control panel by VylarisGroupEurope. It manages web domains, mail accounts, DNS zones, databases and backups from one web interface and from the command line on a Debian or Ubuntu server.

VylarisSpace is a modified version of [HestiaCP](https://github.com/hestiacp/hestiacp) and is licensed under GPL-3.0-or-later. See [License and origin](#license-and-origin).

## Status

This is a **private fork under development**. It is not released.

- Phase 0 (brand foundation) and phase 1 (design) are done. Phase 3 (branding and safe defaults) is in progress. See [VYLARIS.md](VYLARIS.md) for the decisions and [CHANGELOG-VYLARIS.md](CHANGELOG-VYLARIS.md) for the list of changes.
- **No own package repository exists yet** (see [VYLARIS-PACKAGING.md](VYLARIS-PACKAGING.md)). The installer in `install/` still fetches the server packages from the upstream HestiaCP package source and prints a warning for that. A server installed that way gets the upstream interface, not VylarisSpace. Do not use the installer for production servers until the own package repository exists.
- Updates from upstream are switched off by default (`UPSTREAM_UPDATES='no'` in `hestia.conf`), so a server can not be replaced by upstream packages by accident.
- The documentation in `docs/` is inherited from upstream, not rewritten and for internal use only.

## Features and services

- Apache2 and NGINX with PHP-FPM
- Multiple PHP versions
- DNS server (Bind) with clustering capabilities
- POP/IMAP/SMTP mail services with anti-virus, anti-spam and webmail
- MariaDB/MySQL and/or PostgreSQL databases
- Let's Encrypt SSL support with wildcard certificates
- Firewall with brute-force attack detection and IP lists (iptables, fail2ban and ipset)

Supported platforms are inherited from the base version: Debian 11, 12 and 13, and Ubuntu 22.04, 24.04 and 26.04. 32 bit systems are not supported. Use a KVM or LXC virtual server, because OpenVZ 7 or lower may have problems with DNS and the firewall.

## Themes

Two themes are offered to users: `vylaris` (light) and `vylaris-dark`. The older upstream themes stay in the repository (`default.css` is the mandatory base of every theme) but are hidden in the theme selection. Admins can add their own themes under `web/css/themes/custom`. The design rules are in [VYLARIS.md](VYLARIS.md).

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
