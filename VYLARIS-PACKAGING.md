# VylarisSpace package repository plan

Status: plan only, nothing in this document has been built. It describes how VylarisGroupEurope can
run its own apt repository for the four packages of the panel and how updates reach the servers
afterwards.

## Why this is needed

- A fresh install still fetches `hestia`, `hestia-nginx`, `hestia-php` and `hestia-web-terminal` from
  the upstream HestiaCP apt repository (`apt.hestiacp.com`). Those packages contain the upstream
  interface, not VylarisSpace. Installers keep working only with `--with-debs <dir>` pointing to own
  packages until an own repository exists.
- The fork carries the same version number as upstream (`src/deb/hestia/control`: 1.10.5). Any upstream
  release above it would replace the fork on a server that still has the upstream source list.
- Because of that, every upstream update channel is switched off by default with the key
  `UPSTREAM_UPDATES='no'` in `hestia.conf` (scripts exit with
  "Upstream updates are disabled (UPSTREAM_UPDATES=no) - VylarisSpace is updated through its own package source.").
  This document is the plan for the "own package source" that sentence refers to.
- The panel web server (`hestia-nginx`) and PHP (`hestia-php`) are security relevant and are only
  patched through new package builds. Without an own repository nobody ships fixes for them.

## 1. What to build

`src/hst_autocompile.sh` builds four Debian packages. Read it together with `src/chroot_build_all.sh`
and `src/lxd_build_all.sh`.

| Package               | Content                                                                           | Built per                                | Source of the version                  |
| --------------------- | --------------------------------------------------------------------------------- | ---------------------------------------- | -------------------------------------- |
| `hestia`              | `bin`, `func`, `install`, `web` (JS and CSS built with `npm ci && npm run build`) | distro suffix and architecture           | `src/deb/hestia/control` (1.10.5)      |
| `hestia-nginx`        | backend nginx compiled with OpenSSL, PCRE and zlib sources                        | distro and architecture (native compile) | `src/deb/nginx/control` (1.30.6)       |
| `hestia-php`          | backend PHP-FPM compiled from source, depends on distro libraries (libzip, onig)  | distro and architecture (native compile) | `src/deb/php/control` (8.5.12)         |
| `hestia-web-terminal` | Node.js websocket terminal                                                        | distro and architecture                  | `src/deb/web-terminal/control` (1.0.6) |

Notes from reading the build script:

- The script downloads its own inputs: it reads the `control` files from
  `raw.githubusercontent.com/hestiacp/hestiacp/<branch>` and the source archive from
  `github.com/hestiacp/hestiacp/archive/<branch>.tar.gz`, unless the branch is `~localsrc`. The fork is
  private, so builds must use `~localsrc` (build from the checked out tree) or the `REPO` value and the
  archive link must be changed (two spots, `REPO='hestiacp/hestiacp'` and the hard coded archive URL).
- Third-party sources are pinned in the script (`OPENSSL_V`, `PCRE_V`, `ZLIB_V`, nginx and PHP versions).
  They are compiled into `hestia-nginx`, so a new OpenSSL, PCRE or zlib release needs a rebuild of that
  package by the owner. Nobody else will do it once upstream updates are off.
- `--pkgrev <n>` replaces the `-1` in the version suffix (`1.10.5-100+debian12`), `--release <id>`
  appends `~<id>` for CI builds.
- `--cross` and the usage text: the script builds the environment it runs in. For another architecture
  or another OS release use `src/chroot_build_all.sh` (debootstrap plus QEMU) or LXD (`src/lxd_build_all.sh`).
  Compiling nginx and PHP under QEMU works but is slow; native builders are the better CI choice.
- `src/deb/hestia/postinst` strips the version suffix with
  `sed -E 's/-[0-9]{1,}\+[a-z0-9\.]{1,}//'` before it compares versions. The suffix must therefore keep
  the shape `-<digits>+<letters or digits or dots>`. Do not put an extra `+vylaris` part into the
  version, it would break that parsing.
- `Maintainer` and `Homepage` in the four `control` files still name upstream. A Debian package needs
  a Maintainer; the owner has to decide which name and address go there (no contact line is shown to
  customers in the UI, this field is only visible in `apt show`).

## 2. Versioning

Rules to decide and then never change:

1. Keep the upstream base version in the package version (`1.10.5`) so that the upgrade scripts in
   `install/upgrade/versions/` (named after versions) keep working, and use the package revision for
   own releases: `1.10.5-100+debian12`, next own build `1.10.5-101+debian12`.
2. Start the revision at 100. A VylarisSpace build of a given upstream version is then always greater
   than upstream's own build of that version (`1.10.5-1+debian12`), which protects against the wrong
   candidate being chosen when both sources are visible.
3. Never go below upstream. When upstream releases 1.10.6 and it is merged, the fork's
   package becomes `1.10.6-100+...`.
4. Own migration steps that are not part of an upstream release can use a fourth component
   (`1.10.5.1`): the upgrade loop in `func/upgrade.sh` compares four numeric fields. Check this
   with a test upgrade before relying on it.
5. Epoch: do not add one now. An epoch (`1:1.10.5-...`) can never be removed again and makes every
   later version string longer. It is only needed if the fork wants to renumber below upstream
   (for example "1.0.0"). Decide this before the first public build; the recommendation is to keep
   the upstream numbering.
6. Pre-releases for CI use `--release`, for example `1.10.5-101+debian12~ci42`. Because `~` sorts
   before the empty string, CI builds never win over a final build.
7. Pin the repository on the servers: an apt preference with a high priority for the own origin and
   a negative priority for `apt.hestiacp.com` (`Pin: origin apt.hestiacp.com`, `Pin-Priority: -1`) removes
   the risk of an old upstream source list replacing the fork. `apt-mark hold hestia` is not enough, the
   upstream update script runs `apt-get install hestia` explicitly.

## 3. Repository tooling

| Option                   | Strengths                                                                                                         | Weaknesses                                                                           |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `reprepro`               | Small, declarative (`conf/distributions`), one command to add a deb and sign, easy to back up, no database server | No snapshots, single writer, not a web service                                       |
| `aptly`                  | Snapshots and promotion (staging to stable), REST API, merges mirrors                                             | Own database and state, more moving parts, publishes need care for each distribution |
| `apt-ftparchive` + shell | No extra tool beyond `apt-utils`, repository is just files                                                        | You maintain pool layout, `Release` generation and signing yourself                  |

Recommendation: start with `reprepro`. The repository has four packages, four or five distributions
and two architectures, which is exactly what it handles well, and its output is a plain directory
tree that can be served by any static web server or object storage. Move to `aptly` only if
staged promotion (for example "beta" to "stable") becomes important; the CI job can do the same
with two reprepro distributions or two repository paths.

Layout (same pattern as upstream, one suite per distribution codename):

```text
apt.example/            # host name is the owner's choice
  dists/bookworm/main/binary-amd64|arm64/
  dists/trixie/main/...
  dists/jammy/main/...
  dists/noble/main/...
  pool/main/h/hestia/...
  pubkey.gpg            # new VylarisGroupEurope public key (armored or dearmored)
  sources/              # source archives that belong to the published binaries (see GPL note)
```

## 4. Signing key

- Create a new signing key for the repository. Do not reuse `install/deb/deb_signing.key`, it is
  upstream's public key and installing it would trust upstream's key for the own repository.
- Use a dedicated key pair (ed25519 or RSA 4096) with an expiry (2 years) and a revocation
  certificate stored offline. Use a subkey for signing in CI, keep the primary key offline.
- Publish the public key as `pubkey.gpg` in the repository root and import it on servers into
  `/usr/share/keyrings/vylarisspace-keyring.gpg` (`gpg --dearmor`), referenced with `signed-by=` in the
  source list. Do not use `apt-key` or `/etc/apt/trusted.gpg.d/`.
- Store the private key as a CI secret (or use a signing host); rotate with an overlap period: publish
  a new key, ship it in a package that runs before the old one expires.
- Replace `install/deb/deb_signing.key` in the repository with the new public key once it exists, so the
  installers cannot fall back to the upstream key.

## 5. Hosting: private or public

| Aspect    | Public repository                                         | Private repository                                                                                   |
| --------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Access    | Anyone can install, simplest for customers                | Per-customer or per-server token                                                                     |
| GPL       | Anyone can obtain the binaries, publish source as well    | Binaries still go to third parties, same duties apply (see section 9)                                |
| Operation | Static files on any web server or object storage with CDN | Web server with basic auth or token check in front of the same static files                          |
| apt side  | Nothing special                                           | `/etc/apt/auth.conf.d/vylaris.conf` (`machine <host> login <user> password <token>`, mode 600, root) |
| Risk      | Version and package metadata public                       | Tokens on customer servers, rotation and revocation process needed                                   |

Recommendation: a private repository with per-server tokens while the product is young, built so that it
can be opened later by removing the auth rule. Use HTTPS only. Keep the signing independent of the
transport: apt verifies the signature, the token only controls who can download.

## 6. CI build matrix

Targets that `src/hst_autocompile.sh` already lists: Debian 11, 12, 13 and Ubuntu 22.04, 24.04, 26.04.
Recommended initial matrix for VylarisSpace (the installers only support what the owner tests):

| Distribution | Codename   | amd64 | arm64 |
| ------------ | ---------- | ----- | ----- |
| Debian 12    | `bookworm` | yes   | yes   |
| Debian 13    | `trixie`   | yes   | yes   |
| Ubuntu 22.04 | `jammy`    | yes   | yes   |
| Ubuntu 24.04 | `noble`    | yes   | yes   |

- That is 8 jobs, each building all four packages natively inside a container of the target
  distribution (`debian:12`, `debian:13`, `ubuntu:22.04`, `ubuntu:24.04`). Use x86-64 runners for
  amd64 and native arm64 runners for arm64. This avoids the QEMU chroot route for nginx and PHP
  (slow, memory heavy). Cross-compiling `hestia-nginx` and `hestia-php` is not supported by the script;
  the `hestia` package (shell and PHP files) is architecture independent in content.
- Run `hst_autocompile.sh --all --pkgrev <n> '~localsrc'` with the repository checked out. Pass the
  distro through the container so that `lsb_release` yields the suffix (`+debian12`, `+ubuntu24.04`).
- After the build: run `lintian` (informational), install the debs in a clean container with the
  installer's `--with-debs`, run the test suite (`test/` with bats, the same as `.github/workflows/test.yml`),
  and only then upload to the repository host.
- Sign and publish from one place (a job that runs `reprepro includedeb <codename> *.deb`), never from
  the matrix jobs in parallel. Publish to a staging suite first (for example a second repository path)
  and promote after a smoke test.
- Triggers: tag push (`v1.10.5-100`) builds a release; a nightly or manual job builds with `--release ci<run>`.
- Caching: keep the downloaded source archives (`src/archive/`) in the CI cache, they are large.
- Budget: a full native build of nginx and PHP takes a long time per job; plan for roughly 30 to
  60 minutes per distribution and architecture and check runner minutes for a private repository.

## 7. Changes needed in the installers and scripts

These touch files owned by other work streams; they are listed here so nothing is forgotten.

- `install/hst-install-debian.sh` and `install/hst-install-ubuntu.sh`: `RHOST` must point to the own host
  (or be configurable); the key import currently fetches `https://$RHOST/pubkey.gpg`; the apt source line
  `deb [arch=$ARCH signed-by=/usr/share/keyrings/hestia-keyring.gpg] https://$RHOST/ $codename main`
  becomes the own keyring and host. Write an apt preference file that pins the own origin.
- Version check: the installers compare against the upstream `release` branch `control` file on
  `raw.githubusercontent.com/hestiacp/hestiacp`; replace this by a check against the own repository, or
  drop it. `install/hst-install.sh` (the launcher) downloads the installer from upstream and must
  point to a place the owner controls.
- The `--with-debs <dir>` path (`withdebs`) already installs `hestia_*.deb`, `hestia-php_*.deb`,
  `hestia-nginx_*.deb` and `hestia-web-terminal_*.deb` from a directory and skips the final upgrade.
  This is the supported path until the repository exists and for offline installs.
- Auth: for a private repository the installer needs a way to take the token (option or prompt) and
  write `/etc/apt/auth.conf.d/vylaris.conf`.
- Do not install the daily cron `v-update-sys-hestia-all` by default. `func/syshealth.sh` now only adds it when
  `UPSTREAM_UPDATES='yes'`; the installers should follow.
- `install/deb/deb_signing.key`: replace with the new public key.
- `src/deb/*/control`: `Maintainer` and `Homepage` (see section 1).
- `src/hst_autocompile.sh`, `src/hst_bootstrap_install.sh`, `src/lxd_compile.sh`: `REPO`, raw and archive
  URLs point to `hestiacp/hestiacp`; they need the fork as source (or `~localsrc` only).
- `bin/v-update-sys-ip` still looks up the public IP at `ip.hestiacp.com`; the installers already use another
  provider.

## 8. How updates work afterwards

1. `UPSTREAM_UPDATES='no'` stays. It means "never talk to upstream", it does not mean "no updates".
2. Add an own, small update path that uses only the own repository. Two options:
   - Own script (recommended): `bin/v-update-sys-vylaris` runs
     `apt-get update` for the own source list only (the same `-o Dir::Etc::sourcelist=...` pattern the
     upstream script uses) and `apt-get install --only-upgrade hestia hestia-nginx hestia-php hestia-web-terminal`.
     A cron entry (add and delete scripts modelled on `v-add-cron-hestia-autoupdate`) makes it automatic, and
     the Updates page button can call it. `v-list-sys-hestia-updates` already reports installed versions
     and, when allowed, the apt candidate.
   - `unattended-upgrades` with `Origins-Pattern` for the own origin. Less code, but the panel shows
     nothing and every upgrade needs the package maintainer scripts to run unattended.
3. Keep the kill switch semantics separate: introduce a new key (for example `VYLARIS_UPDATES`) for the
   own channel so that `UPSTREAM_UPDATES` can stay `no` for good.
4. The `hestia` package `postinst` runs the upgrade scripts (`func/upgrade.sh`) and the system health
   check (`func/syshealth.sh`), so key migrations ship with the package.
5. Rollout order for a new version: staging repository, one test server, then stable. Keep the last
   two builds in the repository so that servers can be pinned back with `apt install hestia=<version>`.

## 9. Keeping up with upstream security fixes

Upstream HestiaCP stays the source of fixes for the panel code. The owner is now responsible for merging them.

- Remote: `git remote add upstream https://github.com/hestiacp/hestiacp.git`.
- What to watch: release tags (`v1.x.y`) and the `release` branch, the GitHub Security Advisories of
  `hestiacp/hestiacp`, and `CHANGELOG.md`. A subscription to the repository's releases (watch
  "Releases only" and security advisories) is enough; a weekly review is the minimum.
- Also watch the components compiled into the packages: nginx, PHP, OpenSSL, PCRE, zlib (versions in
  `src/hst_autocompile.sh` and `src/deb/*/control`) and Node.js for the web terminal. A fix there needs
  a new `hestia-nginx` or `hestia-php` build even if upstream HestiaCP does not release.
- Merge procedure:
  1. `git fetch upstream --tags`
  2. `git checkout -b merge/upstream-v1.x.y vylaris-webspace`
  3. `git merge v1.x.y` (or cherry-pick single security commits for urgent fixes)
  4. Resolve conflicts. Expect them in the branded files: installers, `web/templates/**`,
     `web/inc/helpers.php`, `web/css/src/themes/**`, `func/syshealth.sh`, `func/upgrade.sh`,
     `bin/v-update-sys-*`, `src/deb/*/control`, `README.md`.
  5. Re-run the branding checks: grep the user-visible spots (UI strings, mails, installer banners)
     for new upstream names or links, check `UPSTREAM_UPDATES` is still honoured by every script that
     downloads (`grep -rn "hestiacp\.com\|github.com/hestiacp\|raw.githubusercontent" bin func`), and rebuild
     CSS/JS (`npm ci && npm run build`).
  6. Update `src/deb/*/control` base versions to the merged versions, build with
     `--pkgrev 100`, run the tests, publish to staging, then promote.
- Keep merges small and frequent. A long divergence makes security merges risky.

## 10. GPL and distribution note (needs legal review)

This is a list of points to bring to a lawyer, not legal advice and not a conclusion.

- The project is GPL-3.0-or-later. `VYLARIS.md` currently treats use on the owner's own servers as private
  use. Handing packages to customers, or letting customers' servers download them from a repository
  the owner operates, may count as conveying the program to third parties. If so, the obligations of the
  GPL apply: license text and notices stay in the package, and the Corresponding Source for the exact
  binaries must be offered (accompanying source, or a written offer, or a public source repository).
- Operating the panel on servers the owner controls and giving customers access to the web interface
  is a different situation from giving them the packages. Which of the two applies to each customer
  contract should be clarified.
- The binaries contain more than the panel: nginx, PHP, OpenSSL, PCRE, zlib and Node.js modules with
  their own licenses (see `src/deb/*/copyright` and the vendor license files). The source archives that
  were used for a build should be kept and offered together with the binaries (the repository layout
  above has a `sources/` area for that).
- Own modifications must stay under GPL-3.0-or-later. Keep `LICENSE`, file headers and vendor
  notices. The credits stay in `NOTICE` and `VYLARIS.md`.
- Trademark: the upstream `README.md` states that the name and logo "Hestia Control Panel" and "HestiaCP"
  must not be used for derivatives. This is why the user visible product name is VylarisSpace. Package
  names (`hestia`, `hestia-nginx`, ...) and paths are internal identifiers and remain; whether publishing a
  repository with packages called `hestia` is acceptable should be part of the same review.
- A repository (even a private one) that serves packages under the same names as the upstream ones
  can collide on systems that also have the upstream source. The apt pin from section 2 reduces that risk.

## Build requirements added in the VylarisSpace changes

The two-factor QR code is now generated locally with the pure PHP library `bacon/bacon-qr-code` (BSD-2-Clause, together with `dasprid/enum`), so the secret never leaves the server. The package build therefore has to:

- run `composer install --no-dev` in `web/inc` so that `vendor/` contains these libraries (the folder is not tracked in git);
- build `hestia-php` with the `iconv` and `xmlwriter` extensions, which the library needs. Do not use configure flags that disable default extensions.

## 11. Work items

Effort is a rough guess for one person who knows the build scripts.

### Decisions

- [ ] Public or private repository, host name, who pays for hosting (0.5 day, owner)
- [ ] Versioning: confirm base version plus `--pkgrev 100`, no epoch (0.5 day)
- [ ] Maintainer name and address for the Debian control files (0.5 day, owner)
- [ ] Supported distribution matrix (Debian 12/13, Ubuntu 22.04/24.04; arm64 yes or no) (0.5 day)
- [ ] Legal review of distribution and trademark points in section 10 (external)

### Build and infrastructure

- [ ] Generate the signing key, revocation certificate, offline backup of the primary key (0.5 day)
- [ ] Set up the repository host: reprepro configuration for four suites, web server, optional auth (1 day)
- [ ] Make `src/hst_autocompile.sh` usable for the private fork: `~localsrc` only, remove raw/archive downloads (1 day)
- [ ] CI workflow: 8 native jobs, artifact upload, publish job, staging and promotion (3 to 4 days)
- [ ] Native arm64 builders or accept slow QEMU builds (0.5 day, depends on CI provider)
- [ ] Smoke test job: install the debs in clean containers with `--with-debs`, run bats tests (2 days)
- [ ] Source archive publishing (`sources/` with tarballs of the commit and third-party sources) (1 day)
- [ ] First full build and publish of 1.10.5-100 for all targets (1 to 2 days with fixes)

### Installers and scripts

- [ ] Installers: own `RHOST`, key import, token support, pin file, version check, launcher (2 to 3 days)
- [ ] Replace `install/deb/deb_signing.key` with the new public key (0.5 hour)
- [ ] Own update script and cron (`v-update-sys-vylaris` plus add/delete cron and panel wiring) (2 days)
- [ ] Decide the key name for the own channel (for example `VYLARIS_UPDATES`) and add it to
      `bin/v-list-sys-config`, `func/syshealth.sh`, `bin/v-change-sys-config-value` (0.5 day)
- [ ] Update `bin/v-update-sys-ip` to a neutral IP lookup (0.5 hour)
- [ ] Test an upgrade from a server installed with `--with-debs` to the first repository build (1 day)

### Operations

- [ ] Upstream watch: subscribe to releases and security advisories, define who reads them (0.5 day setup)
- [ ] Merge routine for upstream tags, including the branding check list from section 9 (1 day to
      write down, then about 1 day per upstream release)
- [ ] Component watch for nginx, PHP, OpenSSL, PCRE, zlib, Node.js with a rebuild policy (0.5 day)
- [ ] Key rotation and token rotation runbook (0.5 day)
- [ ] Rollback runbook (`apt install hestia=<version>`, keeping two builds) (0.5 day)
