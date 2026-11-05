# VylarisSpace package repository

Status: **stage 1 (hybrid) is implemented, nothing has run on production infrastructure yet.** The own
apt repository carries one package, `hestia` (the panel). `hestia-nginx`, `hestia-php` and
`hestia-web-terminal` still come from the upstream HestiaCP apt repository, signed by upstream, and are
updated from it by the normal system `apt upgrade` (section 8). Building those three is stage 2 and is
still a plan (section 13).

What has been verified so far, and what has not, is listed in [Verification status](#verification-status).

## Why this exists

- The package `hestia` has the same name and the same base version (`src/deb/hestia/control`: 1.10.5) as
  the upstream package. Any upstream release above it would replace the fork on a server that still has
  the upstream source list. The upstream package contains the upstream interface, not VylarisSpace.
- Therefore the own repository serves `hestia` with a higher package revision, and every server pins
  `hestia` to the host of the own repository (section 2 and `/etc/apt/preferences.d/vylarisspace`).
- All upstream update channels are off by default (`UPSTREAM_UPDATES='no'` in `hestia.conf`). Updates
  come through the own channel (`VYLARIS_UPDATES`, section 8).
- The panel web server (`hestia-nginx`) and PHP (`hestia-php`) are security relevant and are only patched
  through new package builds. Until stage 2 exists the owner depends on upstream for those three
  packages and nobody patches them if upstream stops.

## Where things are

| Topic                                        | File                                                                                                                                             |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Build the `hestia` package                   | `src/hst_autocompile.sh` (`--hestia`, `~localsrc`, `--pkgrev`)                                                                                   |
| Bundled PHP dependencies (`web/inc/vendor`)  | `bundle_php_vendor` in `src/hst_autocompile.sh`, `bin/v-add-sys-dependencies` (skips a complete vendor)                                          |
| Signing key, repository, publish, rollback   | `src/vylaris/` (`make-signing-key.sh`, `repo-init.sh`, `repo-publish.sh`), see its `README.md`                                                   |
| Trust the repository on a server, the pins   | `src/vylaris/client-setup.sh`, written to `/etc/apt/preferences.d/vylarisspace`                                                                  |
| Installers (refuse without a package source) | `install/hst-install.sh`, `install/hst-install-debian.sh`, `install/hst-install-ubuntu.sh`                                                       |
| Own update path                              | `bin/v-update-sys-vylaris`, `bin/v-add-cron-vylaris-autoupdate`, `bin/v-delete-cron-vylaris-autoupdate`, `web/update/vylaris/`, the Updates page |
| Configuration keys                           | `UPSTREAM_UPDATES` (stays `no`), `VYLARIS_UPDATES` (`yes` when a repository was configured)                                                      |
| CI build and publish                         | `.github/workflows/build-packages.yml`                                                                                                           |

## 1. What to build

`src/hst_autocompile.sh` builds four Debian packages. Stage 1 uses only the first row.

| Package               | Content                                                                                                 | Built per                                | Source of the version                  | Stage |
| --------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------- | -------------------------------------- | ----- |
| `hestia`              | `bin`, `func`, `install`, `web` (JS and CSS built with `npm ci && npm run build`, PHP `vendor` bundled) | distro suffix and architecture           | `src/deb/hestia/control` (1.10.5)      | 1     |
| `hestia-nginx`        | backend nginx compiled with OpenSSL, PCRE and zlib sources                                              | distro and architecture (native compile) | `src/deb/nginx/control` (1.30.6)       | 2     |
| `hestia-php`          | backend PHP-FPM compiled from source, depends on distro libraries (libzip, onig)                        | distro and architecture (native compile) | `src/deb/php/control` (8.5.12)         | 2     |
| `hestia-web-terminal` | Node.js websocket terminal                                                                              | distro and architecture                  | `src/deb/web-terminal/control` (1.0.6) | 2     |

Notes on the build script:

- The `hestia` package is built from the checked out tree with the branch name `~localsrc`. Nothing is
  downloaded from a git hosting service for it. Without `~localsrc` the `--hestia` target refuses to
  build unless `HESTIA_SRC_REPO` names a repository you control.
- The version is `<base>-<pkgrev>+<distro><release>`, for example `1.10.5-100+ubuntu24.04`. The suffix is
  read from `lsb_release` of the machine that builds (`get_distro_suffix`, `apply_distro_version`). The
  contents of the package are the same for every distribution; only the `control` file differs.
  `--cross` makes the script write the package for every known suffix and both architectures in one
  run. That mode exists in the script for `--hestia` but has not been used for the repository yet.
- The package contains `web/inc/vendor` and `web/src/vendor` (composer, no dev packages), so customer
  servers need no network access for it. The build host needs `composer` and network access: composer
  fetches the libraries from Packagist and GitHub **at build time**, never at runtime on a server.
  Development files and Markdown documentation of the libraries (tests, docs, examples, `*.md`, git and
  editor settings) are removed from the package; licence files (`LICENSE*`, `COPYING*`) stay.
- `--pkgrev <n>` is the revision (default 1, **use 100 or higher**), `--release <id>` appends `~<id>` for
  CI builds. The deb files and a `SHA256SUMS` file are written to `$DEB_DIR`
  (default `/tmp/hestiacp-src/deb`).
- Stage 2 targets download third-party sources. Their locations can be overridden with environment
  variables (`NGINX_DIST_BASE`, `PHP_DIST_BASE`, `OPENSSL_DIST_BASE`, `PCRE_DIST_BASE`, `ZLIB_DIST_BASE`);
  the versions are pinned in the script (`OPENSSL_V`, `PCRE_V`, `ZLIB_V`, nginx and PHP versions). A new
  OpenSSL, PCRE or zlib release needs a rebuild of `hestia-nginx` by the owner.
- `src/deb/hestia/postinst` strips the version suffix with
  `sed -E 's/-[0-9]{1,}\+[a-z0-9\.]{1,}//'` before it compares versions. The suffix must therefore keep
  the shape `-<digits>+<letters or digits or dots>`. Do not put an extra `+vylaris` part into the
  version, it would break that parsing.
- **Open (owner decision):** `Maintainer` and `Homepage` in the four `control` files still name upstream.
  A Debian package needs a Maintainer. The field is only visible in `apt show`. Nothing was changed
  because the owner has not provided a name and address.

## 2. Versioning

Rules to decide and then never change:

1. Keep the upstream base version in the package version (`1.10.5`) so that the upgrade scripts in
   `install/upgrade/versions/` (named after versions) keep working, and use the package revision for
   own releases: `1.10.5-100+ubuntu24.04`, next own build `1.10.5-101+ubuntu24.04`.
2. Start the revision at 100. A VylarisSpace build of a given upstream version is then always greater
   than upstream's own build of that version (`1.10.5-1+...`).
3. Never go below upstream. When upstream releases 1.10.6 and it is merged, the fork's package becomes
   `1.10.6-100+...`.
4. Own migration steps that are not part of an upstream release can use a fourth component
   (`1.10.5.1`): the upgrade loop in `func/upgrade.sh` compares four numeric fields. Check this with a
   test upgrade before relying on it.
5. Epoch: do not add one. An epoch (`1:1.10.5-...`) can never be removed again. It is only needed if the
   fork wants to renumber below upstream. Decide this before the first public build; the recommendation
   is to keep the upstream numbering.
6. Pre-releases for CI use `--release`, for example `1.10.5-101+ubuntu24.04~ci42`. Because `~` sorts
   before the empty string, CI builds never win over a final build.
7. **Pins (implemented):** `/etc/apt/preferences.d/vylarisspace` has four stanzas for the package
   `hestia`, in this order, because apt uses the **first** stanza that matches:

   | #   | Pin                                                    | Priority |
   | --- | ------------------------------------------------------ | -------- |
   | 1   | `origin apt.hestiacp.com` (upstream, by host)          | -1       |
   | 2   | `release o=apt.hestiacp.com` (upstream, by its Origin) | -1       |
   | 3   | `origin REPO_HOST` (the own repository host)           | 1001     |
   | 4   | `origin *` (every other source)                        | -1       |

   `REPO_HOST` is the host name of the own repository. A `file://` test repository has no host and uses
   an empty origin (`Pin: origin ""`). The pin is bound to the **host**, not to the path or port and not
   to the `Origin` field of the Release file, because any repository can claim `Origin: VylarisSpace`.
   Consequences:

   - The host of the own repository has to be **dedicated to this repository**. Any other repository
     served from the same host would be trusted for the package `hestia`.
   - Moving the repository to a new host requires running `src/vylaris/client-setup.sh` again on every
     server (it rewrites the source list and the pin). If only the source list is changed, the pin no
     longer matches and `v-update-sys-vylaris` fails closed (`pin_ok=no`).
   - The pins steer the candidate version and upgrades. An explicit `apt-get install hestia=VERSION`
     still installs from a blocked source (apt behaviour), as does `dpkg -i`.

   `apt-mark hold hestia` is not enough, the legacy upstream update script runs `apt-get install hestia`
   explicitly. The details and the checks that were run are in `src/vylaris/README.md`, section 5.

## 3. Repository tooling

Decision: `reprepro` (small, declarative, plain directory tree that any static web server can serve).
`aptly` (snapshots, REST API, more moving parts) is the alternative if staged promotion becomes more
important than it is now. The staging and promotion flow exists with `reprepro` too: a
`<codename>-staging` suite and `repo-publish.sh --promote`.

Implemented in `src/vylaris/`: `repo-init.sh` (layout, four suites, public key, nginx sample),
`repo-publish.sh` (signature chain verification, last 3 builds for rollbacks, source archive, promote and
rollback modes). Layout:

```text
<repo-dir>/             # directory name and host name are the owner's choice
  conf/ db/ logs/ archive/    private
  public/dists/<codename>/main/binary-amd64|arm64/
  public/pool/main/h/hestia/...
  public/pubkey.gpg     # new VylarisGroupEurope public key (binary), pubkey.asc armored
  public/sources/       # source archives that belong to the published binaries (GPL note)
```

Suites: `bookworm`, `trixie`, `jammy`, `noble`, each with an optional `<codename>-staging`.

## 4. Signing key

- `src/vylaris/make-signing-key.sh` creates a **new** key pair. Do not reuse `install/deb/deb_signing.key`,
  it is upstream's public key and installing it would trust upstream's key for the own repository.
- Primary key (certify only) and signing subkey, ed25519, expiry 2 years, revocation certificate. The
  primary key is meant to live offline; the repository host only gets a home with the signing subkey.
- No key is stored in the git repository. The private key is created on the owner's infrastructure by
  running the script.
- On servers the public key is installed to `/usr/share/keyrings/vylarisspace-keyring.gpg` and referenced
  with `signed-by=` in `/etc/apt/sources.list.d/vylarisspace.list`. No `apt-key`, nothing in
  `trusted.gpg.d`.
- Rotation and compromise handling: `src/vylaris/README.md`, section 8. The key expires after 2 years and
  servers reject an expired key, so put the date into a calendar.
- **Open:** replace `install/deb/deb_signing.key` in the repository by the new public key once it
  exists, and optionally ship the keyring inside the `hestia` package so that a key renewal reaches the
  servers.

## 5. Hosting: private or public

| Aspect    | Public repository                                         | Private repository                                                                                                                     |
| --------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Access    | Anyone can install, simplest for customers                | Per-customer or per-server token                                                                                                       |
| GPL       | Anyone can obtain the binaries, publish source as well    | Binaries still go to third parties, same duties apply (see section 10)                                                                 |
| Operation | Static files on any web server or object storage with CDN | Web server with basic auth or token check in front of the same static files                                                            |
| apt side  | Nothing special                                           | `/etc/apt/auth.conf.d/vylarisspace.conf` (`machine <host> login <user> password <token>`, mode 600, root; `client-setup.sh` writes it) |
| Risk      | Version and package metadata public                       | Tokens on customer servers, rotation and revocation process needed                                                                     |

Recommendation: a private repository with per-server tokens while the product is young, built so that it
can be opened later by removing the auth rule. HTTPS only. The signature protects the content, the token
only controls who can download. `repo-init.sh` writes an nginx sample for this
(`nginx-vylarisspace-repo.conf.sample`). **Open (owner decision):** host name, public or private,
who pays for hosting, TLS certificate.

## 6. CI build matrix

Targets that `src/hst_autocompile.sh` knows: Debian 11, 12, 13 and Ubuntu 22.04, 24.04, 26.04. The
repository tooling supports Debian 12 and 13 and Ubuntu 22.04 and 24.04.

| Distribution | Codename   | amd64                      | arm64                |
| ------------ | ---------- | -------------------------- | -------------------- |
| Debian 12    | `bookworm` | prepared, not active       | prepared, not active |
| Debian 13    | `trixie`   | prepared, not active       | prepared, not active |
| Ubuntu 22.04 | `jammy`    | prepared, not active       | prepared, not active |
| Ubuntu 24.04 | `noble`    | **active** in the workflow | prepared, not active |

`.github/workflows/build-packages.yml` implements stage 1:

- Triggers: manual run (`workflow_dispatch` with the inputs `pkgrev`, `branch` and `target`) and a push of
  a tag `v*`. A tag `v1.10.5-100` builds revision 100; the base version of the tag has to equal
  `src/deb/hestia/control`. Revisions below 100 are refused.
- Job `build-hestia` (Ubuntu 24.04 runner): checkout, Node.js 24 (the version `hst_autocompile.sh`
  installs; the repository has no `engines` field or `.nvmrc`), Composer, then
  `bash src/hst_autocompile.sh --hestia --noinstall --keepbuild --pkgrev <n> "~localsrc"`. It checks the
  result (package name, exact version, `web/inc/vendor/autoload.php`, the QR code library and the theme
  file inside the deb), writes `SHA256SUMS` and uploads the deb as an artifact (30 days).
- Job `publish` runs only when the repository variable `VYLARIS_PUBLISH` is `true`. It copies the debs and a
  checkout of the commit to the repository host over SSH (rsync) and runs `src/vylaris/repo-publish.sh`
  there. Pushed tags and runs without an explicit choice publish to the `<codename>-staging` suites;
  only a manual run with `target: live` publishes into the real suites.
- Secrets (repository or environment `vylaris-repo`): `REPO_SSH_KEY`, `REPO_KNOWN_HOSTS` (host key lines,
  the host is verified, not scanned), `REPO_HOST`, `REPO_USER`, `REPO_PATH` (repository directory made by
  `repo-init.sh`), optional `REPO_GNUPGHOME` (signing home on the host). The debs and the source
  checkout land in `<REPO_PATH>-incoming/<run id>/` next to the repository directory and are removed
  after the publish. No host name, key or URL is in the file.
- Permissions are `contents: read`. Third-party actions are referenced by major version tag
  (`actions/checkout@v7`, `actions/setup-node@v7`, `actions/upload-artifact@v4`,
  `actions/download-artifact@v4`), not by commit SHA, because the SHAs cannot be verified offline.
  Pin them when the file is reviewed on a connected machine.

Why only `noble` is active: the version suffix comes from `lsb_release` of the build machine. `jammy` has
a runner image; Debian needs a `container: debian:12` / `debian:13` (with git, ca-certificates, sudo and
`lsb-release` installed first); arm64 needs native arm64 runners, which are paid larger runners for
private repositories. The commented matrix entries in the workflow carry these reasons.

Still to do for the CI (stage 2 sizes this up): a smoke test job that installs the deb in a clean
container and runs the bats tests, source archive publishing for third-party sources, caching of
`src/archive/`. A full native build of nginx and PHP takes about 30 to 60 minutes per distribution and
architecture.

## 7. Installers and scripts

Implemented (`install/hst-install.sh`, `install/hst-install-debian.sh`, `install/hst-install-ubuntu.sh`):

- **Safe default.** Without `--vylaris-repo` (or `VYLARIS_REPO_URL`) or `--with-debs`, the installers stop
  before they change anything and print why: they would otherwise install the upstream `hestia` package.
  `--allow-upstream-hestia` (developers only) overrides this and prints a warning. It cannot be combined
  with `--vylaris-repo`. With `--allow-upstream-hestia` no pin file is written.
- **Options.** The installers read long options and the short forms in brackets (give the value as a
  separate argument):

  | Option                                         | Environment variable              | Meaning                                                               |
  | ---------------------------------------------- | --------------------------------- | --------------------------------------------------------------------- |
  | `--vylaris-repo URL` (`-R`)                    | `VYLARIS_REPO_URL`                | Own repository, `https://REPO_HOST[:port]/REPO_PATH`, no default host |
  | `--vylaris-key URL_OR_FILE` (`-K`)             | `VYLARIS_REPO_KEY`                | Public key, default `REPO_URL/pubkey.gpg`                             |
  | `--vylaris-key-fingerprint FINGERPRINT` (`-F`) | `VYLARIS_REPO_KEY_FPR`            | Primary key fingerprint, required for a key that is downloaded        |
  | `--vylaris-repo-auth USER:PASSWORD` (`-A`)     | `VYLARIS_REPO_AUTH`               | Login for a private repository, prefer the environment variable       |
  | `--allow-insecure-http` (`-I`)                 | `VYLARIS_ALLOW_INSECURE_HTTP=yes` | Accept an `http://` repository, tests on trusted networks only        |
  | `--with-debs DIRECTORY` (`-D`)                 |                                   | Install `hestia_*.deb` built from this source                         |
  | `--allow-upstream-hestia` (`-U`)               |                                   | Developers only, installs the upstream `hestia` package               |

  The suite is the codename of the server; the environment variable `VYLARIS_REPO_SUITE` overrides it
  (for example for a staging suite).

- **Key trust.** https is required. A key that is downloaded (the default is `REPO_URL/pubkey.gpg`)
  needs the fingerprint of its **primary** key. How to get it: on the owner's machine run
  `gpg --show-keys --with-fingerprint pubkey.asc` and publish the fingerprint out of band. A key given as
  a local file may omit the fingerprint, the installer then prints it as not verified. The key file must
  contain exactly one primary key and no secret key, and the key must not be expired or revoked: the
  installer refuses otherwise.
- **Credentials.** `VYLARIS_REPO_AUTH` is read once, written to `/etc/apt/auth.conf.d/vylarisspace.conf`
  (mode 600) and removed from the environment. It is only sent over https to the exact same host and
  port as the repository; plain http with credentials is refused. `-A` / `--vylaris-repo-auth` is visible
  in the process list while the installer runs (a warning is printed), prefer the environment variable.
  Tracing (`bash -x`) is switched off when credentials may be present. Error messages mask the user info
  of a URL.
- **Order of the checks.** The local checks run first and change nothing: package source given, URL,
  http opt-in, fingerprint format, credential format, a local key file (when `gpg` is already
  installed). The checks that need the network happen later, after `apt-get update` and the installation
  of the installer dependencies (`curl`, `gnupg`, ...): download of the key, the fingerprint of a
  downloaded key, expiry of a downloaded key, and the presence of the suite for this distribution. A
  refusal there leaves the installer dependencies, the apt retry setting and the log directory behind,
  but the apt configuration of the own repository (key, source list, pins, credentials) is not written
  yet.
- They then write the keyring, `/etc/apt/sources.list.d/vylarisspace.list`, the pins in
  `/etc/apt/preferences.d/vylarisspace` (section 2, rule 7; the pins are written before the upstream
  source list and before any `apt-get install hestia`) and, with credentials,
  `/etc/apt/auth.conf.d/vylarisspace.conf`. If apt cannot read the repository or the candidate for
  `hestia` does not come from it, the source list, keyring and credentials are removed again and the
  installer stops.
- `--with-debs <dir>` still installs `hestia_*.deb` built from this source (offline installs, tests). The
  pin file then has the upstream and catch-all stanzas only, and `VYLARIS_UPDATES` is `no`.
- The upstream `release` version check is gone. `hst-install.sh` no longer downloads the installer
  from upstream; it uses the installer next to it or stops with a message.
- `hestia.conf` gets `UPSTREAM_UPDATES='no'` and `VYLARIS_UPDATES='yes'` when a repository was configured
  (`'no'` with `--with-debs`). The daily upstream update cron is not installed.

Still open:

- `install/deb/deb_signing.key` is upstream's public key (section 4).
- `src/deb/*/control`: `Maintainer` and `Homepage` (section 1).
- `src/hst_bootstrap_install.sh`, `src/lxd_compile.sh`: they point to the upstream repository. They are not
  used by stage 1; retire them or point them to the fork.
- `bin/v-update-sys-ip` asks a neutral third party for the public IP (`api.ipify.org`). Replace it by an own
  endpoint if that is wanted.
- Stage 1 pulls `hestia-nginx`, `hestia-php`, `hestia-web-terminal` from the upstream repository
  (`RHOST` in the installers), signed by the upstream key which the installers fetch from that host.
  Until stage 2 the upstream repository is a trusted root for those three packages (see section 8).

## 8. How updates work

1. `UPSTREAM_UPDATES='no'` stays. It means "never talk to upstream", it does not mean "no updates".
2. `VYLARIS_UPDATES` (default `no`, installers set `yes` when a repository was configured) switches the own
   channel. The key is listed by `v-list-sys-config` and accepted by `v-change-sys-config-value`.
3. **The two channels exclude each other.** `v-change-sys-config-value` refuses to set `UPSTREAM_UPDATES`
   to `yes` while `VYLARIS_UPDATES` is `yes`, and the other way round. `v-update-sys-hestia-git` refuses
   to run while `VYLARIS_UPDATES` is `yes`, because it installs the built package with `dpkg -i`, which
   ignores the pins. In hybrid mode the upstream update buttons of the panel are intentionally not
   available.
4. `bin/v-update-sys-vylaris [install|check|background|status]` does nothing unless `VYLARIS_UPDATES` is
   `yes`. **It first checks the pin file** `/etc/apt/preferences.d/vylarisspace`: it must contain exactly
   the four stanzas of section 2, rule 7, in that order, with the host of the own source list in the
   third stanza. If the file is missing or was edited, every mode except `status` refuses (exit code 10,
   message, entry in the system log). Restore the file by running `src/vylaris/client-setup.sh` again.
   `status` needs no network and prints key=value lines: `source`, `pin_ok=yes|no`, `installed`,
   `candidate`, `origin` and `available`. `pin_ok` only describes the file `/etc/apt/preferences.d/vylarisspace`; it does not detect conflicting pins in other apt preference files. The check that the candidate is offered by the own source only still applies.
5. With an intact pin file, `install` and `check` run `apt-get update` for the own source list only
   (`/etc/apt/sources.list.d/vylarisspace.list`), `install` then runs `apt-get install --only-upgrade`
   for the exact candidate version. It installs only a candidate that is newer than the installed
   version (otherwise it reports up to date, exit code 0) and that is offered by the own source only
   (otherwise it refuses with exit code 10), writes
   `$HESTIA/log/vylaris-update.log` and uses the usual `v-*` exit codes (`0` ok, `2` invalid mode, `3`
   package or source missing, `10` refused, `19` update failed). `background` runs it as a separate system
   unit so that the restart of the panel at the end of the upgrade cannot interrupt it. Only one update
   runs at a time.
6. `bin/v-add-cron-vylaris-autoupdate` and `bin/v-delete-cron-vylaris-autoupdate` add and remove a daily
   cron job (switching `VYLARIS_UPDATES` to `no` removes it). The Updates page of the panel shows the
   installed and the available version from the own repository and offers "Check for Updates" and
   "Update Now" (and the automatic update toggle) when `VYLARIS_UPDATES` is `yes`. The legacy upstream
   scripts keep their kill switch.
7. The `hestia` package `postinst` runs the upgrade scripts (`func/upgrade.sh`) and the system health
   check (`func/syshealth.sh`), so key migrations ship with the package.
8. Rollout order for a new version: staging suite, one test server, promote. The last three builds are kept
   in `archive/` so that a rollback is possible (`src/vylaris/README.md`, section 7).
9. **Stage-1 trade-off: the other three packages.** `v-update-sys-vylaris` moves `hestia` only. The
   packages `hestia-nginx`, `hestia-php` and `hestia-web-terminal` are not in the own repository and
   are **not pinned**: the pins block the package `hestia` only. They receive their updates from the
   upstream repository through the normal system `apt upgrade`, signed by the upstream key. The default
   unattended-upgrades setup of the installers does not cover the upstream Hestia repository unless an
   administrator adds an origin pattern for it. That is a trade-off of stage 1, not a safe end state: the upstream
   repository stays a trusted root for the panel's web server, PHP and terminal, and these packages
   change when upstream publishes, not when the owner decides. Removing this dependency is the reason
   stage 2 (section 13) exists.

## 9. Keeping up with upstream security fixes

Upstream HestiaCP stays the source of fixes for the panel code. The owner is responsible for merging them.

- Remote: `git remote add upstream https://github.com/hestiacp/hestiacp.git`.
- What to watch: release tags (`v1.x.y`) and the `release` branch, the GitHub Security Advisories of
  `hestiacp/hestiacp`, and `CHANGELOG.md`. A subscription to the repository's releases (watch
  "Releases only" and security advisories) is enough; a weekly review is the minimum.
- Also watch the components upstream builds into `hestia-nginx`, `hestia-php` and `hestia-web-terminal`:
  nginx, PHP, OpenSSL, PCRE, zlib and Node.js (versions in `src/hst_autocompile.sh` and
  `src/deb/*/control`). In stage 1 their fixes come from upstream's repository; once upstream stops
  or once stage 2 starts, a fix there needs a new build by the owner.
- Merge procedure:
  1. `git fetch upstream --tags`
  2. `git checkout -b merge/upstream-v1.x.y vylaris-webspace`
  3. `git merge v1.x.y` (or cherry-pick single security commits for urgent fixes)
  4. Resolve conflicts. Expect them in the branded files: installers, `web/templates/**`,
     `web/inc/helpers.php`, `web/css/src/themes/**`, `func/syshealth.sh`, `func/upgrade.sh`,
     `bin/v-update-sys-*`, `src/hst_autocompile.sh`, `src/deb/*/control`, `README.md`.
  5. Re-run the branding checks: grep the user-visible spots (UI strings, mails, installer banners)
     for new upstream names or links, check `UPSTREAM_UPDATES` is still honoured by every script that
     downloads (`grep -rn "hestiacp\.com\|github.com/hestiacp\|raw.githubusercontent" bin func`), and rebuild
     CSS/JS (`npm ci && npm run build`).
  6. Update `src/deb/*/control` base versions to the merged versions, build with `--pkgrev 100`, run the
     tests, publish to staging, then promote.
- Keep merges small and frequent. A long divergence makes security merges risky.

## 10. GPL and distribution note (needs legal review)

This is a list of points to bring to a lawyer, not legal advice and not a conclusion.

- The project is GPL-3.0-or-later. `VYLARIS.md` treats use on the owner's own servers as private use.
  Handing packages to customers, or letting customers' servers download them from a repository the owner
  operates, may count as conveying the program to third parties. If so, the obligations of the GPL
  apply: license text and notices stay in the package, and the Corresponding Source for the exact
  binaries must be offered (accompanying source, or a written offer, or a public source repository).
- `repo-publish.sh` stores a source archive of the exact commit next to every published build
  (`public/sources/`, with `SHA256SUMS`) and refuses to publish from a dirty checkout. Whether the source
  offer pointing there is sufficient is part of the legal review.
- Operating the panel on servers the owner controls and giving customers access to the web interface is a
  different situation from giving them the packages. Which of the two applies to each customer contract
  should be clarified.
- The package also contains PHP libraries from composer (`web/inc/vendor`, for example
  `bacon/bacon-qr-code`, BSD-2-Clause) and built web assets, each with its own license. Stage 2 adds nginx,
  PHP, OpenSSL, PCRE, zlib and Node.js modules (see `src/deb/*/copyright`); their source archives would
  need to be kept and offered with the binaries.
- Own modifications stay under GPL-3.0-or-later. Keep `LICENSE`, file headers and vendor notices. The
  credits stay in `NOTICE` and `VYLARIS.md`.
- Trademark: the upstream `README.md` states that the name and logo "Hestia Control Panel" and "HestiaCP"
  must not be used for derivatives. This is why the user visible product name is VylarisSpace. Package
  names (`hestia`, `hestia-nginx`, ...) and paths are internal identifiers and remain; whether publishing
  a repository with packages called `hestia` is acceptable should be part of the same review.
- A repository (even a private one) that serves packages under the same names as the upstream ones can
  collide on systems that also have the upstream source. The pins reduce that risk.

## 11. Build requirements for the panel package

The two-factor QR code is generated locally with the pure PHP library `bacon/bacon-qr-code` (BSD-2-Clause,
together with `dasprid/enum`), so the secret never leaves the server. The package build therefore:

- runs `composer install --no-dev` in `web/inc` and `web/src` (done by `bundle_php_vendor`; composer needs
  network access to Packagist and GitHub on the **build host**, at build time only), so that `vendor/` is
  inside the package (the folders are not tracked in git). Git metadata, tests, docs, examples,
  Markdown files and editor or git settings of the libraries are removed; licence files stay. `bin/v-add-sys-dependencies`
  recognises a complete vendor (every package of `composer.lock` in the locked version) and then neither
  runs Composer nor needs the network. On a source install, or with an incomplete vendor, it works as
  before.
- needs a PHP with the `iconv` and `xmlwriter` extensions on the server, which the library uses. In stage 1
  the PHP is upstream's `hestia-php`. This was **not checked** against the real upstream package: after
  the first install run `/usr/local/hestia/php/bin/php -m | grep -E 'iconv|xmlwriter'` and open the 2FA
  setup page. In stage 2 do not use configure flags that disable default extensions.

## 12. First release walkthrough

Hosts: **B** build machine (root, Ubuntu 24.04 for `noble`, with Node.js, `composer`), **R** repository
host, **S** a fresh server. The example values (`/srv/vylarisspace-repo`, `/root/vylaris-...`) are only
examples. Replace `REPO_HOST` and `REPO_PATH` with your own choice and `PRIMARY_FINGERPRINT` with the
fingerprint of your primary key; there is no default host. Use a host name that serves only this
repository (section 2, rule 7).

1. **Make the signing key (once, on a machine you control, outside the git checkout).**

   ```bash
   umask 077
   printf '%s\n' 'a long random passphrase' > /root/vylaris-key.pass
   src/vylaris/make-signing-key.sh --passphrase-file /root/vylaris-key.pass \
   	--signing-home /root/vylaris-sign-gnupg /root/vylaris-key-out /root/vylaris-gnupg
   ```

   Back up `/root/vylaris-key-out` offline, then remove the primary key. Note the fingerprint it prints
   and the expiry date. Use `src/vylaris/README.md`, section 1, for the details.

2. **Initialise the repository on R.**

   ```bash
   export GNUPGHOME=/root/vylaris-sign-gnupg
   export VYLARIS_SIGN_KEY=PRIMARY_FINGERPRINT
   src/vylaris/repo-init.sh --staging --server-name REPO_HOST /srv/vylarisspace-repo
   ```

   Serve `/srv/vylarisspace-repo/public` over https with the generated nginx sample (section 4 of
   `src/vylaris/README.md`).

3. **Build the package on B**, from a clean checkout of the commit to release.

   ```bash
   bash src/hst_autocompile.sh --hestia --noinstall --keepbuild --pkgrev 100 '~localsrc'
   ls /tmp/hestiacp-src/deb # hestia_1.10.5-100+ubuntu24.04_amd64.deb and SHA256SUMS
   ```

   Or let CI do it: push the tag `v1.10.5-100` (or start the workflow `Build packages`) and download the
   artifact. Build once per distribution and architecture.

4. **Publish to staging, then promote.** On R, with the checkout the package was built from (clean working
   tree, so that the matching source archive is stored):

   ```bash
   src/vylaris/repo-publish.sh --suite noble-staging /srv/vylarisspace-repo hestia_1.10.5-100+ubuntu24.04_amd64.deb
   # test it on one server (step 5, with --suite noble-staging), then:
   src/vylaris/repo-publish.sh --promote /srv/vylarisspace-repo noble
   ```

   With the CI publish job the first command is done for you (enable it with the repository variable
   `VYLARIS_PUBLISH=true` and the secrets from section 6).

5. **Install on a fresh server S.** Copy `install/hst-install.sh` and `install/hst-install-ubuntu.sh` (or
   `-debian.sh`) from the source tree to the server, and run as root:

   ```bash
   VYLARIS_REPO_AUTH=SERVER_USER:SERVER_TOKEN \
   	bash hst-install.sh \
   	--vylaris-repo https://REPO_HOST/REPO_PATH \
   	--vylaris-key-fingerprint PRIMARY_FINGERPRINT \
   	--email ADMIN_EMAIL
   ```

   `PRIMARY_FINGERPRINT` is the 40 digit fingerprint of the primary key. Get it on the machine that made
   the key (`make-signing-key.sh` prints it, or `gpg --show-keys --with-fingerprint pubkey.asc`) and
   give it to the server out of band, never from the repository server itself. Without
   `--vylaris-repo` (or `--with-debs`) the installer refuses to install. `VYLARIS_REPO_AUTH` (use the
   environment, not `--vylaris-repo-auth`) is only needed for a private repository. A repository over
   plain http is refused unless `--allow-insecure-http` is added (tests on trusted networks only).
   Alternatively pass a key file that you received on a trusted channel with `--vylaris-key KEY_FILE`;
   then the fingerprint may be left out and the installer prints it for you to compare.

6. **Verify on S.**

   ```bash
   apt-cache policy hestia                                                  # candidate 1.10.5-100+ubuntu24.04, priority 1001, from the own repository
   grep -E '^(UPSTREAM|VYLARIS)_UPDATES' /usr/local/hestia/conf/hestia.conf # no / yes
   cat /etc/apt/preferences.d/vylarisspace                                  # four stanzas, the third names REPO_HOST
   /usr/local/hestia/bin/v-update-sys-vylaris status                        # pin_ok=yes, origin=own
   /usr/local/hestia/php/bin/php -m | grep -E 'iconv|xmlwriter'
   ```

   Log in to the panel: the interface must be VylarisSpace, not the upstream one.

7. **Update from the panel.** Build and publish `--pkgrev 101`, then on S either wait for the daily cron
   (`v-add-cron-vylaris-autoupdate`), run `v-update-sys-vylaris check` and `v-update-sys-vylaris`, or open
   the Updates page of the panel and use "Check for Updates" and "Update Now" (offered when
   `VYLARIS_UPDATES` is `yes`). `apt-cache policy hestia` then shows the new version.

## 13. Stage 2: own `hestia-nginx`, `hestia-php`, `hestia-web-terminal` (plan)

Not implemented. It replaces the last dependency on the upstream repository.

- Build natively per distribution and architecture: eight jobs for the four suites and two
  architectures, in containers of the target distribution on x86-64 runners and native arm64 runners.
  `--cross` is not supported for `hestia-nginx` and `hestia-php`. Compiling under QEMU
  (`src/chroot_build_all.sh`, `src/lxd_build_all.sh`) works but is slow and memory heavy.
- Effort: roughly 30 to 60 minutes per job for nginx plus PHP, so a full release is several runner hours;
  plan 3 to 4 days to extend the workflow, one to two days for the first full build with fixes, and the
  ongoing work to rebuild whenever nginx, PHP, OpenSSL, PCRE, zlib or Node.js publish a fix.
- Publish with `repo-publish.sh --allow-other-packages`; the reprepro configuration and the pins need
  stanzas for the three package names, and `client-setup.sh` and the installers must stop adding the
  upstream source list (`RHOST`).
- `hestia-php` must keep `iconv` and `xmlwriter`.
- Collect the source archives of nginx, PHP, OpenSSL, PCRE, zlib and the Node.js modules for the GPL
  source offer (`public/sources/`).
- After stage 2 the installers need no upstream host at all.

## Verification status

Verified in the sandbox, with throw-away keys and no network host of the owner:

- The `hestia` package was built with the documented command from a copy of the tree
  (`hestia_1.10.5-100+ubuntu24.04_amd64.deb`, contains `web/inc/vendor` with `bacon-qr-code` and the
  theme files). The checks of the CI build job were run against it.
- With a throw-away key: `make-signing-key.sh`, `repo-init.sh --staging`, the publish step of the CI
  workflow (its remote script, run locally), `repo-publish.sh --promote`, `client-setup.sh`. In an
  Ubuntu 24.04 container `client-setup.sh --update` and `apt-cache policy hestia` showed the candidate
  `1.10.5-100+ubuntu24.04` from the own repository. The installers' refusal without a package source was
  run. More detailed checks (four distributions, pins, https with basic auth) are in `src/vylaris/README.md`.
- The workflow file parses as YAML and passes `actionlint`.
- The hardened trust and pin behaviour, with throw-away keys and loopback test repositories: the pin
  file written by `client-setup.sh --root` selects the own host and blocks the upstream stand-in and a
  third repository that claims `Origin: VylarisSpace` (apt 2.8.4, unsigned test repositories); the
  refusals of `client-setup.sh` (http without opt-in, missing fingerprint for a downloaded key,
  fingerprint mismatch, expired key, several primary keys, user info in the URL); the credential file
  mode 600 and no credential in a `bash -x` trace; the local refusals of the installers (no package
  source, http, missing fingerprint); the pin check of `v-update-sys-vylaris` (function run in
  isolation: intact file ok, edited, missing or mismatching host fails closed).

Not verified:

- A real run of the GitHub Actions workflow (runner image, action versions, SSH publish to a real host).
- A complete installation of the package on a server (installer end to end) and the web update button.
- `iconv` and `xmlwriter` in the upstream `hestia-php`, builds for other suites and for arm64, and
  upgrade from a `--with-debs` installation to a repository build.
- The host pin in the four distribution chroots and with https and basic auth (the earlier checks in
  `src/vylaris/README.md` were made with a previous pin variant), `v-update-sys-vylaris` as a whole
  on a server, and the installer refusals that need the network (key download, fingerprint mismatch of
  a downloaded key, missing suite), which happen after `apt-get update` and the installation of the
  installer dependencies.

## 14. Work items

Effort is a rough guess for one person who knows the build scripts.

### Decisions (open)

- [ ] Public or private repository, host name, who pays for hosting (0.5 day, owner)
- [ ] Versioning: confirm base version plus `--pkgrev 100`, no epoch (0.5 day)
- [ ] Maintainer name and address for the Debian control files (0.5 day, owner)
- [ ] Supported distribution matrix (Debian 12/13, Ubuntu 22.04/24.04; arm64 yes or no) (0.5 day)
- [ ] Legal review of distribution and trademark points in section 10 (external)

### Build and infrastructure

- [x] Make `src/hst_autocompile.sh` usable for the private fork: `~localsrc`, no remote fetch for `--hestia`
- [x] Bundle `web/inc/vendor` into the package, `v-add-sys-dependencies` skips a complete vendor
- [x] Signing key tooling (`make-signing-key.sh`), repository tooling (`repo-init.sh`, `repo-publish.sh`)
- [x] CI workflow for the `hestia` package (Ubuntu 24.04), artifact upload, optional publish job
- [ ] Generate the real signing key, revocation certificate, offline backup of the primary key (0.5 day)
- [ ] Set up the repository host: run `repo-init.sh`, web server, optional auth (1 day)
- [ ] Activate the other CI suites and architectures (containers, native arm64 runners) (1 to 2 days)
- [ ] Smoke test job: install the deb in clean containers, run bats tests (2 days)
- [ ] First full build and publish of 1.10.5-100 for all targets (1 to 2 days with fixes)

### Installers and scripts

- [x] Installers: own repository options, key import, token support, pin file, no upstream version check,
      no download of the installer, refusal without a package source
- [x] Own update script and cron (`v-update-sys-vylaris` plus add/delete cron and Updates page)
- [x] Key `VYLARIS_UPDATES` in `bin/v-list-sys-config`, `func/syshealth.sh`, `bin/v-change-sys-config-value`
- [x] Public IP lookup is a neutral third party (`api.ipify.org`)
- [ ] Replace `install/deb/deb_signing.key` with the new public key (0.5 hour, after the key exists)
- [ ] Ship the repository keyring inside the `hestia` package for key renewals (0.5 day)
- [ ] Retire or re-point `src/hst_bootstrap_install.sh` and `src/lxd_compile.sh` (0.5 day)
- [ ] Test an upgrade from a server installed with `--with-debs` to the first repository build (1 day)

### Operations

- [ ] Upstream watch: subscribe to releases and security advisories, define who reads them (0.5 day setup)
- [ ] Merge routine for upstream tags, including the branding check list from section 9 (1 day to
      write down, then about 1 day per upstream release)
- [ ] Component watch for nginx, PHP, OpenSSL, PCRE, zlib, Node.js with a rebuild policy (0.5 day)
- [ ] Key rotation and token rotation runbook in operation (`src/vylaris/README.md`, section 8; 0.5 day)
- [ ] Rollback drill (`repo-publish.sh --rollback`, keeping three builds) (0.5 day)
- [ ] Stage 2: build and publish `hestia-nginx`, `hestia-php`, `hestia-web-terminal` (section 13)
