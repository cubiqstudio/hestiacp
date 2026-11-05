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

| File                  | Purpose                                                                                      |
| --------------------- | -------------------------------------------------------------------------------------------- |
| `make-signing-key.sh` | Create a new signing key pair (offline primary key, signing subkey, revocation cert)         |
| `repo-init.sh`        | Create the reprepro layout, suites, public key, sample nginx config                          |
| `repo-publish.sh`     | Add debs, verify the signature chain, keep the last 3 builds, store the source archive       |
| `client-setup.sh`     | Run on a server: keyring, source list, pins, optional credentials                            |
| `setup-repo-host.sh`  | ONE script: runs all of the above on a fresh machine and exposes it with a Cloudflare tunnel |

All scripts: `--help` prints the usage. They are plain bash, `shellcheck` clean, and refuse to work
inside a git working tree where that would leak secrets or mix packages into the source tree.

## Repository host installer (`setup-repo-host.sh`): everything in one script

For the owner who does not want to run the four scripts by hand. On a fresh Debian 12/13 or Ubuntu
22.04/24.04 machine (root, a git checkout of this repository on it) one command creates the signing
key, the apt repository, the web server, a Cloudflare Tunnel with your domain, builds and publishes the
panel package, checks everything and prints the command for a new panel server. It does not duplicate
the other scripts: it calls `make-signing-key.sh`, `repo-init.sh`, `repo-publish.sh` (and prints the
`client-setup.sh` / installer commands).

You need, once:

1. A domain whose DNS is on Cloudflare (a free account is enough). The host name you choose
   (for example `repo.example.com`) must be **dedicated to this repository** (see section 5, the pin
   is bound to the host name). It must be **one label below the zone** (`repo.example.com` in
   `example.com`): the free Universal SSL certificate covers `example.com` and `*.example.com` only, so
   `repo.srv.example.com` would fail on https. The script refuses such a name (`--allow-deep-host` if you
   have an Advanced Certificate).
2. A Cloudflare **API token**. Dashboard: _My Profile_ (top right) > _API Tokens_ > _Create Token_ >
   _Create Custom Token_ (newer dashboards also offer _Manage Account_ > _Account API Tokens_; the
   wording differs a little). Permissions. The dashboard labels them _Edit_ and _Read_; the API
   documentation calls the same permissions _Cloudflare Tunnel Write_ (or _Cloudflare One Connectors
   Write_), _DNS Write_ and _Zone Read_:

   | Scope   | Resource          | Dashboard label | API documentation                                            |
   | ------- | ----------------- | --------------- | ------------------------------------------------------------ |
   | Account | Cloudflare Tunnel | Edit            | Cloudflare Tunnel Write (or Cloudflare One Connectors Write) |
   | Zone    | DNS               | Edit            | DNS Write                                                    |
   | Zone    | Zone              | Read            | Zone Read                                                    |

   _Account Resources_: Include > the account that owns the zone. _Zone Resources_: Include > the zone
   of your domain (or all zones). _Continue to summary_ > _Create Token_, copy the token (shown only
   once). The two permissions that change something must be **Edit**; _Read_ is not enough for them (the
   script can only check that the token can read; it finds out about the write permissions when it creates
   the tunnel, which is the first thing it creates).

3. **Cloudflare Zero Trust (Cloudflare One) must be activated in the account.** Tunnels belong to that
   product: in the dashboard open _Zero Trust_ once. It may ask for a one-time setup (a team name and a plan;
   the free plan is offered). This is **unverified**: it was not tried against a real account here, and the
   dashboard wording changes. If the script reports an error while creating the tunnel although the token
   has the permissions, check this first.
4. **The checkout on the repository machine.** The script must run from a git checkout of this repository
   (`git clone`), and the build runs programs of that checkout **as root**. So use **your own clean clone**
   that nobody else can write to, not a shared directory. A normal `git clone` as your own user and then
   `sudo bash src/vylaris/setup-repo-host.sh ...` works (directories 775 with your private group are
   accepted; the script refuses a checkout that belongs to a third user, that every user can write to, or
   that a group with other members can write to; it looks at the checkout directory, `.git`, `.git/config`,
   `.git/hooks` and `src/`, not at the rest of the tree). For a **private fork** on GitHub the new machine needs
   credentials to clone: clone as root with a personal access token or a read-only **deploy key**
   (GitHub: repository > Settings > Deploy keys; put the private key in `/root/.ssh/` with mode 600 and use the
   `git@github.com:...` address), or clone as your own user with your credentials and run the script with `sudo`.
   If you copied the files instead of cloning: `git init`, commit them, and `chmod -R go-w` the directory
   (the script also needs `.git` for the source archive of the package).

This is a **private** repository for your own servers. Do not use it as a high-volume public mirror on a
free Cloudflare plan: that can breach Cloudflare's CDN terms of service. If `apt` gets a 403 from the public
name (Cloudflare's Browser Integrity Check or Bot Fight Mode takes `apt` for a bot), add a WAF custom rule
with the action _Skip_ (for Browser Integrity Check and Bot Fight Mode) for the host name and the paths
`/dists/` and `/pool/`. Also allow **outgoing port 7844** (TCP and UDP) on the repository machine:
`cloudflared` connects to Cloudflare through it.

Then, as root on the repository machine:

```bash
git clone <your repository> && cd <it>        # as root, or as your user and then use sudo below
CLOUDFLARE_API_TOKEN=... bash src/vylaris/setup-repo-host.sh --domain repo.example.com
```

Better for the shell history: run it without the token and type it into the hidden prompt, or
`--cf-token-file FILE`. Without `--domain` the script asks. At the end it prints, and saves in
`/root/vylarisspace-repo-host/CLIENT-INSTALL.txt` (mode 600), the URL, the **fingerprint of the signing
key** and the exact commands for

- a **new panel server** (`install/hst-install-ubuntu.sh --vylaris-repo https://DOMAIN --vylaris-key-fingerprint FPR`,
  the repository login in the environment variable `VYLARIS_REPO_AUTH`), and
- a server with the panel **already installed** (`client-setup.sh --repo https://DOMAIN --key-fingerprint FPR --update`).

The login is offered in two forms: typed at a hidden prompt (nothing in the shell history) and as an
environment prefix `VYLARIS_REPO_AUTH='user:password'` (stays in the history). The hidden-prompt form is **one
line** joined with `&&` (`read -r -s -p ... VYLARIS_REPO_AUTH && echo && export VYLARIS_REPO_AUTH && bash ...`):
paste it as a whole; with two separate lines `read` would swallow the second line. The installer option
`--vylaris-repo-auth` is **not** printed: it would show the password in `ps` while it runs. The password
is printed in the terminal **only once**: by the first run that completes after it was generated. Every
later run (and `--print-client-command`) names the file `repo-auth` instead. To see it again:

```bash
bash src/vylaris/setup-repo-host.sh --print-client-command --show-login # changes nothing
cat /root/vylarisspace-repo-host/CLIENT-INSTALL.txt                     # mode 600, always has it
```

`--show-login` alone (without `--print-client-command`) is only a modifier of an installer run: that run
prints the login in its summary.

### What it does

| Step | What                                                                                                                                                                                                                                                                                                                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Root, supported system; installs `reprepro gnupg nginx curl jq openssl git ...`; then every refusal that can be known in advance (checkout, version to build, disk space, repository directory, nginx site and port, token read access, zone, existing DNS and tunnel); **last, creates the tunnel** (the first write with the token) |
| 2    | Signing key with `make-signing-key.sh` (generated passphrase in `key.pass`, never printed; a second GnuPG home with only the signing subkey for reprepro)                                                                                                                                                                             |
| 3    | Repository `/srv/vylarisspace-repo` with `repo-init.sh --server-name DOMAIN` (`--staging` optional)                                                                                                                                                                                                                                   |
| 4    | nginx site `/etc/nginx/conf.d/vylarisspace-repo.conf`: only `127.0.0.1:8088`, plain http, root `<repo>/public`, no listing, headers, basic auth (generated login)                                                                                                                                                                     |
| 5    | Cloudflare API: route of the (remotely managed) tunnel `DOMAIN -> http://127.0.0.1:8088`, proxied CNAME `DOMAIN -> <id>.cfargotunnel.com`, tunnel run token                                                                                                                                                                           |
| 6    | `cloudflared` from `pkg.cloudflare.com` (key fingerprint pinned), systemd service `vylarisspace-tunnel`, waits until the tunnel is healthy                                                                                                                                                                                            |
| 7    | Builds the `hestia` package from this checkout (`src/hst_autocompile.sh --hestia --noinstall --keepbuild --pkgrev N '~localsrc'`) or takes `--deb FILE`; publishes with `repo-publish.sh`                                                                                                                                             |
| 8    | Verifies: local nginx (401 without login, 200 with), signature of `InRelease` against the exported key, private paths closed, then `https://DOMAIN/dists/CODENAME/InRelease` (retries up to 90 s)                                                                                                                                     |
| 9    | Summary in German and English, `CLIENT-INSTALL.txt`                                                                                                                                                                                                                                                                                   |

Every step is idempotent and says `[done]` or `[skipped]`. A second run never creates a second signing
key or tunnel, never changes the repository login, the passphrase or the tunnel token, and leaves nginx
and the service alone when they are right. If it stops, run the same command again: it resumes.
Only one run at a time (a lock file `/run/vylarisspace-repo-host.lock`; `/run/lock` is only the fallback).
Step 1 first installs the packages and makes the empty state directory (that is all it does before the checks).
The refusals that can be known in advance then come **before the signing key, the repository, the nginx site, the tunnel
and the DNS record exist**: wrong token, missing read permission, domain not in the account, a domain
too deep below the zone, an existing A/AAAA/CNAME record of the domain (replace only with `--force-dns`;
a CNAME to **another** tunnel counts as foreign, only a CNAME to the tunnel of this machine is ours), a
tunnel of the same name that is not completely empty (no ingress, no catch-all rule, no warp routing) or
has a local config file, a busy port (`--listen-port`), an nginx site `vylarisspace-repo.conf` that this script
did not write (`--force`), a repository directory that is not empty and not ours, a checkout that belongs to
somebody else or is writable by others, a dirty checkout when a package has to be built or published, too little disk
space (also the 3 GB for a build, but only when a build is needed), and a changed `--domain`, `--tunnel-name`
or `--state-dir`. Two things can only fail later, on purpose, and leave
what was done in place (the same command resumes): a missing **write** permission for DNS (the tunnel
write permission fails in step 1; the DNS one in step 5, after key, repository, nginx and the tunnel with its route
exist), and an `nginx -t` failure (the previous nginx setup is restored). A refused
run prints the reason and nothing else; after exit 3, 4 and 5 it adds that the same command resumes.
Further refusals: a different `--auth-user` than the existing login, and a different `--domain` than the saved
one (compared after lower-casing and removing a trailing dot); `--delete-dns` without `--uninstall-tunnel` is a usage
error (exit 1).

**The signing key and the login are never replaced by accident.** The state directory is recorded in
`/etc/vylarisspace-repo-host/state-dir` as soon as the signing key exists in it (an empty directory of a run that
failed early pins nothing; to use another directory then, delete that file only if the old directory has no
`keys/` yet); a later `--state-dir` that differs is refused (exit 2). A changed `--tunnel-name` is refused as well
once a tunnel is in the state (a new name would mean a second tunnel). If a
repository, a password file or a tunnel token of an earlier run exists but the key or the login of the
state directory is missing (directory lost, moved, wrong `--state-dir`), the script stops instead of
creating a new key or password that would lock out every server. The public key of the repository must
have the fingerprint of the key in the state directory. A state directory that already exists must be
empty and private or carry the marker file `.vylarisspace-repo-host-state`; the script never changes the
mode of a directory it did not create, and refuses relative paths and system directories. A repository
directory that holds only what `repo-init.sh` makes before its last step (empty directories, an empty
`conf/distributions`) is the leftover of a stopped run and is continued; anything else in it is refused.

**Tunnel and DNS are only touched when they are ours.** An existing tunnel of the same name is taken over
only when it is completely empty; the state remembers whether the script created the tunnel
(`TUNNEL_CREATED=yes`). `--uninstall-tunnel --delete-dns` deletes the tunnel only in that case, otherwise it
says so and leaves it. DNS lists are asked with `name.exact=` and checked again on the host name, so a
record of another name is never changed. `--force-dns` first writes the old records (type, content, ttl,
proxied) to the log and to `dns-backup-*.json` (mode 600) in the state directory, then changes the record
in place (an A record becomes the CNAME without a gap) and deletes the others afterwards. Cloudflare does
not allow a CNAME next to an A/AAAA record; if it refuses the change with an answer about the content (HTTP 400 or
409), the other records are deleted first (they are in the backup file). Any other failure of that change (401/403: the
token lacks DNS Edit; 429; a 5xx; no answer) stops the run with exit 4 and **deletes nothing**. A DNS record creation that ended in an error is checked again before it is
reported as failed. HTTP 429 is answered with the `Retry-After` wish of Cloudflare (at most 60 s, a longer
wish stops the run; run it again later; leading zeros are ignored).

The package: version `<base>-<pkgrev>+<distro>`, default revision 100, the suite is the codename of this
machine (a deb built here is only for this system; the script does not claim support for other
codenames, `--deb FILE` publishes whatever suites the files belong to). If that version or a newer one is
already published, the build is skipped (`--rebuild` builds and publishes the next revision, for example
after a `git pull`). Whether the version is published already is decided **first**: a rerun that builds nothing
is not refused because the tree is dirty. When a build or a `--deb` publish is going to happen, a checkout with
uncommitted changes or untracked files is refused in step 1 ("commit your changes (`git add <files>; git commit`) or
move stray files out of the checkout"; `--allow-dirty` overrides; the source archive for the GPL offer then lacks the
changes). Building needs internet (npm,
Packagist) and about 3 GB free in `/var/tmp`; `src/hst_autocompile.sh` installs Node.js and Composer
itself when they are missing.

### Options

| Option                                     | Meaning                                                                                                                                                                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--domain NAME`                            | Host name of the repository (default: the saved one, else the script asks)                                                                                                                                   |
| `--cf-token-file FILE`                     | Token from a file (first line); else `CLOUDFLARE_API_TOKEN`; else hidden prompt                                                                                                                              |
| `--public` / `--auth`                      | No password / password protection (default on; the choice is saved)                                                                                                                                          |
| `--auth-user NAME`                         | User name of the generated login (default `vylaris-server`)                                                                                                                                                  |
| `--staging`                                | Also create `<codename>-staging` suites (only for a new repository)                                                                                                                                          |
| `--listen-port PORT`                       | Local port of the site (default 8088)                                                                                                                                                                        |
| `--repo-dir DIR`, `--state-dir DIR`        | Defaults `/srv/vylarisspace-repo`, `/root/vylarisspace-repo-host` (the state dir is saved)                                                                                                                   |
| `--show-login`                             | Modifier: the run prints the login. To only print it: `--print-client-command --show-login`                                                                                                                  |
| `--deb FILE` (repeatable)                  | Publish these packages instead of building                                                                                                                                                                   |
| `--rebuild`, `--pkgrev N`, `--allow-dirty` | Package build control                                                                                                                                                                                        |
| `--tunnel-name NAME`                       | Tunnel name (default `vylarisspace-repo`)                                                                                                                                                                    |
| `--force-dns`                              | Replace an existing A/AAAA/CNAME record of the domain (old records are saved first)                                                                                                                          |
| `--force`                                  | Overwrite an nginx site `vylarisspace-repo.conf` that this script did not write                                                                                                                              |
| `--allow-deep-host`                        | Accept a domain more than one label below the zone (needs an Advanced Certificate)                                                                                                                           |
| `--skip-tunnel-service`                    | Only the API part; prints the `docker run` / `cloudflared` command to run it yourself (the summary then says the tunnel is NOT running yet; exit 0)                                                          |
| `--cloudflared-deb FILE`                   | Install cloudflared from this file (offline or own build)                                                                                                                                                    |
| `--print-client-command`                   | Print the commands for new servers again (no changes)                                                                                                                                                        |
| `--status`                                 | nginx, service, tunnel (needs the token; Enter at the prompt, or an API problem, prints `not checked`), published versions; exit 6 if something is down                                                      |
| `--uninstall-tunnel` [`--delete-dns`]      | Remove the cloudflared service; with `--delete-dns` also the DNS record (and the tunnel, if this script created it); the token is tried first, a wrong one removes nothing. `--delete-dns` alone is an error |
| `-y`, `--yes`                              | No confirmation questions                                                                                                                                                                                    |

Exit codes: 0 done, 1 usage, 2 refused (nothing damaged), 3 this machine cannot do it (not root,
system, tool, disk), 4 Cloudflare API error (with a hint: wrong token, missing permission, domain not in
the account), 5 build or publish failed, **or the local check of the new repository failed** (nginx or the repository on this
machine is wrong: waiting does not help, the message says where to look), 6 installed but the public check did not pass yet
(the public address does not answer yet, the tunnel is not healthy: wait a few minutes, run the same command again; if
it stays so, check that the machine may connect **outward to port 7844, TCP and UDP**, which `cloudflared` needs).
After exit 3, 4 and 5 the script prints that the same command resumes (after 1 and 2 the error says what to fix).
A tunnel that Cloudflare reports as `degraded` (up with reduced redundancy) counts as working. The log
(`/var/log/vylarisspace-repo-host.log`, mode 600, timestamps, no secrets) and the build log
(`.build`) are next to it.

### Where things are, and what to back up

```text
/root/vylarisspace-repo-host/      (mode 700)  BACK UP THIS DIRECTORY, to another machine
  keys/out/                        public key, revocation certificate, secret key exports (mode 600)
  keys/gnupg-primary/              the primary key (passphrase protected)
  keys/gnupg-signing/              signing subkey only, used by reprepro
  key.pass                         passphrase of the secret keys (mode 600, never printed)
  repo-auth                        user:password of the repository (mode 600)
  state.env                        domain, tunnel id, TUNNEL_CREATED, port, key fingerprint (no secrets)
  CLIENT-INSTALL.txt               the commands for new servers (mode 600)
  dns-backup-*.json                records that --force-dns replaced (mode 600)
  .vylarisspace-repo-host-state    marker: this directory was created by the script
/etc/vylarisspace-repo-host/state-dir    where the state directory is (a different one is refused); written once the signing key exists
/etc/vylarisspace-repo-host/tunnel.env   tunnel run token (mode 600), read by the service
/etc/nginx/conf.d/vylarisspace-repo.conf, /etc/nginx/vylarisspace-repo.htpasswd (640 root:www-data)
/etc/nginx/vylarisspace-repo.conf.bak    the original of a site that this script did not write (only with --force; the first copy is never overwritten, a second original gets .bak.<date>)
/etc/systemd/system/vylarisspace-tunnel.service
/srv/vylarisspace-repo/            the repository; back up conf/ db/ archive/ public/ as well
/run/vylarisspace-repo-host.lock   the lock of a running script (/run is writable by root only)
```

**If the signing key is lost, every server has to be set up again** with a new key and a new
fingerprint; the repository cannot be signed by anyone else. Keep the backup of `keys/` and `key.pass`
apart (password manager). The primary key stays on the machine, protected by the passphrase that lies
next to it; for more safety follow section 1 ("offline primary key"): copy `keys/out` to offline media and
remove `secret-primary-*` and `keys/gnupg-primary` afterwards. The script never deletes keys.

### Secrets

- The Cloudflare API token is read once from the file, the environment or the hidden prompt, removed from
  the environment (programs started by the script do not inherit it) and passed to `curl` only as
  configuration on standard input. It is never in a command line, never in a file, never in the log and
  never printed. Tracing (`bash -x`) is switched off. It is not needed after the run (except `--status`
  and `--uninstall-tunnel --delete-dns`): delete it in the dashboard. Residual exposure: it lives in the
  memory of the script (and in the shell history if you typed `CLOUDFLARE_API_TOKEN=...` on the command
  line).
- The **tunnel run token** is fetched from the API and written to `/etc/vylarisspace-repo-host/tunnel.env`
  (mode 600). The service reads it with `EnvironmentFile=`, so the daemon's command line is only
  `cloudflared --no-autoupdate tunnel run` and the unit file (mode 644) contains no secret. Design
  rationale (not something that was tested here): with `cloudflared service install TOKEN` the token would
  be on the command line / in the unit file as `--token`, where other users could read it; this script
  avoids that by an `EnvironmentFile`. The answer of the API that carries the token is kept only in a
  private temporary directory (on `/run`, a memory file system, when there is one) and wiped as soon as the
  token has been read. Residual exposure: root, and the process environment of the service (readable by
  root only).
- The repository password is generated (`openssl rand`), saved in `repo-auth` (600), and hashed in the
  htpasswd file (apr1). It is shown in the terminal once (the first completed run, or `--show-login`) and
  is always in `CLIENT-INSTALL.txt` (600), so you can give it to your servers. Servers store it in
  `/etc/apt/auth.conf.d/vylarisspace.conf` (600).
  `client-setup.sh` refuses to send credentials over plain `http://`; use the https address.
- Cloudflare terminates TLS: Cloudflare can see the (signed, public) package traffic and the login.
  The packages are signed, so a tampered download is rejected by apt; the login only decides who may
  download. Use a separate login per server if you need to lock out one server (`htpasswd`, section 4).

### cloudflared from the Cloudflare repository

The script adds `deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main`
and refuses unless the downloaded key has exactly one primary key with the fingerprint (it tries
`https://pkg.cloudflare.com/cloudflare-public-v2.gpg` first and `.../cloudflare-main.gpg` second; the same
fingerprint is required from either)

```text
CC94B39C77AE7342A68B89628A682D308D4E5E73   CloudFlare Software Packaging 2025 <help@cloudflare.com>
```

How this was checked (2026-11-05, from the build machine through its web proxy): the key was fetched from
`cloudflare-public-v2.gpg`, `cloudflare-main.gpg` and `cloudflare-ascii-pubkey.gpg` (the same key), the
`InRelease` of `.../cloudflared/dists/any/` carried a good signature of that key (the file is signed twice:
the second signature is by an older key `254B391D8CACCBF8` that is not in this keyring, apt needs one valid
signature), and `apt-get install cloudflared` worked in the test containers. The fingerprint was read from
`pkg.cloudflare.com` itself and was **not** compared with a second, independent source (for example a
printed page of Cloudflare's documentation). Do that before you trust it, and if Cloudflare rotates its key the script stops with a clear message: update
the constant `CFD_KEY_FPR` or install cloudflared yourself and pass `--cloudflared-deb FILE`.

### Maintenance

- New panel version: `git pull`, then `bash src/vylaris/setup-repo-host.sh --rebuild` (token needed only for
  the API checks; the same token or a new one).
- `bash src/vylaris/setup-repo-host.sh --status`, `--print-client-command`.
- Stop the tunnel: `--uninstall-tunnel` (service only) or `--uninstall-tunnel --delete-dns` (also the DNS
  record and the tunnel at Cloudflare). The repository, nginx site and keys stay. Another domain: do
  `--uninstall-tunnel --delete-dns` first, then run with the new `--domain`; the key stays the same.
- DNS and tunnel can need a few minutes after the first run; exit code 6 and the message say so.
- The unit starts `cloudflared` by its real path (`readlink -f`), so a link such as `/usr/local/bin/cloudflared`
  does not matter.

### Tests of the host installer

`test/vylaris-repo-host/` (needs Docker and the two prebuilt test packages of
`test/vylaris-upgrade/build-debs.sh`, found in `/tmp/vylaris-upgrade-test/debs` or built on the way):

```text
mock-cloudflare.py   stand-in for the Cloudflare API (Python 3 standard library): exactly the endpoints the script
                     uses, Bearer token check, Cloudflare style answers, wrong token / missing permission / zone
                     not found / foreign DNS record / existing tunnel / "HTTP 500 once" / "429 with Retry-After" /
                     "record created although the answer was a 500" on demand; the DNS list honours ONLY
                     name.exact (everything else returns all records), tunnel "connections" is always empty
                     (deprecated), plus an "edge" on https that forwards to the tunnel route once a tunnel is
                     connected
guest.sh             runs inside the container: fresh Ubuntu/Debian with only python3 and openssl added
run.sh               builds the image, copies the checkout in, starts the container, prints PASS/FAIL lines
Dockerfile
```

```bash
test/vylaris-repo-host/run.sh # profile a on ubuntu:24.04
test/vylaris-repo-host/run.sh --profile b --image debian:12
```

The logs go to a new directory from `mktemp -d` under `/tmp` (printed at the end); `--result DIR` is accepted
only for a new or empty directory, the runner never deletes anything there.

Profiles: `a` (error cases: API base, state directory and lock, foreign DNS records and tunnels, zone depth,
rate limit including `Retry-After` with leading zeros; a token that may only read tunnels, too little disk for the
build, a dirty checkout and a foreign repository directory, all refused in step 1 with nothing created; full run
with decoys in the mock, an interrupted first run, idempotency, nginx login, signature, `CLIENT-INSTALL.txt`
(one-line login forms), password printed once, secret scan, lost state / key / login, a renamed `--tunnel-name`,
files that are not keys, the checkout rules (other owner, a plain user clone with 775 and a private group, a group
with other members, world-writable `.git/config`, `.git/hooks`, `src/`), the lock in `/run`, `client-setup.sh`
and `apt-get install -s hestia`, `--status` (also with a wrong token), `--print-client-command`, `--public` /
`--auth` and the saved mode, uninstall with a wrong token (nothing torn down) and resume),
`b` (`--force-dns` in place and with A + AAAA, a PATCH that fails with 500/403 and deletes nothing, foreign nginx
site and its single `.bak`, a repository directory that holds only the `repo-init.sh` skeleton, the export under
`umask 022`, a 2 MB `nginx -T` output, busy port, `nginx -t` rollback, `--skip-tunnel-service` and its headline,
`--public`, `--staging`, several suites, the build path, a rerun that builds nothing on a dirty tree, untracked
files, a DNS record that was created although the answer was a 500, a token that may read but not write DNS,
a failing local check (exit 5), an unreachable public address, a degraded tunnel, token file and hidden prompt on a
pty (also Enter alone), `bash -x`),
`cfd` (the real `pkg.cloudflare.com`, a fake one that must be refused, the second key address, a captive-portal page
at the first or at both key addresses), `build` (the real `hst_autocompile.sh` build). The container has no
systemd: `systemctl` is a stub that starts the `ExecStart` of the unit with its `EnvironmentFile`, `cloudflared` is
a stub package (`--cloudflared-deb`) that tells the mock that the tunnel is connected, `df` is a stub that can report
a full `/var/tmp`; the unit file is checked with the real `systemd-analyze verify`. The Cloudflare API itself is never
contacted (profile `cfd` and `build` do use the network: `pkg.cloudflare.com`, npm, Packagist).

Result of the last run of the whole set, after the last change of the script (all with `0 failed`): profile `a`
451 checks on each of `ubuntu:24.04`, `ubuntu:22.04` and `debian:12`; profile `b` 165 checks on `ubuntu:24.04`;
profile `cfd` 38 checks on `ubuntu:24.04`; profile `build` 5 checks on `ubuntu:24.04`. Not run: profile `b`, `cfd` and
`build` on the other images.

Not covered by these tests: the real Cloudflare API (answers of the mock follow the documented shape and were
not compared with live responses), a real tunnel connection, real DNS and a real Cloudflare certificate, systemd as
PID 1 (only the unit syntax was verified), Debian 13.

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

- The package build of the host installer (profile `build` of `test/vylaris-repo-host/`) ran once, on
  `ubuntu:24.04` in a container with Node.js and Composer installed by `hst_autocompile.sh`: it built a real
  `hestia_1.10.5-100+ubuntu24.04_amd64.deb` from the checkout and published it into a test repository (5 checks
  passed; its output was not installed on a machine). Other distributions and architectures were not built; no
  package was published on a real host, and the other tests used dummy debs with the same package name and
  version scheme.
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
