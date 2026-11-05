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
  compare.sh       compares two snapshots; also prints the file list of a deb
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
```

Exit status: `0` nothing unexpected changed, `1` `compare.sh` found an unexpected difference,
`2` the test itself could not run. Run time: about 11 minutes (the installer takes 6 to 8 of them).
The result is printed at the end and stored in `<work>/result/`:

| File                          | Content                                                                   |
| ----------------------------- | ------------------------------------------------------------------------- |
| `compare.txt`                 | the comparison, sections (a) to (d) below                                 |
| `network.txt`                 | every network destination of the update, the program, the DNS names asked |
| `summary.txt`                 | exit status of the update, installed version before and after             |
| `upd/update.log`              | output of `v-update-sys-vylaris install`                                  |
| `upd/connect.trace`           | the raw `strace -f` log (connect, sendto, sendmsg, execve, clone)         |
| `upd/hst_backups/*/`          | the upgrade's own log and the backup it made of conf, templates, packages |
| `snap-before/`, `snap-after/` | the snapshots, including a copy of every file up to 100 KB                |
| `dnsmasq.log`                 | query log of the resolver the server used                                 |

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
   `OWNER_NOTE` and `/etc/hestiacp/local.conf`; a custom theme (`web/css/themes/custom`), a custom script
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
6. **Compare** and list the destinations.

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

## Results of the first runs (2026-11-05, tree at commit 05d8162 plus working tree)

Update 1.10.5-100 to 1.10.5-101 through `v-update-sys-vylaris install`, exit status 0, panel and sites up
afterwards. Closed network run and `--open-network` run:

- **Untouched:** all 75 `hestia.conf` keys (`APP_NAME`, `TITLE`, `THEME vylaris-dark`, `HIDE_DOCS no`, `LANGUAGE de`,
  the hand-edited `BACKUP_GZIP='7'`, the unknown key `OWNER_NOTE`, `UPSTREAM_UPDATES no`, `VYLARIS_UPDATES yes`),
  `/etc/hestiacp/local.conf`, `web/css/themes/custom`, `web/js/custom_scripts/custom.js`, `web/images/custom`, the
  whitelabel logos in `web/images` (re-applied from `custom/`), every edited and new template in `data/templates`,
  the apt source lists, the pin file and the keyring, the firewall rules, the customer's files, database rows, mail
  file, cron job, SSH key, backup, SSL certificate and the customer's own nginx include files. The customer site still
  answers with its marker and its `X-Customer-Include-Ssl` header.
- **Changed, content:** the customer's DNS zone: the record `webmail` changed from `CNAME mail.shop.example.org.` to
  `A <public ip of the server>` (and the SOA serial rose by 2). `v-rebuild-mail-domain` deletes and re-adds the
  webmail record. With `--open-network` also `/etc/nginx/conf.d/cloudflare.inc`: the update replaces the whole file
  with the list from `api.cloudflare.com`, and the line the seed had added by hand was gone.
- **Changed, permissions only (17):** the user rebuild sets `web`, `conf/mail` and the domain directories to 751,
  `conf/dns` to `bind:bind`, `cron.conf` to 660, and the log symlinks under `web/<domain>/logs` to `root:root`.
- **Rewritten with identical content (36):** every generated nginx, PHP-FPM, mail and user config and the
  `document_errors` pages of each domain. An admin edit inside one of these generated files would be lost.
- **Network during the update:** the own repo (`/dists/noble/InRelease`, `Packages.gz`, the deb, `pubkey.gpg`) and
  `api.cloudflare.com` (`curl` in `upgrade_cloudflare_ip`, every time, it is not gated by `UPSTREAM_UPDATES`).
  `telemetry.sury.org` is asked by the sury build of php-fpm when the update restarts it. Nothing else.
- The upgrade log says "Starting upgrade from 1.10.5 to 1.10.5 ... applying patches and updates for version v1.10.6":
  `install/upgrade/versions/1.10.6.sh` runs on every update because `VERSION` stays at 1.10.5.

## What it proves, and what it does not

Proves, for the configuration it installs (see step 3) on Ubuntu 24.04 and for an update from revision 100 to
101 of the same base version through `v-update-sys-vylaris`: which of the listed things are touched by the
real postinst, the upgrade scripts and the user rebuild; which hosts the update tries to reach; that the
update works with the network closed except the repo.

Does not prove:

- A **version bump** (e.g. 1.10.5 to a higher base version with new `install/upgrade/versions/*.sh`). A and B
  have the same base version `1.10.5`; the scripts in `versions/` that are newer than `VERSION`
  (`1.10.6.sh` in the current tree) do run, see `upd/hst_backups/*/hst-upgrade-*.log`.
- Services that are not installed here (Apache, multi-PHP, FTP, ClamAV, SpamAssassin, Fail2Ban, PostgreSQL),
  Let's Encrypt, real mail delivery, DKIM, quota, cluster, the web terminal, the API with keys, 2FA.
- Other distributions or architectures, and the stage-2 packages (`hestia-nginx`, `hestia-php` come from
  upstream and are not updated by this test).
- The accident case that the upstream `hestia` package is installed over ours (not part of this harness).
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
