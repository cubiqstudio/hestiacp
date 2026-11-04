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

### Changed

- Phase 1: new installs default to the `vylaris` theme. The product name is shown as VylarisSpace.
- Phase 3: user-visible branding (UI strings, e-mails, installer and console banners, 2FA issuer, default `APP_NAME`, logos and favicon) now uses the product name VylarisSpace. Internal identifiers keep the name `hestia`, see `VYLARIS.md`.
- Phase 3: two-factor authentication QR codes are generated on the server. The TOTP secret is no longer sent to an external QR service.
- Phase 3: the legacy themes `default`, `dark`, `flat` and `vestia` are hidden from the theme selection of customers and admins. Their files stay in place.
- Phase 3: help and "More info" links are controlled by one helper and hidden by default (`HIDE_DOCS`).
- Phase 3: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, the issue templates and the descriptions in `src/deb/*/control` are rewritten for the fork. Security reports go through GitHub's private vulnerability reporting.
- Phase 3: the BATS workflow runs only when started manually.
- Phase 3: the configuration of the internal documentation site no longer contains upstream links, donation and team entries or search credentials.

### Removed

- Phase 3: upstream links shown to users (documentation, forum, GitHub issues and releases), the donation block and the upstream tagline.
- Phase 3: the Crowdin workflow and configuration, and the donation file in `.github`.

### Security

- Phase 3: upstream update channels do not run by default. With `UPSTREAM_UPDATES='no'` the Updates page, the autoupdate cron job and the update commands stop without network access and print a message. The cron job is not installed by default.
- Phase 3: the TOTP secret of a two-factor setup stays on the server.
