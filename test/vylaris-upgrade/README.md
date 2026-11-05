# Upgrade test: what an update does to the owner's things

This test installs VylarisSpace with the **real installer** into a systemd Ubuntu 24.04 container,
fills it with branding, admin settings, customisations and customer data, runs the update through
the **own update channel** (`bin/v-update-sys-vylaris install` against a signed test repository) and
then compares everything before and after.

It answers one question: "when the server updates itself, are my things untouched?"

```text
test/vylaris-upgrade/
  run.sh           orchestrates everything (start here)
  build-debs.sh    builds deb A (revision 100) and deb B (revision 101 + marker file) from a scratch copy
  repo.sh          throw-away CA, signing key and signed apt repository (uses src/vylaris/*.sh)
  seed.sh          fills the installed server (runs inside the container)
  snapshot.sh      records files, hashes, hestia.conf keys, panel lists, health (inside the container)
  guest-update.sh  closes the network, runs the update under strace (inside the container)
  compare.sh       compares two snapshots; also prints the file list of a deb (--strict: no normalisation)
  assert.sh        explicit checks on the result: no upgrade step, no rebuild, hand edits and "#" values kept
  repack-deb.sh    makes the later own revision (102) and the foreign stand-in of the guard phase from deb B
  guard-phase.sh   (inside the server) a foreign hestia package must be refused, nothing may change
  guard-override.sh (inside a copy of the server) the deliberate override lets the foreign package in
  net-summary.sh   turns the strace and DNS logs into the list of network destinations
  Dockerfile       systemd Ubuntu 24.04 ("server")
  Dockerfile.repo  the "repo" container: nginx (https) + dnsmasq (DNS, query log)
```

## Run it

```bash
test/vylaris-upgrade/run.sh                               # work dir /tmp/vylaris-upgrade-test
test/vylaris-upgrade/run.sh --work /some/dir --reuse-debs # skip the 1 minute deb build when /some/dir/debs exists
test/vylaris-upgrade/run.sh --open-network                # let the update reach the real internet (see below)
test/vylaris-upgrade/run.sh --keep                        # keep the containers to look around (docker exec vyup-sys bash)
test/vylaris-upgrade/run.sh --no-guard                    # skip the guard phase (step 7)
```

Exit status: `0` nothing unexpected changed, every assertion and every guard check passed; `1` `compare.sh`
found an unexpected difference or an assertion or guard check failed; `2` the test itself could not run.
Run time: about 11 minutes for the update, about 8 more for the guard phase (the installer takes 6 to 8 minutes).
The result is printed at the end and stored in `<work>/result/`:

| File                          | Content                                                                            |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| `compare.txt`                 | the comparison, sections (a) to (d) below                                          |
| `network.txt`                 | every network destination of the update, the program, the DNS names asked          |
| `summary.txt`                 | exit status of the update, installed version before and after                      |
| `upd/update.log`              | output of `v-update-sys-vylaris install`                                           |
| `upd/connect.trace`           | the raw `strace -f` log (connect, sendto, sendmsg, execve, clone)                  |
| `assert.txt`                  | the explicit checks of `assert.sh` (PASS/FAIL lines)                               |
| `guard/`                      | guard phase: logs of the three parts, the two comparisons, `upd2/` (second update) |
| `upd/hst_backups/*/`          | the upgrade's own log and the backup it made of conf, templates, packages          |
| `snap-before/`, `snap-after/` | the snapshots, including a copy of every file up to 100 KB                         |
| `dnsmasq.log`                 | query log of the resolver the server used                                          |

### Needs on the host

Docker with a reachable daemon (`docker ps`), privileged containers with `--cgroupns=host` (systemd as
PID 1; tested with cgroup v1 and Docker 29), Ubuntu 24.04 (the deb suffix `+ubuntu24.04` comes from
`lsb_release`), `node`, `npm`, `composer`, `openssl`, `gpg`, `reprepro`, `dpkg-deb`, `git`, `flock`.
Network access for the images, `npm ci`, composer and for the installer (it fetches `hestia-nginx`,
`hestia-php`, MariaDB, the sury PHP repository and phpMyAdmin from their upstream hosts).
Images `vylaris-upgrade-sys` and `vylaris-upgrade-repo` are built on the first run and kept as a
cache (`docker rmi vylaris-upgrade-repo vylaris-upgrade-sys` removes them). Containers and the network are
removed at the end unless `--keep` is given. `VYLUP_EXTRA_CA` (default `/root/.ccr/ca-bundle.crt`
when it exists) names CA certificates the images must trust, needed behind a TLS intercepting proxy.
Nothing is written into the checkout; the packages are built from a scratch copy.

## What happens

1. **Build.** Two packages from a scratch copy of the working tree with the normal build
   (`src/hst_autocompile.sh --hestia --pkgrev N '~localsrc'`, `npm run build`, `composer install`):
   A = `<base>-100+ubuntu24.04`, B = `<base>-101+ubuntu24.04` plus `web/vylaris-build-marker.txt`.
   (The two `vylaris*.min.css.map` files differ between A and B as well; they embed the build path.)
2. **Repository.** New test CA, new signing key (`src/vylaris/make-signing-key.sh`), new repository
   (`repo-init.sh`), A published (`repo-publish.sh --allow-dirty`), served over https as
   `repo.vylaris.test` with a certificate of the test CA that only the server container trusts.
3. **Install.** `install/hst-install-ubuntu.sh --vylaris-repo https://repo.vylaris.test
--vylaris-key-fingerprint ...` with nginx, PHP-FPM, MariaDB, Exim, Dovecot, BIND, iptables and the API.
   Not installed: Apache, multi-PHP, FTP, ClamAV, SpamAssassin, Fail2Ban, PostgreSQL, quota.
   The installer really runs: apt sources and pins, the keyring, `hestia`, `hestia-nginx`, `hestia-php`,
   the panel answers on port 8083.
4. **Seed** (`seed.sh`, real `v-*` commands): `APP_NAME 'Customer Brand'`, `TITLE`, `THEME vylaris-dark`,
   `HIDE_DOCS no`, `LANGUAGE de`, other policy values; a hand-edited `BACKUP_GZIP='7'`, an unknown key
   `OWNER_NOTE`, values with a hash sign (`SERVER_SMTP_PASSWD='pa#ss'`, `OWNER_HASH_NOTE='a#b # c&d|e'`), a key
   written twice (`OWNER_DUP`) and `/etc/hestiacp/local.conf`; a custom theme (`web/css/themes/custom`), a custom script
   (`web/js/custom_scripts/custom.js`), whitelabel logos (`web/images/custom`); edited and new web, mail and
   DNS templates and a custom hosting package; the user `cust` with web domain, own SSL certificate,
   customer nginx include files, database with two rows (MariaDB), mail domain, mailbox with a mail file and an
   alias, DNS zone with an extra record, cron job, SSH key; a firewall rule; a backup. A package-owned file
   (`web/css/themes/dark.min.css`) is edited by hand as a **canary**: the update is expected to replace it.
5. **Snapshot before**, publish B, **close the network** (routes of the uplink interface are removed; what
   remains is the internal test network with the repo container; `/etc/resolv.conf` points to the DNS of
   the repo container, which knows only `repo.vylaris.test`, refuses the rest and logs every query), check
   that `1.1.1.1`, `8.8.8.8` and an Ubuntu mirror address are unreachable, run
   `v-update-sys-vylaris install` under `strace -f`, **snapshot after**.
6. **Compare** (strict: a difference in a volatile field such as the DNS serial counts too), run the
   explicit checks of `assert.sh` and list the destinations.
7. **Guard phase** (closed network only, `--no-guard` skips it), on the same server after the update:
   1. A foreign stand-in is built from deb B: package `hestia`, version `1.10.6-1`, without the field
      `Vylaris-Edition`, without the themes, apt hook, checker and prerm of this edition, with its own
      postinst (it only writes `/root/foreign-postinst-ran`). `dpkg -i foreign.deb` and
      `apt-get install ./foreign.deb` must both be refused with the message, the installed version must
      be unchanged (`ii`, `dpkg --audit` empty), no foreign file may be unpacked and the foreign postinst
      must not run, `hestia.conf` must be byte-identical, every file of the package and of the owner trees
      must be identical and the panel login page must answer 200. A snapshot is compared with the one
      after the update (strict, 0 differences allowed).
   2. Recovery: a later own revision (102, made from B) is published and installed through
      `v-update-sys-vylaris install` again; it must run no upgrade step and no rebuild, change nothing but the
      version, and the guard must still be in place and still refuse the foreign package.
   3. Override, in two throw-away containers started from `docker commit` of the server (no systemd; only
      dpkg and apt are exercised): without the override the foreign package is refused; with the file
      `/etc/hestiacp/allow-foreign-hestia` (`dpkg -i`) and with `VYLARIS_ALLOW_FOREIGN_HESTIA=yes`
      (`apt-get install ./foreign.deb`) it is installed.

## How to read `compare.txt`

- **(a)** Files of the admin, the customers, the branding and the generated service configs
  (`/usr/local/hestia/{data,conf}`, `/etc/hestiacp`, `web/css/themes/custom`, `web/js/custom_scripts`,
  `web/images/custom`, `/etc/apt/{sources.list.d,preferences.d,auth.conf.d}`, the keyring, `/etc/nginx`,
  `/etc/php`, `/etc/exim4`, `/etc/dovecot`, `/etc/bind`, `/etc/cron.d`, `/etc/ssh`, user crontabs, `/home/*/{conf,web,mail,.ssh}`, `/backup`):
  changed, removed and added files with type, content hash, mode and owner, and the first changed lines.
- **(b)** Files owned by the package `hestia`: every file whose content differs between deb A and deb B must
  be the content of B afterwards; a file that the admin had changed before the update is reported as
  `PRESERVED` (still the admin's content, e.g. the whitelabel logos), `OVERWRITTEN` or `ALTERED`.
- **(c)** `hestia.conf` keys (`/usr/local/hestia/conf/hestia.conf`, `/etc/hestiacp/*.conf`) that changed, were
  added or removed. The comparison is key by key, so a re-sorted file is not a change.
- **(d)** What the panel reports (`v-list-*` as JSON), the content of the customer database, health checks
  (panel login page, `nginx -t`, `named-checkconf`, failed units, the customer site answers with its marker
  and its custom `X-Customer-Include` header), package versions, apt pin state, running services.

Every difference is classified. `expected` means it matches the short ALLOW list (logs, history, sessions,
queue, the update's own notification, the canary, files the upgrade writes by design) or the NORMALIZE list
(a text file that is identical once volatile fields such as disk usage, time stamps and the DNS serial are
removed). **Everything else is `UNEXPECTED`**, split into content/removal differences and
permission-only differences. Both lists are at the top of `compare.sh` with the reason for each entry;
add to them only with a reason, never to silence a finding.

## Results (2026-11-05, working tree after the upgrade-step cap and the package guard)

Closed network run, `run.sh --reuse-debs`, exit status 0. Final lines of the run:

```text
update exit status      : 0
compare.sh (strict)     :  RESULT: 0 UNEXPECTED content/removal difference(s), 0 UNEXPECTED permission-only difference(s),
                                   4 expected (documented) difference(s)
assert.sh               : assert.sh: 42 passed, 0 failed
guard phase             : 63 PASS, 0 FAIL
```

- **Update 1.10.5-100 to 1.10.5-101** through `v-update-sys-vylaris install`: exit status 0, panel and sites up. The upgrade
  log says "Starting upgrade from 1.10.5 to 1.10.5" and "The latest version is already installed". **No version step
  ran**: no "applying patches" line, no `v1.10.6`, no `v-rebuild-*` program in the `strace` of the update. `VERSION` in
  `hestia.conf` stays `1.10.5`.
- **The 4 expected differences:** the reference copy `conf/defaults/mail_accounts.conf` that the upgrade writes, `hestia.conf`
  (compared key by key in section (c): unchanged; the text differs because the duplicated key `OWNER_DUP` was merged
  into one line), the "Upgrade complete" notification, and the canary `dark.min.css`.
- **Gone since the first runs**, which ran the step `versions/1.10.6.sh` on every update (see git history of this file):
  the customer's DNS record `webmail` turned from `CNAME` into `A` and the SOA serial rose by 2; the 17 mode and owner
  changes (`web`, `conf/mail`, `conf/dns`, `cron.conf`, the log symlinks); 36 generated configs rewritten with identical
  content. `assert.sh` checks each of them explicitly (zone file and record file hashes, mode and owner of every file of
  the compared trees, no rewritten customer config).
- **Untouched:** all `hestia.conf` keys including the hand-edited `BACKUP_GZIP='7'`, `OWNER_NOTE`, the values with a hash sign
  (`SERVER_SMTP_PASSWD='pa#ss'`, `OWNER_HASH_NOTE='a#b # c&d|e'`) and the key written twice (`OWNER_DUP`: one line with the last value
  `'last#value|with&chars'` afterwards), `/etc/hestiacp/local.conf`, the custom theme, script and logos, the whitelabel logos in
  `web/images` (`PRESERVED`), every edited template, the apt source lists, pin and keyring, the firewall rules, the customer's
  files, database rows, mail file, cron job, SSH key, backup, SSL certificate and own nginx include files.
- **Guard phase:** `dpkg -i` and `apt-get install ./foreign.deb` of the foreign `hestia 1.10.6-1` are refused (exit 1 and
  100), the installed package stays `ii`, a snapshot taken afterwards equals the one after the update (0 differences, 0
  expected), the panel answers 200. The later own revision 102 installs through the same channel, runs no step and no rebuild,
  and changes nothing but the version and the notification. The override file and `VYLARIS_ALLOW_FOREIGN_HESTIA=yes` let the
  foreign package in (throw-away copies of the server).
- **Network during the update:** the own repo (`/dists/noble/InRelease`, `Packages.gz`, the deb) and `api.cloudflare.com`
  (`curl` in `upgrade_cloudflare_ip`, every time, it is not gated by `UPSTREAM_UPDATES`; refused here because the network is
  closed). `telemetry.sury.org` is asked by the sury build of php-fpm when the update restarts it. Nothing else.
- **With `--open-network`** (first runs, before the cap) `/etc/nginx/conf.d/cloudflare.inc` was replaced from `api.cloudflare.com` and
  the line the seed had added by hand was gone. That is not changed by the cap and is not asserted in the open run.

## What it proves, and what it does not

Proves, for the configuration it installs (see step 3) on Ubuntu 24.04 and for an update from revision 100 to
101 of the same base version through `v-update-sys-vylaris`: which of the listed things are touched by the
real postinst, the upgrade scripts and the user rebuild; which hosts the update tries to reach; that the
update works with the network closed except the repo.

Does not prove:

- A **version bump** (e.g. 1.10.5 to a higher base version with new `install/upgrade/versions/*.sh`). A and B
  have the same base version `1.10.5`; steps newer than that base (`1.10.6.sh` in the current tree) are skipped by
  design, which is what the run shows. The step selection itself is covered by `test/vylaris-upgrade-unit/upgrade-steps.sh`.
- Services that are not installed here (Apache, multi-PHP, FTP, ClamAV, SpamAssassin, Fail2Ban, PostgreSQL),
  Let's Encrypt, real mail delivery, DKIM, quota, cluster, the web terminal, the API with keys, 2FA.
- Other distributions or architectures, and the stage-2 packages (`hestia-nginx`, `hestia-php` come from
  upstream and are not updated by this test).
- The accident case with the **real** upstream package: the guard phase uses a stand-in made from deb B (same package
  name, no `Vylaris-Edition` field). A foreign package with its own `prerm` that exits 0 passes `dpkg -i` (the apt hook
  still stops the apt paths); that case is not part of this harness.
- That a different admin user name behaves the same (`--admin-user NAME` exists but was not run; note that
  `src/deb/hestia/preinst` only does its work when `data/users/admin` exists).
- Timing and load; the container has no real traffic.

### Test environment, not product

- The kernel of the machine this was written on has **no IPv6**. The Dovecot configuration written by the
  installer says `listen = *, ::`, which cannot start there and makes the installer stop. `run.sh` therefore
  adds a systemd drop-in for `dovecot.service` that rewrites that line to IPv4 before each start, only when
  `/proc/net/if_inet6` is missing. Nothing else is stubbed: no fake `systemctl`, `nginx` or `php`.
- `docker exec` runs with umask 0000, which made the first versions of this test create world-writable
  files. Every command in the container now runs with umask 022.
- The network is closed with routes, not with iptables, because the Hestia firewall replaces the whole
  iptables rule set. The address of the uplink interface is left in place so the panel's IP list stays equal.
- With `--open-network` the uplink stays up and the resolver forwards to public DNS; the list of
  destinations is then a list of hosts that were really reached.
- Keys, the CA and the repository are generated on every run and removed afterwards.
