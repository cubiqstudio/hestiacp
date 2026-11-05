# VylarisSpace package repository tooling

Scripts to run the own apt repository for the `hestia` package (the panel) with `reprepro`, and the
script a server runs to trust it. They implement stage 1 of `VYLARIS-PACKAGING.md`.

**Stage 1 (this directory): hybrid.** The own repository carries only the package `hestia` (`bin`,
`func`, `install`, `web`, built assets). `hestia-nginx`, `hestia-php` and `hestia-web-terminal` still
come from the upstream apt repository, signed by upstream. Building them is stage 2 (native compile,
see the end of this file). Because the package name `hestia` is the same as upstream's and the base
version is the same, **apt pinning is mandatory**: package `hestia` may only come from the own
repository host, so an upstream release 1.10.6 or later cannot replace the fork through apt. The pins
protect the choice of the candidate version and upgrades; they are not a lock against an explicit
`apt-get install hestia=VERSION` (see section 5).

Everything runs on the owner's infrastructure. No key, host name, password or contact address is stored
in the git repository. There is deliberately no default host.

| File                  | Purpose                                                                                |
| --------------------- | -------------------------------------------------------------------------------------- |
| `make-signing-key.sh` | Create a new signing key pair (offline primary key, signing subkey, revocation cert)   |
| `repo-init.sh`        | Create the reprepro layout, suites, public key, sample nginx config                    |
| `repo-publish.sh`     | Add debs, verify the signature chain, keep the last 3 builds, store the source archive |
| `client-setup.sh`     | Run on a server: keyring, source list, pins, optional credentials                      |

All scripts: `--help` prints the usage. They are plain bash, `shellcheck` clean, and refuse to work
inside a git working tree where that would leak secrets or mix packages into the source tree.

## Requirements

On the machine that publishes: `reprepro`, `gnupg` (2.2 or newer), `dpkg-dev` (`dpkg-deb`), `git`,
`flock` (util-linux). On a server: `gnupg`, `curl` (only when the key or credentials are fetched over
https), `apt`.

```bash
apt-get install reprepro gnupg dpkg-dev git
```

## 1. Create the signing key (once)

Use a machine you control, outside of the git checkout, preferably an encrypted disk.

```bash
umask 077
printf '%s\n' 'a long random passphrase' > /root/vylaris-key.pass # store it in your password manager
src/vylaris/make-signing-key.sh \
	--passphrase-file /root/vylaris-key.pass \
	--signing-home /root/vylaris-sign-gnupg \
	/root/vylaris-key-out /root/vylaris-gnupg
```

Arguments: the output directory and a new GnuPG home (must not exist or be empty). The GnuPG home path
must be short (about 80 characters at most): `gpg-agent` creates a socket there and fails with a long
path. The script says so.

What it creates:

- A primary key that can only certify (`[C]`) and a separate signing subkey (`[S]`), both ed25519, both
  valid for 2 years. The user id is `VylarisSpace Package Signing Key` (change with `--uid`; no e-mail
  address is invented).
- `pubkey.asc` and `vylarisspace-keyring.gpg` (the public key, armored and binary).
- `revocation-certificate-<id>.asc`: store it offline; publishing it revokes the key.
- `secret-primary-and-subkey-OFFLINE-BACKUP-<id>.asc`: the whole secret key, protected by the passphrase.
- `secret-signing-subkey-only-<id>.asc`: only the signing subkey.
- With `--signing-home DIR`: a second GnuPG home that contains only the signing subkey, **without
  passphrase**, and the primary key as a stub (`sec#`). This is the home the repository host uses so that
  `reprepro` can sign unattended. Protect it with file permissions and disk encryption.

The script refuses to write inside any git working tree, refuses a non-empty target and prints the
fingerprint and the backup steps. Never reuse `install/deb/deb_signing.key`: that is the upstream
project's public key.

**Backup and offline primary key.** Copy `/root/vylaris-key-out` to two offline media in different
places. Then remove `secret-primary-and-subkey-OFFLINE-BACKUP-*.asc` and the primary key home
(`/root/vylaris-gnupg`) from the machine. From now on only `/root/vylaris-sign-gnupg` stays on the
repository host. The offline primary key is needed only to extend the expiry, to create a new signing
subkey or to revoke.

**Algorithm choice.** ed25519 is the default. RSA 4096 is available with `--algo rsa4096`. Checked in
isolated apt environments (debootstrap chroots, real `apt-get update` against a signed repository served
by nginx):

| System       | apt   | Verifier          | ed25519 repository key |
| ------------ | ----- | ----------------- | ---------------------- |
| Ubuntu 22.04 | 2.4.5 | gpgv 2.2.27       | accepted               |
| Ubuntu 24.04 | 2.7.x | gpgv 2.4.4        | accepted               |
| Debian 12    | 2.6.1 | gpgv 2.2.40       | accepted               |
| Debian 13    | 3.0.3 | sqv 1.3.0 (apt 3) | accepted               |

An RSA 4096 key was created and its signature checked with `sqv` on Debian 13 and with `gpg`; it was
not run through every chroot. Choose RSA only if you have to support a verifier older than gpg 2.1.

Set the key for the next steps:

```bash
export VYLARIS_SIGN_KEY=PRIMARY_FINGERPRINT # printed by make-signing-key.sh
export GNUPGHOME=/root/vylaris-sign-gnupg
```

## 2. Initialise the repository

`REPO_HOST` is the host name of the repository (only used in the nginx sample). `/srv/vylarisspace-repo`
is an example directory; `repo-init.sh` needs `VYLARIS_SIGN_KEY` and `GNUPGHOME` from step 1.

```bash
src/vylaris/repo-init.sh --staging --server-name REPO_HOST /srv/vylarisspace-repo
```

Layout (only `public/` is ever served):

```text
/srv/vylarisspace-repo/
  conf/distributions   suites bookworm trixie jammy noble (+ <codename>-staging with --staging)
  conf/options         outdir +b/public, dbdir +b/db, logdir +b/logs
  db/ logs/            reprepro state (back up)
  archive/<suite>/     the last N builds per suite, used for rollbacks (private)
  public/dists         Release, InRelease, Release.gpg, Packages per suite
  public/pool          the .deb files
  public/pubkey.gpg    public key, binary (usable as apt signed-by file)
  public/pubkey.asc    public key, armored
  public/sources/      source archives (GPL source offer)
  nginx-vylarisspace-repo.conf.sample
```

Each suite has `Origin: VylarisSpace`, `Components: main`, `Architectures: amd64 arm64` and
`SignWith: <your key>`. The `Origin` field is informative only: the pins on the servers do not use it
(any repository can claim it), they are bound to the host name of the repository (section 5). Suite name and codename are identical (`noble`), as apt requires the codename of
the server. The script signs the empty indices once, which proves that the key works. It refuses to run
inside a git working tree or on an already initialised directory.

## 3. Build and publish

Build the package from the checked-out, committed tree with the package revision 100 or higher (see
`VYLARIS-PACKAGING.md`, section 2):

```bash
bash src/hst_autocompile.sh --hestia --noinstall --keepbuild --pkgrev 100 '~localsrc'
```

`apply_distro_version` in `src/hst_autocompile.sh` builds the version
`<base>-<pkgrev>+<distro><release>` from `lsb_release`, so the result is for example
`1.10.5-100+ubuntu24.04`, `1.10.5-100+debian12`. Build once per distribution and architecture, in a
container or host of the target system. The build host needs `composer`: it installs the PHP libraries
(`web/inc/vendor`, `web/src/vendor`, `composer install --no-dev`) and fetches them from Packagist and
GitHub **at build time**. They are bundled into the package, so servers need no network access for them
at runtime. Development files and Markdown documentation of the libraries (tests, docs, examples,
`*.md`, git and editor settings) are removed from the package; the licence files stay.

```bash
src/vylaris/repo-publish.sh /srv/vylarisspace-repo hestia_1.10.5-100+ubuntu24.04_amd64.deb \
	hestia_1.10.5-100+ubuntu24.04_arm64.deb hestia_1.10.5-100+debian12_amd64.deb
```

The suite is derived from the version suffix:

| Suffix         | Suite      |
| -------------- | ---------- |
| `+debian12`    | `bookworm` |
| `+debian13`    | `trixie`   |
| `+ubuntu22.04` | `jammy`    |
| `+ubuntu24.04` | `noble`    |

A `~tag` after the suffix (CI builds, `--release`) is accepted. Anything else needs `--suite`. The script
only accepts the package `hestia` (stage 1) unless `--allow-other-packages` is given.

What a publish does, in this order:

1. Checks package name, suite and source commit for all files first. The architecture and the version check
   are done per file, so a refusal on a later file leaves the earlier files published.
2. Refuses a version older than the one served in that suite and architecture, and refuses to reuse a
   version number for different content. Publishing identical content again is a no-op (exit 0).
3. `reprepro includedeb`, which writes the indices and signs `Release`, `InRelease` and `Release.gpg`.
4. Copies the deb to `archive/<suite>/`.
5. Verifies the result without trusting reprepro: `gpgv` against `public/pubkey.gpg` for `InRelease` and
   `Release.gpg`, the signer must be the primary key of `pubkey.gpg`; then `Release` lists the sha256 of
   `Packages.gz`, and `Packages.gz` lists the sha256 and size of the deb. If this fails (exit 3) the deb
   is already archived, so the same version cannot be reused for different content; publish a higher
   revision instead. After a successful check the last `N` builds per suite and architecture are kept
   (`--keep N`, default 3, or `VYLARIS_KEEP_VERSIONS`).
6. Stores `public/sources/vylarisspace-<version>-<revision>-<12 character commit>.tar.gz` (see section 9) and appends a line to
   `logs/publish.log`.
7. Prints the sha256 of the deb and of the source archive. A warning appears when the signing key
   expires within 60 days; an expired key stops the publish.

**One version per suite.** `reprepro` keeps exactly one version of a package per suite and architecture;
that is a property of the tool. The last N builds are therefore kept in `archive/`, not in the apt
index. Publish all architectures of a build together, otherwise `amd64` and `arm64` of one suite show
different versions.

**Staging and promotion.** With `--staging`, publish to `noble-staging` first
(`--suite noble-staging`), test on one server (`client-setup.sh --suite noble-staging`), then promote:

```bash
src/vylaris/repo-publish.sh --promote /srv/vylarisspace-repo noble
```

Promote publishes the newest archived staging build into the real suite, with the same verification.

## 4. Serve it

The repository is static files. Serve it from a host name that is **dedicated to this repository**: the
pin on the servers trusts the host (not the path) for the package `hestia`, so any other repository on
the same host would be trusted for it too. `repo-init.sh` writes `nginx-vylarisspace-repo.conf.sample` for the
chosen host name: https only, `root` at `<repo>/public`, no directory listing, optional basic auth with
one user per server, `pubkey.*` readable without credentials, `dists/` not cached, dot files denied.

```bash
printf '%s:%s\n' server01 "$(openssl passwd -apr1)" >> /etc/nginx/vylarisspace-repo.htpasswd
chgrp www-data /etc/nginx/vylarisspace-repo.htpasswd && chmod 640 /etc/nginx/vylarisspace-repo.htpasswd
cp nginx-vylarisspace-repo.conf.sample /etc/nginx/conf.d/vylarisspace-repo.conf # then adjust
nginx -t && systemctl reload nginx
```

Checked with the generated sample behind a local nginx: without credentials `dists/` answers 401, with
credentials 200, `pubkey.gpg` answers 200 without credentials, and `conf/`, `db/` and `archive/` answer
404 because they are outside the served root. Any other static host works too (object storage, CDN); the
signature protects the content, the credentials only decide who may download. The sample is a template:
certificate paths are placeholders.

For a public repository remove the three `auth_basic` lines.

## 5. Trust the repository on a server

Run as root on the server. The script is self-contained, copy `client-setup.sh` to the server. The
placeholders are yours to fill in: `REPO_HOST` and `REPO_PATH` from the URL the repository is served
under, `PRIMARY_FINGERPRINT` from the owner (see below), `SERVER_USER` and `SERVER_TOKEN` only for a
private repository.

```bash
VYLARIS_REPO_URL=https://REPO_HOST/REPO_PATH \
	VYLARIS_REPO_KEY_FPR=PRIMARY_FINGERPRINT \
	VYLARIS_REPO_AUTH=SERVER_USER:SERVER_TOKEN \
	bash client-setup.sh --update
```

**The fingerprint.** On the owner's machine, from the public key (never from the repository server, which
is the thing to be verified):

```bash
gpg --show-keys --with-fingerprint pubkey.asc
```

Publish the 40 digit fingerprint of the **primary** key out of band (contract, ticket, your own web
site), `make-signing-key.sh` prints it too. Case and spaces do not matter.

| Input                                                       | Meaning                                                                                  |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `VYLARIS_REPO_URL` / `--repo`                               | Base URL `https://REPO_HOST[:port]/REPO_PATH`. Required, no default host                 |
| `VYLARIS_REPO_KEY` / `--key`                                | URL or local file of the public key (armored or binary). Default `REPO_URL/pubkey.gpg`   |
| `VYLARIS_REPO_KEY_FPR` / `--key-fingerprint`                | Refuse the key unless its primary fingerprint is this one. Required for a downloaded key |
| `VYLARIS_REPO_AUTH` / `--auth-file`                         | `user:password` (environment), or a file whose first line is `user:password`             |
| `VYLARIS_ALLOW_INSECURE_HTTP=yes` / `--allow-insecure-http` | Accept an `http://` repository or key URL (tests on trusted networks only)               |
| `--suite`, `--arch`                                         | Default from `/etc/os-release` and `dpkg`; `CODENAME-staging` for staging                |
| `--root DIR`                                                | Work on a chroot or test directory; apt is not run                                       |
| `--keyring-path`, `--upstream-host`                         | Keyring path as apt sees it; host of the upstream repository to pin away                 |
| `--update`                                                  | `apt-get update` restricted to the own source list (not with `--root`)                   |

The installers (`install/hst-install-*.sh`) contain the same steps, with the option names
`--vylaris-repo`, `--vylaris-key`, `--vylaris-key-fingerprint`, `--vylaris-repo-auth` and
`--allow-insecure-http`. The part between the "shared" markers is identical in all three files.

It writes, idempotently (a second run reports `unchanged`):

- `/usr/share/keyrings/vylarisspace-keyring.gpg`: the key, dearmored if needed. No `apt-key`, nothing in
  `trusted.gpg.d`.
- `/etc/apt/sources.list.d/vylarisspace.list`:
  `deb [arch=ARCH signed-by=/usr/share/keyrings/vylarisspace-keyring.gpg] REPO_URL CODENAME main`.
- `/etc/apt/preferences.d/vylarisspace`: the pins below.
- `/etc/apt/auth.conf.d/vylarisspace.conf` (mode 600, root), only when credentials are given:
  `machine HOST[:port][/path] login USER password TOKEN`.

### Key trust

- **https is required.** An `http://` repository or key URL is refused unless `--allow-insecure-http` (or
  `VYLARIS_ALLOW_INSECURE_HTTP=yes`) is given, and then it prints a warning. Credentials together with an
  http repository are refused.
- **A key that is downloaded needs its fingerprint.** A key that comes from the same server proves
  nothing about who owns it, so without `--key-fingerprint` the script refuses before it downloads
  anything. A key given as a **local file** may omit the fingerprint: the script prints the fingerprint
  and says it was not verified, compare it with the one the owner published.
- The fingerprint of the **primary** key is compared. The key file must contain **exactly one primary
  key** (apt trusts everything in the keyring, the signing subkey is trusted with its primary key), **no
  secret key material**, and the key must not be **expired, revoked, disabled or invalid**. Each of
  these is refused with a message.
- The repository URL must not contain user info, an IPv6 literal, a query, a fragment or percent
  escapes. The upstream host is refused as repository host. Error messages print the URL with the user
  info masked.

### Credentials

- `VYLARIS_REPO_AUTH` is read once, written to `/etc/apt/auth.conf.d/vylarisspace.conf` (mode 600) and
  removed from the environment of the script and of everything it starts.
- The `--auth-file` option avoids a password in the process list. The installers also have
  `-A` / `--vylaris-repo-auth` with the value on the command line: it is visible in `ps` while the
  installer runs, and the installer prints a warning. Prefer the environment variable.
- For the key download the credentials go to curl on stdin, only over https and only to the exact same
  host **and port** as the repository (a redirect may not leave https; `https://REPO_HOST.OTHER_DOMAIN` is not
  `https://REPO_HOST`).
- When the shell traces (`bash -x`, `set -x`) and credentials may be present, tracing is switched off
  for the whole run and a note is printed.
- Credentials must be a generated token without spaces, quotes or backslashes.

### The pins

`apt` uses the **first** stanza that matches, so the order of the four stanzas is part of the design.
The file is written in this order (the real file also carries comments):

```text
Package: hestia
Pin: origin apt.hestiacp.com
Pin-Priority: -1

Package: hestia
Pin: release o=apt.hestiacp.com
Pin-Priority: -1

Package: hestia
Pin: origin REPO_HOST
Pin-Priority: 1001

Package: hestia
Pin: origin *
Pin-Priority: -1
```

- **1 and 2, upstream first.** The upstream repository is blocked by its host name and by the Origin it
  claims. A version from there never becomes the candidate.
- **3, the own repository by HOST, not by the Origin of its Release file.** Any repository can claim
  `Origin: VylarisSpace`, a host name is what the pin can rely on. The pin binds to the **host** only,
  not to the path or the port. Consequence: **the host of the own repository has to be dedicated to this
  repository**. Any other repository served from the same host would also be trusted for the package
  `hestia`. A `file://` repository (tests only) has no host and is matched with an empty origin
  (`Pin: origin ""`).
- **4, everything else.** `origin *` at -1 means a third repository that carries a package named
  `hestia` never wins and cannot be installed by accident. It does not match the installed package
  (dpkg status), so the installed version stays valid.
- **Moving the repository to another host** means running `client-setup.sh` again, which rewrites the
  source list and the pin. If only the source list is changed by hand, the pin no longer matches and
  `v-update-sys-vylaris` refuses (`pin_ok=no`, section 6).
  `pin_ok` only describes the file `/etc/apt/preferences.d/vylarisspace`; it does not detect conflicting pins in other apt preference files. The check that the candidate is offered by the own source only still applies.
- **Priority 1001 does the work, -1 is the safety net.** With 1001 the own version wins even against a
  higher upstream version number. The -1 stanzas matter when the own index is missing (failed
  `apt-get update`, removed source): there is then no candidate at all instead of the upstream package.
- Priority above 1000 also means a **downgrade is allowed** when the own repository serves a lower
  version than the installed one (see Rollback).

**What the pins do not do.** They steer the choice of the candidate and upgrades. An explicit
`apt-get install hestia=VERSION` for a version that a blocked source offers still installs it (apt
behaviour, checked below), and so does `dpkg -i`. The pins also cover the package `hestia` only: the
other upstream packages (`hestia-nginx`, `hestia-php`, `hestia-web-terminal`) are not pinned. In stage 1
they come from the upstream repository and are updated by the normal system `apt upgrade`, see
`VYLARIS-PACKAGING.md`, section 8. That is a known trade-off of stage 1 and the reason stage 2 exists.

### Checked behaviour

Two sets of checks exist, and they do not cover the same thing.

**Pin variant with the Release Origin (earlier design, now replaced).** In four isolated apt
environments (debootstrap chroots of Ubuntu 22.04, 24.04, Debian 12, 13; apt 2.4.5, 2.7.14, 2.6.1,
3.0.3), with the own repository behind nginx with TLS and basic auth and a fake upstream repository
(test key, Origin `apt.hestiacp.com`, host name mapped in `/etc/hosts`) carrying `hestia 1.10.6`, the
pin file of that time (own repository matched by `release o=VylarisSpace`) gave:

| Check                                                             | Result in all four                                          |
| ----------------------------------------------------------------- | ----------------------------------------------------------- |
| `apt-get update` over https with credentials from `auth.conf.d`   | ok (nginx log shows the user on every request)              |
| `apt-cache policy hestia` with the pins                           | candidate `1.10.5-100+...`, own 1001, upstream 1.10.6 at -1 |
| Control experiment: pin file removed                              | candidate becomes upstream `1.10.6-1+...`                   |
| `apt-get install hestia` with the pins                            | installs the own build                                      |
| Upstream publishes 1.10.7, then `dist-upgrade` / `--only-upgrade` | no change to `hestia`                                       |
| Own publishes a higher revision                                   | `--only-upgrade hestia` installs it                         |
| Repository signed by another key                                  | `apt-get update` refuses (NO_PUBKEY / sqv "Missing key")    |
| `client-setup.sh` run twice                                       | second run `unchanged`                                      |

**Current pin file (host pin).** Checked with apt 2.8.4 on one machine, with three unsigned test
repositories (`trusted=yes`, so the signature path was not part of this check) on three loopback
addresses, each with a dummy package `hestia`: the own repository (1.10.5-100), a stand-in for upstream
(1.10.9, Origin `apt.hestiacp.com`, given to the script with `--upstream-host`) and a third repository
that claims `Origin: VylarisSpace` (2.0.0). The pin file was written by `client-setup.sh --root`:

| Check                                                        | Result                                                                                                 |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `apt-cache policy hestia` with the pin file                  | candidate 1.10.5-100 (own host) at 1001; 1.10.9 and 2.0.0 at -1                                        |
| Control experiment: pin file removed                         | candidate becomes 2.0.0 (the repository that claims the Origin)                                        |
| `apt-get -s install hestia=1.10.9-1+ubuntu24.04`             | would install from the blocked source (explicit version)                                               |
| `v-update-sys-vylaris` pin check (function run in isolation) | intact file ok; priority edited, file removed and source list pointing to another host all fail closed |

Not rerun for the host pin: the four distribution chroots, https with basic auth, and the installers end
to end.

## 6. Updates and rollout

1. Build, publish to `<codename>-staging`, test on one server, promote.
2. Servers pick up the new build through the own update path (`bin/v-update-sys-vylaris`, installers
   set `VYLARIS_UPDATES='yes'`) or a manual `apt-get install --only-upgrade hestia`.
3. `UPSTREAM_UPDATES` stays `no`. The upstream update scripts never run. The two keys exclude each
   other: `v-change-sys-config-value` refuses to set one to `yes` while the other is `yes`, and
   `v-update-sys-hestia-git` refuses to run while `VYLARIS_UPDATES` is `yes` (it installs with `dpkg -i`,
   which ignores the pins). The upstream update buttons of the panel are therefore not offered.
4. `v-update-sys-vylaris` checks the pin file before it does anything but `status`: it must contain the
   four stanzas above, in this order, with the host of the source list in the own stanza. If the file is
   missing or was edited, the command refuses (exit code 10) and logs a warning; restore the file by
   running `client-setup.sh` again. `v-update-sys-vylaris status` prints `pin_ok=yes` or `pin_ok=no`.
   It also installs only a candidate that is newer than the installed version and that is offered by the
   own source only.

Keep the revision monotonic. Because of priority 1001, a manual `apt-get upgrade` will also move a
server **down** if the repository serves a lower version, `v-update-sys-vylaris` will not.

## 7. Rollback

Preferred: publish a corrected build with a higher revision (`-101` after a bad `-100`).

If the bad build must disappear at once:

```bash
src/vylaris/repo-publish.sh --rollback /srv/vylarisspace-repo noble 1.10.5-100+ubuntu24.04
```

This removes the current version from the suite index and publishes the archived build again (the last
N builds are in `archive/<suite>/`). Servers that have not updated yet see no change. Servers that already
installed the bad build and use the pins are offered the older version as a downgrade at the next
`apt-get upgrade` (checked: apt proposes `Inst hestia [101] (100 ...)`). One server can also be moved
by hand: `apt-get install hestia=<version>` works for the version that is currently in the index.
The `postinst` and the upgrade scripts of the package only move forward, so test a downgrade on a copy
first. A version number that was published once is never reused for different content.

## 8. Key lifetime, rotation, compromise

- The key expires after 2 years. **Servers reject a repository that is signed by an expired key**, the
  keyring file on a server does not update itself, and `client-setup.sh` and the installers refuse to
  install an expired or revoked key file. Put the expiry date into a calendar now.
- Extend the expiry (primary key from the offline backup, in a temporary GnuPG home):
  `gpg --quick-set-expire <primary fingerprint> 2y '*'`, then export the new public key
  (`gpg --export`), replace `public/pubkey.gpg` and `pubkey.asc`, and give the servers the new file
  **before the old date**: re-run `client-setup.sh` on each server (it replaces the keyring), or ship the
  keyring inside the `hestia` package. Shipping it in the package (installed to
  `/usr/share/keyrings/vylarisspace-keyring.gpg` by a build step) is the robust way, because the package
  update that carries the new key is still signed by the old, valid key.
- New signing subkey only (primary stays): `gpg --quick-add-key <fpr> ed25519 sign 2y`, import the new
  secret subkey into the signing home, export the public key as above.
- New primary key (full rotation): run `make-signing-key.sh` again, publish the new key, run
  `client-setup.sh --key-fingerprint <new>` on every server while the old key is still valid, switch
  `SignWith` in `conf/distributions`, run `reprepro -b <repo> export`.
- Compromise: publish `revocation-certificate-<id>.asc` (import it, export the public key), issue a new
  key as above and tell the servers. Rotate the repository passwords as well.
- Passwords: one basic-auth user per server (`htpasswd`), so that a single server can be locked out.

## 9. GPL source offer

`repo-publish.sh` stores, for every published build, the matching source archive in `public/sources/`:
`git archive` of the commit (`--source-commit`, default `HEAD` of the checkout that contains the
script), named `vylarisspace-<version>-<revision>-<12 character commit>.tar.gz`, plus `SHA256SUMS` and a
`README`. It refuses to publish while the source checkout has uncommitted changes (the archive would not
match the package; `--allow-dirty` overrides, `--no-source` is for tests only). It warns when
`src/deb/hestia/control` in that commit does not match the package version.

The source archives are never pruned. Point your source offer (website, customer contract, the
`Homepage` field) to `<repo>/sources/`. The packages contain the license text. In stage 1 the archive is
the VylarisSpace tree; the panel build additionally uses npm and composer dependencies that are bundled
into the package (`web/inc/vendor`, built assets), which carry their own licenses. Whether and how
distribution to customers' servers counts as conveying is a legal question listed in
`VYLARIS-PACKAGING.md`, section 10.

## 10. Open items for the owner

- Host name and public or private operation; TLS certificate for it.
- `Maintainer` and `Homepage` in `src/deb/*/control` still name upstream. They are not changed here.
- Ship the repository keyring inside the `hestia` package (see key lifetime) and replace
  `install/deb/deb_signing.key` by the new public key once it exists.
- Backups: the key output directory (offline), and `conf/`, `db/`, `archive/`, `public/` of the
  repository.
- Stage 2 (own `hestia-nginx`, `hestia-php`, `hestia-web-terminal`): native builds per distribution and
  architecture, then publish with `--allow-other-packages`; reprepro and the pins then need stanzas for
  those package names too. Until then the upstream repository stays a trusted root for those three
  packages: they are updated from it by the normal system `apt upgrade` (the pins only cover `hestia`),
  and nobody patches them if upstream stops.
- The host name of the repository must be dedicated to it: the pin on the servers trusts the host for
  the package `hestia`.
- The staging suites are optional; remove them from `conf/distributions` if unused.

## Not verified

- No real `hestia` package was built or published; the tests used dummy debs with the same package
  name and version scheme.
- No run on a real server and no real host name. Tests ran in chroots on one machine with a local
  nginx and a mapped host name.
- Passphrase-protected key handling was checked for generation, export and signing-home creation; the
  full publish test used a key without passphrase.
- RSA 4096 was not run through every apt environment.
- The refusal for an expired signing key of `repo-publish.sh` is in the code but was not exercised (only
  the 60 day warning was). The `--update` option was run only inside a chroot.
- The host pin was checked with unsigned local test repositories and apt 2.8.4 (section 5), not in the
  four distribution chroots, and not with https and basic auth. The refusals of `client-setup.sh`
  (http without opt-in, missing fingerprint, fingerprint mismatch, expired key, several primary keys,
  user info in the URL) and the credential file (mode 600, no secret in a `bash -x` trace) were run
  with `--root` and a throw-away key; the installers' local refusals were run too. The refusals that need
  the network (key download, missing suite) were not run against a real host.
