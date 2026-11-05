#!/usr/bin/env bash
# setup-repo-host.sh - VylarisSpace repository host installer
#
# ONE script that turns a fresh Debian or Ubuntu machine into the VylarisSpace apt repository and
# makes it reachable on the internet through a Cloudflare Tunnel under a domain you choose. No
# open port, no certificate to manage: Cloudflare terminates TLS, the tunnel carries the traffic.
#
# Run it as root, from a git checkout of this repository (the script lives in it). Building the
# package runs programs of the checkout as root: use your own clean clone, not a shared directory.
#
#   CLOUDFLARE_API_TOKEN=... bash src/vylaris/setup-repo-host.sh --domain repo.example.com
#
# or just  bash src/vylaris/setup-repo-host.sh  and answer the questions (the token is typed
# hidden). Running it again is always safe: it resumes, skips what is done, and never creates a
# second signing key or a second tunnel and never changes a password.
#
# What it does (each step says what it did or skipped):
#   1. checks the system, installs the packages it needs, makes the checks that can refuse the run (the
#      checkout, disk space, nginx site and port, the Cloudflare token with read access, the domain, DNS
#      and tunnel), then creates the Cloudflare tunnel: the first write with the token, so a token without
#      write permission stops the run before the key and the repository exist
#   2. creates the package signing key (make-signing-key.sh) - ONCE
#   3. creates the apt repository /srv/vylarisspace-repo (repo-init.sh)
#   4. nginx: a separate site on 127.0.0.1:8088 (basic auth on, unless --public)
#   5. Cloudflare API: tunnel route to the local site, DNS record for your domain
#   6. cloudflared from the Cloudflare apt repository, as a systemd service
#   7. builds the panel package from this checkout (or --deb FILE) and publishes it (repo-publish.sh)
#   8. verifies it end to end (local, signature, public URL)
#   9. prints the command for a new panel server and saves it in
#      /root/vylarisspace-repo-host/CLIENT-INSTALL.txt (mode 600) together with the key fingerprint
#
# Usage:
#   setup-repo-host.sh [options]
#
# Main options:
#   --domain NAME          host name of the repository, for example repo.example.com. It must be
#                          dedicated to this repository and its DNS zone must be on Cloudflare.
#                          Without it: the value of the last run, else the script asks.
#   --cf-token-file FILE   file with the Cloudflare API token (first line). Otherwise the
#                          environment variable CLOUDFLARE_API_TOKEN, otherwise the script asks
#                          (hidden input). The token is never put on a command line, never printed
#                          and never written to the log.
#   --staging              also create <codename>-staging suites (only when the repository is new)
#   --public               no password: anybody who knows the address may download. Default: a
#                          generated user and password (saved in repo-auth, mode 600).
#   --auth                 go back to password protection after a --public run
#   --auth-user NAME       user name of the generated login (default vylaris-server)
#   --listen-port PORT     local port of the repository site (default 8088, loopback only)
#   --repo-dir DIR         repository directory (default /srv/vylarisspace-repo)
#   --state-dir DIR        keys, login, state (default /root/vylarisspace-repo-host). It is saved in
#                          /etc/vylarisspace-repo-host/state-dir; a different value later is refused
#                          (a new directory would mean a new signing key and a new password).
#   --show-login           only a modifier: print the repository login (user:password) in the output of
#                          the run it is given to. To just print it again, change nothing:
#                            bash setup-repo-host.sh --print-client-command --show-login
#                          or: cat /root/vylarisspace-repo-host/CLIENT-INSTALL.txt (mode 600).
#                          Without it the password is printed only once (the first run that completed
#                          after it was created); later runs name the file repo-auth instead.
#
# Package options:
#   --deb FILE             publish this hestia .deb instead of building (repeatable)
#   --rebuild              build and publish a NEW revision although this version is published
#   --pkgrev N             package revision of the build (default 100, or the next free one)
#   --allow-dirty          build/publish although the checkout has uncommitted or untracked files
#                          (the source archive then lacks them)
#
# Cloudflare / tunnel options:
#   --tunnel-name NAME     name of the tunnel (default vylarisspace-repo)
#   --force-dns            replace an existing A/AAAA/CNAME record of the domain (default: refuse).
#                          The old records are written to the log and to dns-backup-*.json in the
#                          state directory first. A CNAME to ANOTHER tunnel counts as foreign too.
#   --allow-deep-host      accept a domain that is more than one label below the zone
#                          (repo.srv.example.com in example.com): the free Cloudflare certificate
#                          covers only *.example.com, so https would fail there. Default: refuse.
#   --force                overwrite /etc/nginx/conf.d/vylarisspace-repo.conf although it was not
#                          written by this script (a copy is kept as /etc/nginx/vylarisspace-repo.conf.bak)
#   --skip-tunnel-service  only do the API part (tunnel, route, DNS); do not install cloudflared
#                          and print the docker/cloudflared command to run it yourself. The tunnel is
#                          then NOT running until you start it: the summary says so (exit code 0).
#   --cloudflared-deb FILE install cloudflared from this .deb (offline) instead of from the
#                          Cloudflare apt repository
#
# Other modes:
#   --print-client-command show the command for a new panel server again (no changes)
#   --status               nginx, cloudflared, tunnel (needs the token; Enter at the prompt skips that
#                          check, and so does an API problem), published versions
#   --uninstall-tunnel     stop and remove the cloudflared service. With --delete-dns the DNS
#                          record is deleted through the API as well, and the tunnel too, but only
#                          when this script created it (otherwise it is left alone).
#   --delete-dns           only together with --uninstall-tunnel (otherwise exit 1); needs the token.
#                          The token is tried first: a wrong token stops before anything is removed.
#   -y, --yes              do not ask for confirmation
#   -h, --help             this text
#
# Cloudflare API token - create it once in the Cloudflare dashboard:
#   My Profile (top right) > API Tokens > Create Token > Create Custom Token (the wording may differ
#   a little: newer dashboards also have Manage Account > Account API Tokens). Permissions (the
#   dashboard says Edit/Read; the API documentation calls them Write/Read):
#     Account   Cloudflare Tunnel   Edit   ("Cloudflare Tunnel Write", or "Cloudflare One Connectors Write")
#     Zone      DNS                 Edit   ("DNS Write")
#     Zone      Zone                Read   ("Zone Read")
#   Account Resources: Include > the account that owns the zone.  Zone Resources: Include > the zone
#   of your domain (or all zones). Continue to summary > Create Token > copy it (shown only once).
#   The token is only needed while this script runs (and for --status / --uninstall-tunnel with
#   --delete-dns); you may delete it in the dashboard afterwards.
#
# Environment:
#   VYLARIS_CF_API_BASE    Cloudflare API base URL (default https://api.cloudflare.com/client/v4);
#                          for tests against a mock. Must be https://, except for 127.0.0.1/localhost.
#   VYLARIS_HOST_LOG       log file (default /var/log/vylarisspace-repo-host.log, no secrets)
#   VYLARIS_TUNNEL_WAIT    seconds to wait for a healthy tunnel (default 90)
#   VYLARIS_VERIFY_WAIT    seconds to wait for the public URL (default 90)
#   VYLARIS_CF_RETRY_DELAY seconds between API retries, times the attempt number (default 2)
#
# Exit codes:
#   0 done   1 usage error   2 refused (something would be overwritten or is unsafe; nothing was
#   damaged, read the message)   3 this machine cannot do it (not root, unsupported system, tool or
#   disk missing)   4 Cloudflare API error (wrong token, missing permission, domain not in the
#   account, ...)   5 package build or publish failed, or the local check of the new repository failed
#   (a fault on this machine: waiting does not help)   6 installed, but the public address does not
#   answer yet or the tunnel is not healthy yet: wait a few minutes and run the same command again.
#   The tunnel needs outgoing TCP and UDP port 7844 (cloudflared to Cloudflare).
# After exit 3, 4 or 5 the script says that the same command resumes where it stopped.
# The files of the other scripts in this directory are used, not copied: make-signing-key.sh,
# repo-init.sh, repo-publish.sh. Clients use client-setup.sh or the installers.

set -euo pipefail
umask 077
# Never trace while secrets are in use: this must come before anything reads the token.
TRACE_WAS_ON=0
case "$-" in
	*x*)
		set +x
		TRACE_WAS_ON=1
		;;
esac

PROG=$(basename "$0")
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------------------------
LOG_FILE="${VYLARIS_HOST_LOG:-/var/log/vylarisspace-repo-host.log}"
CF_BASE="${VYLARIS_CF_API_BASE:-https://api.cloudflare.com/client/v4}"
TUNNEL_WAIT="${VYLARIS_TUNNEL_WAIT:-90}"
VERIFY_WAIT="${VYLARIS_VERIFY_WAIT:-90}"
SERVICE_NAME='vylarisspace-tunnel'
UNIT_FILE="/etc/systemd/system/$SERVICE_NAME.service"
TUNNEL_ENV_DIR='/etc/vylarisspace-repo-host'
TUNNEL_ENV="$TUNNEL_ENV_DIR/tunnel.env"
# Where the state directory is recorded. A later run takes the directory from here and refuses another one.
STATE_PTR="$TUNNEL_ENV_DIR/state-dir"
STATE_MARKER='.vylarisspace-repo-host-state'
STATE_MARKER_TEXT='VylarisSpace repository host state directory (created by setup-repo-host.sh, do not remove this file)'
POLICY_RC_FILE='/usr/sbin/policy-rc.d'
POLICY_RC_MARK='# vylarisspace-repo-host: temporary file of setup-repo-host.sh, removed again by it'
NGX_CONF='/etc/nginx/conf.d/vylarisspace-repo.conf'
NGX_HTPASSWD='/etc/nginx/vylarisspace-repo.htpasswd'
# Kept outside of conf.d on purpose: an include of conf.d/* must not load the old copy as well.
NGX_BAK='/etc/nginx/vylarisspace-repo.conf.bak'
NGX_HAD=0
NGX_OLD_PORT=''
NGX_HEADER='# Managed by setup-repo-host.sh'
# Cloudflare's own apt repository for cloudflared. The fingerprint is the primary key of
# "CloudFlare Software Packaging 2025 <help@cloudflare.com>" (see README.md for how it was checked).
CFD_KEY_URLS=('https://pkg.cloudflare.com/cloudflare-public-v2.gpg' 'https://pkg.cloudflare.com/cloudflare-main.gpg')
CFD_KEY_FPR='CC94B39C77AE7342A68B89628A682D308D4E5E73'
CFD_KEY_FILE='/usr/share/keyrings/cloudflare-public-v2.gpg'
CFD_LIST_FILE='/etc/apt/sources.list.d/cloudflared.list'
CFD_REPO_LINE="deb [signed-by=$CFD_KEY_FILE] https://pkg.cloudflare.com/cloudflared any main"
DEFAULT_PORT=8088
DEFAULT_PKGREV=100
SUPPORTED='debian12 debian13 ubuntu22.04 ubuntu24.04'
PACKAGES='reprepro gnupg gpgv nginx curl jq ca-certificates openssl git util-linux iproute2 lsb-release procps'

# ---------------------------------------------------------------------------------------------
# options and state (filled by parse_args / load_state)
# ---------------------------------------------------------------------------------------------
DOMAIN=''
CF_TOKEN_FILE=''
TUNNEL_NAME=''
STAGING=0
AUTH_WANT=''
AUTH_USER=''
LISTEN_PORT=''
REPO_DIR=''
STATE_DIR='/root/vylarisspace-repo-host'
STATE_DIR_GIVEN=0
SKIP_SERVICE=0
CLOUDFLARED_DEB=''
DEBS=()
REBUILD=0
PKGREV=''
ALLOW_DIRTY=0
FORCE_DNS=0
FORCE=0
ALLOW_DEEP=0
SHOW_LOGIN_OPT=0
MODE='install'
DELETE_DNS=0
ASSUME_YES=0

CF_TOKEN=''
# The token of the environment is taken over and removed from the environment at once, so no program
# started by this script (apt, reprepro, the build) inherits it.
CF_TOKEN_ENV="${CLOUDFLARE_API_TOKEN:-}"
unset CLOUDFLARE_API_TOKEN

TMP=''
KEYGEN_TMP=''
BUILD_BASE=''
ERR_REPORTED=0
CHECKOUT=''
CHECKOUT_UID=''
STATE_FILE=''
OS_ID=''
OS_VERSION=''
CODENAME=''
HOST_ARCH=''
DISTRO_SUFFIX=''
KEY_OUT=''
SIGN_HOME=''
KEY_FPR=''
ZONE_ID=''
ZONE_NAME=''
ACCOUNT_ID=''
TUNNEL_ID=''
DNS_ACTION=''
DNS_IDS=()
DNS_OWN_ID=''
DNS_RECORDS_JSON='[]'
TUNNEL_CREATED=''
LOGIN_FRESH=0
REPO_USER=''
REPO_PASS=''
AUTH_MODE='auth'
SERVED_SUITES=''
VERIFY_SUITE=''
FINAL_RC=0
ADOPTED=0
POLICY_RC=0
TOKEN_CHANGED=0
BUILT_DEB=''
BUILD_PLAN=''
BUILD_REV=''
BUILD_VER=''
BUILD_PUB=''
NEED_BUILD=0
CF_HTTP=''
CF_BODY=''
CF_ERR=''
CF_CODES=''
TOKEN_OPTIONAL=''
ZONE_TRY_NAME=''
LOCK_FILE=''
CLEANED=''

# ---------------------------------------------------------------------------------------------
# output and log (the log has a timestamp on every line and never a secret)
# ---------------------------------------------------------------------------------------------
logf() {
	local m=${*//$'\n'/ | }
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$m" >> "$LOG_FILE" 2> /dev/null || true
}
say() {
	printf '%s\n' "$*"
	logf "$*"
}
did() { say "  [done]     $*"; }
skip() { say "  [skipped]  $*"; }
info() { say "  $*"; }
warn() {
	printf '  [warning]  %s\n' "$*" >&2
	logf "WARNING: $*"
}
step() {
	say ""
	say "== Step $1/9: $2"
}
die() {
	local code=${2:-1}
	printf 'ERROR: %s\n' "$1" >&2
	logf "ERROR: $1 (exit $code)"
	ERR_REPORTED=1
	exit "$code"
}

cleanup() {
	local rc=$?
	if [ -n "$KEY_OUT" ] && [ -d "$SIGN_HOME" ]; then
		GNUPGHOME="$SIGN_HOME" gpgconf --kill gpg-agent > /dev/null 2>&1 9>&- || true
	fi
	[ -z "$TMP" ] || rm -rf "$TMP"
	[ -z "$KEYGEN_TMP" ] || rm -rf "$KEYGEN_TMP"
	[ -z "$BUILD_BASE" ] || rm -rf "$BUILD_BASE"
	if [ "$POLICY_RC" -ne 0 ] && [ -f "$POLICY_RC_FILE" ] && grep -qF "$POLICY_RC_MARK" "$POLICY_RC_FILE"; then
		rm -f "$POLICY_RC_FILE"
	fi
	if [ "$rc" -ne 0 ] && [ "$ERR_REPORTED" -eq 0 ]; then
		printf 'ERROR: unexpected failure (exit %s). Details: %s\n' "$rc" "$LOG_FILE" >&2
		logf "unexpected failure, exit $rc"
	fi
	# (exit 1 and 2: the error already says what to fix; 6: the summary says what to do)
	if [ "$MODE" = install ]; then
		case "$rc" in
			3 | 4 | 5) printf '%s\n' "The run stopped early. Nothing is lost: run the same command again, it resumes." >&2 ;;
		esac
	fi
	return "$rc"
}

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

# Run a command, add its output to the log, show the tail and stop when it fails.
run_step() { # description exit-code command...
	local desc=$1 code=$2 out rc=0
	shift 2
	out="$TMP/run.out"
	"$@" > "$out" 2>&1 9>&- || rc=$?
	cat "$out" >> "$LOG_FILE" 2> /dev/null || true
	if [ "$rc" -ne 0 ]; then
		tail -n 15 "$out" >&2
		die "$desc failed (exit $rc). More in $LOG_FILE" "$code"
	fi
}

is_tty() { [ -t 0 ] && [ -t 1 ]; }

ask_yes() { # question -> 0 when yes
	local a=''
	if [ "$ASSUME_YES" -eq 1 ]; then
		return 0
	fi
	if ! [ -t 0 ]; then
		die "this needs a confirmation but there is no terminal. Add --yes." 2
	fi
	read -r -p "$1 [y/N] " a
	case "$a" in y | Y | yes | YES | j | J | ja) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------------------------
# state file: KEY=VALUE lines, never sourced
# ---------------------------------------------------------------------------------------------
state_get() { # key
	[ -f "$STATE_FILE" ] || return 0
	sed -n "/^$1=/{s/^$1=//p;q;}" "$STATE_FILE"
}
state_set() { # key value
	local k=$1 v=$2 tmp
	[[ $v =~ ^[A-Za-z0-9._:/@+~=-]*$ ]] || die "internal error: unsafe value for state key $k" 1
	tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
	{
		if [ -f "$STATE_FILE" ]; then grep -v "^$k=" "$STATE_FILE" || true; fi
		printf '%s=%s\n' "$k" "$v"
	} > "$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$STATE_FILE"
}
state_del() {
	local tmp
	[ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || return 0
	tmp=$(mktemp "$STATE_DIR/.state.XXXXXX")
	grep -v "^$1=" "$STATE_FILE" > "$tmp" || true
	chmod 600 "$tmp"
	mv -f "$tmp" "$STATE_FILE"
}

# Write a file that holds a secret: mode 600 from the first byte, replaced atomically.
write_secret() { # file content
	local tmp
	tmp=$(mktemp "$(dirname "$1")/.secret.XXXXXX")
	chmod 600 "$tmp"
	printf '%s\n' "$2" > "$tmp"
	mv -f "$tmp" "$1"
}

# ---------------------------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------------------------
need_value() { # option count
	[ "$2" -ge 2 ] || {
		printf '%s: %s needs a value\n' "$PROG" "$1" >&2
		exit 1
	}
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--domain)
				need_value "$1" $#
				DOMAIN=$2
				shift 2
				;;
			--cf-token-file)
				need_value "$1" $#
				CF_TOKEN_FILE=$2
				shift 2
				;;
			--tunnel-name)
				need_value "$1" $#
				TUNNEL_NAME=$2
				shift 2
				;;
			--staging)
				STAGING=1
				shift
				;;
			--public)
				AUTH_WANT=public
				shift
				;;
			--auth)
				AUTH_WANT=auth
				shift
				;;
			--auth-user)
				need_value "$1" $#
				AUTH_USER=$2
				shift 2
				;;
			--listen-port)
				need_value "$1" $#
				LISTEN_PORT=$2
				shift 2
				;;
			--repo-dir)
				need_value "$1" $#
				REPO_DIR=$2
				shift 2
				;;
			--state-dir)
				need_value "$1" $#
				STATE_DIR=$2
				STATE_DIR_GIVEN=1
				shift 2
				;;
			--deb)
				need_value "$1" $#
				DEBS+=("$2")
				shift 2
				;;
			--rebuild)
				REBUILD=1
				shift
				;;
			--pkgrev)
				need_value "$1" $#
				PKGREV=$2
				shift 2
				;;
			--allow-dirty)
				ALLOW_DIRTY=1
				shift
				;;
			--force-dns)
				FORCE_DNS=1
				shift
				;;
			--force)
				FORCE=1
				shift
				;;
			--allow-deep-host)
				ALLOW_DEEP=1
				shift
				;;
			--show-login)
				SHOW_LOGIN_OPT=1
				shift
				;;
			--skip-tunnel-service)
				SKIP_SERVICE=1
				shift
				;;
			--cloudflared-deb)
				need_value "$1" $#
				CLOUDFLARED_DEB=$2
				shift 2
				;;
			--print-client-command)
				MODE=print
				shift
				;;
			--status)
				MODE=status
				shift
				;;
			--uninstall-tunnel)
				MODE=uninstall
				shift
				;;
			--delete-dns)
				DELETE_DNS=1
				shift
				;;
			-y | --yes)
				ASSUME_YES=1
				shift
				;;
			-h | --help)
				usage
				exit 0
				;;
			*)
				printf '%s: unknown option: %s (try --help)\n' "$PROG" "$1" >&2
				exit 1
				;;
		esac
	done
}

# ---------------------------------------------------------------------------------------------
# validation helpers
# ---------------------------------------------------------------------------------------------
valid_domain() {
	local d=$1
	[ "${#d}" -le 253 ] || return 1
	[[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]
}

# Lower case, no trailing dot, then validate. Sets DOMAIN. Call before DOMAIN is compared with anything.
normalize_domain() {
	[ -n "$DOMAIN" ] || return 0
	DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
	DOMAIN=${DOMAIN%.}
	valid_domain "$DOMAIN" || die "\"$DOMAIN\" is not a valid host name (example: repo.example.com)" 1
}

# An absolute, normal path: no relative path, no .. or . parts, no trailing slash, not a system directory.
# Sets CLEANED (not printed: die inside $(...) would only end the subshell).
clean_path() { # option-name path
	local p=$2
	[[ $p == /* ]] || die "$1 must be an absolute path (it starts with /), not \"$p\"" 1
	while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
	[[ $p =~ ^/[A-Za-z0-9._/-]+$ ]] || die "$1 must be an absolute path (letters, digits, . _ - /)" 1
	case "$p/" in
		*/../* | */./* | *//*) die "$1: no .. or . parts and no double slashes in the path: $p" 1 ;;
	esac
	case "$p" in
		/bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /libx32 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /usr/local | /usr/share | /usr/lib | /usr/bin | /var/lib | /var/log | /var/tmp | /var/cache | /var/www | /etc/nginx | /etc/apt | /etc/systemd | /etc/vylarisspace-repo-host | /etc/vylarisspace-repo-host/* | /home/* | /proc/* | /sys/* | /dev/*)
			case "$p" in
				/home/*/*) ;;
				/home/*) die "$1: $p is a home directory, not a directory for this script. Use a sub directory of it." 2 ;;
				*) die "$1: $p is a system directory. Choose a dedicated directory (for example /srv/vylarisspace-repo)." 2 ;;
			esac
			;;
	esac
	CLEANED=$p
}

fpr_groups() { # 40 hex -> groups of four
	printf '%s' "$1" | sed 's/\(....\)/\1 /g; s/ $//'
}

# The nearest existing parent directory (for df).
existing_parent() {
	local p=$1
	while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
	printf '%s' "$p"
}

free_mb() { # path
	df -Pm "$(existing_parent "$1")" | awk 'NR==2{print $4}'
}

# ---------------------------------------------------------------------------------------------
# step 1: system, packages
# ---------------------------------------------------------------------------------------------
detect_system() {
	[ "$(id -u)" -eq 0 ] || die "run this as root (sudo -i, then run the command again)." 3
	[ -r /etc/os-release ] || die "cannot read /etc/os-release" 3
	OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
	OS_VERSION=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
	CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
	DISTRO_SUFFIX="$OS_ID$OS_VERSION"
	case " $SUPPORTED " in
		*" $DISTRO_SUFFIX "*) ;;
		*) die "unsupported system: $OS_ID $OS_VERSION. Supported: Debian 12, Debian 13, Ubuntu 22.04, Ubuntu 24.04." 3 ;;
	esac
	HOST_ARCH=$(dpkg --print-architecture)
	case "$HOST_ARCH" in
		amd64 | arm64) ;;
		*) die "unsupported architecture: $HOST_ARCH (amd64 or arm64)" 3 ;;
	esac
	local f
	for f in make-signing-key.sh repo-init.sh repo-publish.sh client-setup.sh; do
		[ -f "$SELF_DIR/$f" ] || die "$SELF_DIR/$f is missing. Run this script from a complete checkout of the repository." 3
	done
}

# A policy-rc.d that an interrupted run left behind (only one with our marker is removed).
remove_stale_policy_rc() {
	if [ -f "$POLICY_RC_FILE" ] && grep -qF "$POLICY_RC_MARK" "$POLICY_RC_FILE"; then
		rm -f "$POLICY_RC_FILE"
		warn "removed $POLICY_RC_FILE: a temporary file of an interrupted run of this script (it would have kept services from starting)"
	fi
	[ -z "$(state_get POLICY_RC_D)" ] || state_del POLICY_RC_D
}

ensure_packages() {
	local p st missing=()
	for p in $PACKAGES; do
		st=$(dpkg-query -W -f='${Status}' "$p" 2> /dev/null || true)
		if [ "$st" != 'install ok installed' ]; then
			missing+=("$p")
		fi
	done
	if [ "${#missing[@]}" -eq 0 ]; then
		skip "packages: all installed"
		return 0
	fi
	info "installing packages: ${missing[*]}"
	export DEBIAN_FRONTEND=noninteractive
	# A freshly installed nginx must not start on its own (its stock site wants port 80 and IPv6): this
	# script starts it itself, with its own site, after the configuration is in place.
	case " ${missing[*]} " in
		*" nginx "*)
			if [ ! -e "$POLICY_RC_FILE" ]; then
				state_set POLICY_RC_D yes
				printf '#!/bin/sh\n%s\nexit 101\n' "$POLICY_RC_MARK" > "$POLICY_RC_FILE"
				chmod 755 "$POLICY_RC_FILE"
				POLICY_RC=1
			fi
			state_set NGINX_BY_US yes
			;;
	esac
	run_step "apt-get update" 3 apt-get -qq update
	run_step "apt-get install" 3 apt-get -qq install -y --no-install-recommends "${missing[@]}"
	if [ "$POLICY_RC" -eq 1 ]; then
		rm -f "$POLICY_RC_FILE"
		POLICY_RC=0
		state_del POLICY_RC_D
	fi
	did "packages installed: ${missing[*]}"
}

# True when nobody but the owner is in the group (no other member, nobody else has it as primary group).
# A plain "git clone" as a normal Ubuntu/Debian user makes directories 775 with the private group of that
# user: that is fine. When the system cannot tell (unknown user or group), the answer is yes.
group_is_private() { # gid owner-uid
	local g=$1 u=$2 uname entry members others
	uname=$(getent passwd "$u" 2> /dev/null | cut -d: -f1 || true)
	[ -n "$uname" ] || return 0
	entry=$(getent group "$g" 2> /dev/null || true)
	[ -n "$entry" ] || return 0
	members=$(printf '%s' "$entry" | cut -d: -f4)
	others=$(printf '%s\n' "$members" | tr ',' '\n' | grep -vxF -e "$uname" -e '' || true)
	[ -z "$others" ] || return 1
	others=$(getent passwd 2> /dev/null | awk -F: -v g="$g" -v n="$uname" '$4==g && $1!=n{print $1; exit}' || true)
	[ -z "$others" ]
}

# One path of the checkout: belongs to root or to the sudo user, is not writable by everybody, and not
# by a group that has other members.
checkout_path_ok() { # path
	local p=$1 owner mode gid
	[ -e "$p" ] || return 0
	owner=$(stat -L -c %u "$p" 2> /dev/null) || return 0
	mode=$(stat -L -c %a "$p")
	gid=$(stat -L -c %g "$p")
	if [ "$owner" != 0 ] && [ "$owner" != "$CHECKOUT_UID" ]; then
		die "the git checkout $CHECKOUT is not safe to build as root: $p belongs to user id $owner (allowed: root, or the user who started sudo). Fix: chown -R root: $CHECKOUT   (or run the script as the owner with sudo). Building runs programs from the checkout as root: use your own clean clone." 2
	fi
	if [ $((8#$mode & 8#002)) -ne 0 ]; then
		die "the git checkout $CHECKOUT is not safe to build as root: $p can be changed by every user (mode $mode). Fix: chmod -R go-w $CHECKOUT" 2
	fi
	if [ $((8#$mode & 8#020)) -ne 0 ] && ! group_is_private "$gid" "$owner"; then
		die "the git checkout $CHECKOUT is not safe to build as root: $p can be changed by a group with other members (mode $mode, group id $gid). Fix: chmod -R go-w $CHECKOUT" 2
	fi
}

# The git checkout this script lives in (needed for the build and the source archive). git is told to
# trust THIS directory only (not '*'), and only when it belongs to root or to the user who ran sudo and
# nobody else can write to it: a checkout that others can change would let them run code as root (the
# build runs scripts of the checkout as root; so do git hooks). Checked: the directory, .git, .git/config,
# .git/hooks (and the hooks in it), src and every entry of src. Not checked: the rest of the tree. Use
# your own clean clone.
find_checkout() {
	local d=$SELF_DIR p
	CHECKOUT=''
	CHECKOUT_UID=${SUDO_UID:-}
	command -v git > /dev/null 2>&1 || return 0
	while [ "$d" != / ] && [ -n "$d" ]; do
		if [ -e "$d/.git" ]; then
			CHECKOUT=$d
			break
		fi
		d=$(dirname "$d")
	done
	[ -n "$CHECKOUT" ] || return 0
	[[ $CHECKOUT_UID =~ ^[0-9]+$ ]] || CHECKOUT_UID=''
	for p in "$CHECKOUT" "$CHECKOUT/.git" "$CHECKOUT/.git/config" "$CHECKOUT/.git/hooks" "$CHECKOUT/src" "$CHECKOUT"/src/* "$CHECKOUT"/src/.[!.]*; do
		checkout_path_ok "$p"
	done
	for p in "$CHECKOUT"/.git/hooks/*; do
		case "$p" in *.sample) continue ;; esac
		checkout_path_ok "$p"
	done
	# git (and repo-publish.sh) must accept exactly this checkout
	export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$CHECKOUT"
}

check_disk() {
	local need_build=$1 mb
	mb=$(free_mb "$REPO_DIR")
	[ "$mb" -ge 500 ] || die "not enough free disk space for the repository ($mb MB free in $(existing_parent "$REPO_DIR"), need 500 MB)." 3
	mb=$(free_mb "$STATE_DIR")
	[ "$mb" -ge 50 ] || die "not enough free disk space for $STATE_DIR ($mb MB free, need 50 MB)." 3
	if [ "$need_build" -eq 1 ]; then
		mb=$(free_mb /var/tmp)
		[ "$mb" -ge 3000 ] || die "not enough free disk space to build the panel package ($mb MB free in /var/tmp, need 3000 MB)." 3
	fi
	skip "disk space: ok"
}

# ---------------------------------------------------------------------------------------------
# Cloudflare API (token only through curl's config on stdin, never on a command line)
# ---------------------------------------------------------------------------------------------
cf_config() { printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN"; }

# cf_request METHOD PATH [JSON]: sets CF_HTTP, CF_BODY, CF_ERR, CF_CODES. Returns 0 when HTTP worked
# and the answer says "success":true. Retries network errors, 429 and 5xx up to 4 times. On 429 the
# Retry-After header of Cloudflare is honoured (at most 60 s; a longer wish stops the run).
cf_request() {
	local method=$1 path=$2 data=${3:-} attempt=1 rc code delay=${VYLARIS_CF_RETRY_DELAY:-2} pause ra msg
	local bodyfile="$TMP/cf.body" out="$TMP/cf.out" err="$TMP/cf.err" hdr="$TMP/cf.hdr" extra=()
	CF_HTTP=''
	CF_BODY=''
	CF_ERR=''
	CF_CODES=''
	if [ -n "$data" ]; then
		printf '%s' "$data" > "$bodyfile"
		extra=(--data-binary "@$bodyfile")
	fi
	while :; do
		rc=0
		: > "$out"
		: > "$hdr"
		code=$(cf_config | curl -sS -K - -X "$method" --connect-timeout 10 --max-time 45 \
			-H 'Content-Type: application/json' -H 'Accept: application/json' \
			"${extra[@]}" -D "$hdr" -o "$out" -w '%{http_code}' "$CF_BASE$path" 2> "$err") || rc=$?
		if [ "$rc" -eq 0 ]; then
			CF_HTTP=$code
			CF_BODY=$(cat "$out")
			case "$code" in 429 | 5??) ;; *) break ;; esac
		else
			CF_HTTP=000
			CF_BODY=''
			CF_ERR="cannot reach the Cloudflare API (curl exit $rc: $(head -c 200 "$err" | tr '\n' ' '))"
		fi
		[ "$attempt" -lt 4 ] || break
		pause=$((delay * attempt))
		msg="temporary problem (HTTP $CF_HTTP), trying again in $pause s"
		if [ "$CF_HTTP" = 429 ]; then
			ra=$(sed -n 's/^retry-after:[[:space:]]*\([0-9][0-9]*\).*/\1/Ip' "$hdr" | tail -n1)
			if [ -n "$ra" ]; then
				# leading zeros away first: "0000000060" is 60 (and "08" is no octal number)
				ra=${ra#"${ra%%[!0]*}"}
				ra=${ra:-0}
				if [ "${#ra}" -gt 3 ] || [ "$((10#$ra))" -gt 60 ]; then
					CF_ERR="HTTP 429: Cloudflare limits the number of requests and asks to wait $ra seconds (Retry-After). That is more than the 60 seconds this script waits. Wait a few minutes and run the same command again (it resumes)."
					logf "Cloudflare API $method $path: 429 with Retry-After $ra, stopping"
					CF_BODY=''
					return 1
				fi
				pause=$((10#$ra))
				msg="rate limit (HTTP 429), waiting $pause s as Cloudflare asks (Retry-After)"
			fi
		fi
		say "  Cloudflare API: $msg (attempt $attempt of 4)"
		logf "Cloudflare API $method $path: attempt $attempt failed (HTTP $CF_HTTP), retrying"
		sleep "$pause"
		attempt=$((attempt + 1))
	done
	[ "$CF_HTTP" != 000 ] || return 1
	if ! printf '%s' "$CF_BODY" | jq -e . > /dev/null 2>&1; then
		CF_ERR="HTTP $CF_HTTP and the answer is not JSON"
		return 1
	fi
	if printf '%s' "$CF_BODY" | jq -e '.success == true' > /dev/null 2>&1; then
		return 0
	fi
	CF_ERR="HTTP $CF_HTTP: $(printf '%s' "$CF_BODY" | jq -r '[.errors[]? | "[\(.code)] \(.message)"] | join("; ")')"
	CF_CODES=$(printf '%s' "$CF_BODY" | jq -r '[.errors[]?.code] | join(" ")')
	CF_BODY=''
	return 1
}

# Forget the last answer, also on disk (it may contain the tunnel run token).
cf_wipe() {
	CF_BODY=''
	if [ -n "$TMP" ]; then
		: > "$TMP/cf.out" 2> /dev/null || true
		: > "$TMP/cf.body" 2> /dev/null || true
		rm -f "$TMP/cf.out" "$TMP/cf.body"
	fi
}

# Stop with a message that says what to do. Code 4.
cf_die() { # what-we-were-doing
	local hint=''
	case " $CF_CODES " in
		*" 9109 "* | *" 10000 "* | *" 10001 "* | *" 6003 "* | *" 6111 "* | *" 9106 "* | *" 9107 "*) hint=auth ;;
	esac
	if [ -z "$hint" ]; then
		case "$CF_HTTP" in
			401 | 403) hint=auth ;;
			000) hint=net ;;
		esac
	fi
	case "$hint" in
		auth) hint="Cloudflare refused the API token. Possible reasons: the token is wrong, expired or revoked; it is restricted to other IP addresses; or it lacks a permission or a resource. It needs the permissions Account > Cloudflare Tunnel > Edit (the API documentation says 'Cloudflare Tunnel Write' or 'Cloudflare One Connectors Write'), Zone > DNS > Edit ('DNS Write') and Zone > Zone > Read ('Zone Read'), and as resources the account that owns the zone and the zone of the domain (or all zones). Read permissions are not enough for the first two: they must be Edit. See --help." ;;
		net) hint="Check the internet connection of this machine, DNS and firewall (outgoing https to api.cloudflare.com)." ;;
	esac
	die "Cloudflare: $1 failed. $CF_ERR${hint:+
  -> $hint}" 4
}

cf_jq() { printf '%s' "$CF_BODY" | jq -r "$1"; }

read_token() {
	local t='' mode
	if [ -n "$CF_TOKEN_FILE" ]; then
		[ -f "$CF_TOKEN_FILE" ] && [ -r "$CF_TOKEN_FILE" ] || die "cannot read the token file: $CF_TOKEN_FILE" 1
		mode=$(stat -c %a "$CF_TOKEN_FILE")
		if [ $((8#$mode & 8#077)) -ne 0 ]; then
			warn "$CF_TOKEN_FILE is readable by others (mode $mode). Use: chmod 600 $CF_TOKEN_FILE"
		fi
		t=$(head -n1 "$CF_TOKEN_FILE" | tr -d '\r\n\t ')
	elif [ -n "$CF_TOKEN_ENV" ]; then
		t=$CF_TOKEN_ENV
	elif [ -t 0 ]; then
		read -r -s -p "Cloudflare API token (input is hidden${TOKEN_OPTIONAL:+; Enter alone skips the tunnel check}): " t
		printf '\n'
	fi
	CF_TOKEN_ENV=''
	[ -n "$t" ] || return 1
	[[ $t =~ ^[A-Za-z0-9_.~+/=-]{16,512}$ ]] || die "the Cloudflare API token looks wrong (unexpected characters or length). Paste only the token." 1
	CF_TOKEN=$t
}

need_token() {
	read_token || die "the Cloudflare API token is missing. Set CLOUDFLARE_API_TOKEN, use --cf-token-file FILE, or run in a terminal to be asked." 1
}

# Zone of the domain: try the domain, then its parents. Returns 0 (found; ZONE_NAME, ZONE_ID, ACCOUNT_ID are
# set), 1 (the API answered with an error: CF_ERR and the others say which) or 2 (no such zone in this account).
cf_find_zone_try() {
	local name=$DOMAIN found=0
	ZONE_TRY_NAME=$name
	while [[ $name == *.* ]]; do
		ZONE_TRY_NAME=$name
		cf_request GET "/zones?name=$name&per_page=5" || return 1
		# only a zone with exactly this name counts, whatever the filter of the API did
		CF_BODY=$(printf '%s' "$CF_BODY" | jq -c --arg n "$name" '.result |= [.[]? | select((.name // "" | ascii_downcase) == $n)]')
		if [ "$(cf_jq '.result | length')" -gt 0 ]; then
			found=1
			break
		fi
		name=${name#*.}
	done
	[ "$found" -eq 1 ] || return 2
	ZONE_NAME=$name
	ZONE_ID=$(cf_jq '.result[0].id')
	ACCOUNT_ID=$(cf_jq '.result[0].account.id')
	[ -n "$ZONE_ID" ] && [ "$ZONE_ID" != null ] && [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != null ] || {
		CF_ERR="the zone answer has no zone id or account id"
		return 1
	}
	if [ "$(cf_jq '.result[0].status // "active"')" != active ]; then
		warn "the zone $ZONE_NAME is not active on Cloudflare yet (status $(cf_jq '.result[0].status')): the domain will not resolve until its nameservers point to Cloudflare."
	fi
	return 0
}

cf_find_zone() {
	local rc=0
	cf_find_zone_try || rc=$?
	case "$rc" in
		0) return 0 ;;
		2) die "Cloudflare: the domain $DOMAIN is not in this Cloudflare account (no DNS zone for it or its parents was found with this token).
  -> Add the domain to Cloudflare first (dashboard > Add a site, nameservers switched), and make sure the token has Zone Resources for it." 4 ;;
	esac
	cf_die "looking up the DNS zone $ZONE_TRY_NAME"
}

# The free Universal SSL certificate of Cloudflare covers example.com and *.example.com, not
# repo.srv.example.com. Stop (or warn with --allow-deep-host) before anything is created.
check_domain_depth() {
	local prefix=${DOMAIN%".$ZONE_NAME"}
	[ "$DOMAIN" != "$ZONE_NAME" ] || return 0
	if [[ $prefix == *.* ]]; then
		if [ "$ALLOW_DEEP" -eq 1 ]; then
			warn "$DOMAIN is more than one label below the zone $ZONE_NAME: the free Universal SSL certificate does not cover it (https will fail without a paid Advanced Certificate)."
		else
			die "$DOMAIN is more than one label below the zone $ZONE_NAME. The free Cloudflare certificate (Universal SSL) covers only $ZONE_NAME and *.$ZONE_NAME, so https://$DOMAIN would fail. Use a name like repo.$ZONE_NAME, or add --allow-deep-host if you have an Advanced Certificate. Nothing was changed." 2
		fi
	fi
}

# Read-only: the records whose name is exactly the domain. Sets DNS_RECORDS_JSON (id, type, name,
# content, ttl, proxied). The filter name.exact is sent AND checked here: only records whose name
# equals the domain (case-insensitive) are ever looked at, changed or deleted.
cf_dns_list() {
	cf_request GET "/zones/$ZONE_ID/dns_records?name.exact=$DOMAIN&per_page=100" || cf_die "reading the DNS records of $DOMAIN"
	if [ "$(cf_jq '(.result_info.total_pages // 1) > 1')" = true ]; then
		die "Cloudflare: the domain $DOMAIN has more than 100 DNS records. That is not a host name for this repository. Nothing was changed." 2
	fi
	DNS_RECORDS_JSON=$(printf '%s' "$CF_BODY" | jq -c --arg d "$DOMAIN" \
		'[.result[]? | select((.name // "" | ascii_downcase) == $d) | {id, type, name, content, ttl, proxied}]')
	CF_BODY=''
}

# Read-only: what is in DNS for the domain? Sets DNS_ACTION (create|ok|update|replace), DNS_IDS (all
# A/AAAA/CNAME records), DNS_OWN_ID (our CNAME) and DNS_RECORDS_JSON. A CNAME counts as ours only when
# it points to the cfargotunnel.com name of OUR tunnel; a CNAME to another tunnel is foreign.
cf_dns_inspect() {
	local id type content bad='' target=''
	[ -z "$TUNNEL_ID" ] || target="$TUNNEL_ID.cfargotunnel.com"
	DNS_IDS=()
	DNS_OWN_ID=''
	DNS_ACTION=create
	cf_dns_list
	while IFS=$'\t' read -r id type content; do
		case "$type" in
			A | AAAA)
				bad="$bad $type $content;"
				DNS_IDS+=("$id")
				;;
			CNAME)
				DNS_IDS+=("$id")
				if [ -n "$target" ] && [ "${content,,}" = "$target" ]; then
					DNS_OWN_ID=$id
					DNS_ACTION=update
				else
					bad="$bad CNAME $content;"
				fi
				;;
		esac
	done < <(printf '%s' "$DNS_RECORDS_JSON" | jq -r '.[] | [.id, .type, .content] | @tsv')
	if [ -n "$bad" ] && [ "$FORCE_DNS" -eq 0 ]; then
		die "the domain $DOMAIN already has a DNS record that is not the record of this tunnel:$bad
  Nothing was changed. If this host name is really meant for the repository, run again with --force-dns
  (the old records are saved first, then replaced), or choose another domain." 2
	fi
	[ -z "$bad" ] || DNS_ACTION=replace
}

# Read-only: is there a tunnel with our name? Sets TUNNEL_ID (empty: none). A tunnel of the same name
# that this machine does not know (not in the state) is taken over only when it is completely empty
# (no ingress, no catch-all, no warp routing, nothing): it may be used by something else.
cf_tunnel_inspect() { # [created-by-us]: skip the emptiness check (we created it a moment ago)
	local id='' src cfg_used
	if [ -n "$TUNNEL_ID" ]; then
		if cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID"; then
			[ "$(cf_jq '.result.deleted_at // ""')" != '' ] || return 0
		elif [ "$CF_HTTP" != 404 ]; then
			cf_die "reading the tunnel $TUNNEL_ID"
		fi
		warn "the tunnel $TUNNEL_ID of the last run no longer exists at Cloudflare; looking for it by name."
		TUNNEL_ID=''
		TUNNEL_CREATED=''
	fi
	ADOPTED=0
	cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" || cf_die "listing the tunnels"
	# only a tunnel with exactly this name that is not deleted counts, whatever the filter of the API did
	CF_BODY=$(printf '%s' "$CF_BODY" | jq -c --arg n "$TUNNEL_NAME" '.result |= [.[]? | select(.name == $n and (.deleted_at // null) == null)]')
	id=$(cf_jq '.result[0].id // ""')
	if [ -z "$id" ]; then
		TUNNEL_ID=''
		return 0
	fi
	src=$(cf_jq '.result[0].config_src // "cloudflare"')
	if [ "$src" != cloudflare ]; then
		die "the tunnel \"$TUNNEL_NAME\" already exists in your account and is configured by a local file ($src), not remotely. It is not touched. Use another name with --tunnel-name." 2
	fi
	if [ "${1:-}" = created-by-us ]; then
		TUNNEL_ID=$id
		TUNNEL_CREATED=yes
		return 0
	fi
	cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$id/configurations" || cf_die "reading the configuration of the existing tunnel $TUNNEL_NAME"
	cfg_used=$(cf_jq '(.result.config // {}) | with_entries(select(.value != null and .value != [] and .value != {})) | keys | join(", ")')
	if [ -n "$cfg_used" ]; then
		die "the tunnel \"$TUNNEL_NAME\" already exists in your account and has a configuration ($cfg_used; host names: $(cf_jq '[.result.config.ingress[]?.hostname // empty] | join(", ")')). It was not created by this script, so it is not taken over or changed. Use another name with --tunnel-name, or delete that tunnel in the Cloudflare dashboard if nothing uses it." 2
	fi
	TUNNEL_ID=$id
	TUNNEL_CREATED=no
	ADOPTED=1
}

cf_preflight() {
	local out=''
	cf_find_zone
	info "zone: $ZONE_NAME (found with this token, account id known)"
	check_domain_depth
	cf_tunnel_inspect
	if [ -n "$TUNNEL_ID" ]; then
		out="tunnel \"$TUNNEL_NAME\" exists and will be reused"
	else
		out="tunnel \"$TUNNEL_NAME\" will be created"
	fi
	info "$out"
	cf_dns_inspect
	case "$DNS_ACTION" in
		create) info "DNS: no record for $DOMAIN yet (will be created)" ;;
		update) info "DNS: $DOMAIN is the record of this tunnel already (will be checked)" ;;
		replace) warn "DNS: the existing record(s) of $DOMAIN will be replaced (--force-dns); the old ones are saved first" ;;
	esac
	did "Cloudflare token: read access works (zone, tunnels, DNS). The write permissions (Tunnel Edit, DNS Edit) are checked when they are used: the tunnel is created next."
}

# ---------------------------------------------------------------------------------------------
# step 2: signing key
# ---------------------------------------------------------------------------------------------
pubkey_fpr() { # file
	# never fails: no key (a text file, a web page) gives an empty answer, the callers say what is wrong
	gpg --batch --show-keys --with-colons "$1" 2> /dev/null 9>&- | awk -F: '$1=="pub"{p=1;next} p==1&&$1=="fpr"{print $10;exit}' || true
}

# Something of an earlier run exists, but its key is not in the state directory: creating a NEW key (or a
# new password) now would lock every server out. Stop and say what to restore.
die_if_earlier_run_without_key() {
	local what=''
	[ ! -s "$STATE_DIR/keys/out/pubkey.asc" ] || return 0
	[ ! -f "$REPO_DIR/conf/distributions" ] || what="$what the repository $REPO_DIR;"
	[ ! -e "$REPO_DIR/public/pubkey.gpg" ] || what="$what the public key $REPO_DIR/public/pubkey.gpg;"
	[ ! -e "$NGX_HTPASSWD" ] || what="$what the password file $NGX_HTPASSWD;"
	[ ! -e "$TUNNEL_ENV" ] || what="$what the tunnel token $TUNNEL_ENV;"
	[ -z "$what" ] || die "an earlier run of this script left${what%;} on this machine, but the signing key is missing in the state directory $STATE_DIR (lost, moved, or another --state-dir). A new key and a new password would lock out every server that uses this repository, so nothing was created. Restore the backup of the state directory (keys/, key.pass, repo-auth, state.env) to $STATE_DIR. If you really start from scratch: remove those files yourself first, and set every server up again." 2
}

ensure_signing_key() {
	local keys="$STATE_DIR/keys" pass="$STATE_DIR/key.pass" fpr secrets tmpk
	KEY_OUT="$keys/out"
	SIGN_HOME="$keys/gnupg-signing"
	if [ -s "$KEY_OUT/pubkey.asc" ] && [ -d "$SIGN_HOME" ]; then
		KEY_FPR=$(pubkey_fpr "$KEY_OUT/pubkey.asc")
		[ -n "$KEY_FPR" ] || die "cannot read the public key $KEY_OUT/pubkey.asc" 2
		secrets=$(GNUPGHOME="$SIGN_HOME" gpg --batch --list-secret-keys --with-colons "$KEY_FPR" 2> /dev/null 9>&- || true)
		if ! grep -q '^\(sec\|ssb\)' <<< "$secrets"; then
			die "the signing key of $KEY_FPR is missing in $SIGN_HOME. Restore the backup of $keys (a new key would make every server re-trust)." 2
		fi
		skip "signing key exists (fingerprint $(fpr_groups "$KEY_FPR")), not touched"
		state_set KEY_FPR "$KEY_FPR"
		record_state_ptr
		return 0
	fi
	if [ -e "$keys" ]; then
		die "$keys exists but is incomplete. Restore it from the backup, or (only if no key was ever used) move it away." 2
	fi
	die_if_earlier_run_without_key
	[ "${#STATE_DIR}" -le 50 ] || die "the state directory path is too long for gpg-agent (${#STATE_DIR} characters, at most 50): $STATE_DIR" 3
	if [ ! -s "$pass" ]; then
		write_secret "$pass" "$(openssl rand -hex 32)"
		did "passphrase generated: $pass (mode 600, never printed)"
	fi
	rm -rf "$STATE_DIR"/.keygen-tmp "$STATE_DIR"/.keygen.* 2> /dev/null || true
	KEYGEN_TMP=$(mktemp -d "$STATE_DIR/.keygen.XXXXXX")
	tmpk=$KEYGEN_TMP
	run_step "creating the signing key" 5 bash "$SELF_DIR/make-signing-key.sh" \
		--passphrase-file "$pass" --signing-home "$tmpk/gnupg-signing" "$tmpk/out" "$tmpk/gnupg-primary"
	GNUPGHOME="$tmpk/gnupg-signing" gpgconf --kill gpg-agent > /dev/null 2>&1 9>&- || true
	GNUPGHOME="$tmpk/gnupg-primary" gpgconf --kill gpg-agent > /dev/null 2>&1 9>&- || true
	fpr=$(pubkey_fpr "$tmpk/out/pubkey.asc")
	[ -n "$fpr" ] || die "the new key could not be read" 5
	mv "$tmpk" "$keys"
	KEYGEN_TMP=''
	KEY_FPR=$fpr
	state_set KEY_FPR "$KEY_FPR"
	record_state_ptr
	did "signing key created. Fingerprint: $(fpr_groups "$KEY_FPR")"
	say ""
	say "  IMPORTANT / WICHTIG: back up $STATE_DIR now (keys/, key.pass, repo-auth, state.env)"
	say "  to a safe place that is NOT this machine. If this key is lost, every server must be"
	say "  set up again with a new key. Verlust des Schluessels = alle Server muessen neu"
	say "  eingerichtet werden. The passphrase file belongs in your password manager too."
	say ""
}

# ---------------------------------------------------------------------------------------------
# step 3: repository
# ---------------------------------------------------------------------------------------------
# Only what repo-init.sh creates before its last step is in the directory: the empty directories, an
# empty or missing conf/distributions, conf/options, the public key files, the nginx sample. An earlier
# run that was stopped (power cut, Ctrl-C) while repo-init.sh was working leaves exactly this; it is safe to
# run repo-init.sh again over it.
repo_is_skeleton() {
	local e
	[ -d "$REPO_DIR" ] || return 1
	[ ! -s "$REPO_DIR/conf/distributions" ] || return 1
	while IFS= read -r e; do
		case "$e" in
			conf | db | logs | archive | public | public/dists | public/pool | public/sources) ;;
			*) return 1 ;;
		esac
	done < <(cd "$REPO_DIR" && find . -mindepth 1 -type d | sed 's|^\./||')
	while IFS= read -r e; do
		case "$e" in
			conf/distributions | conf/options | public/pubkey.gpg | public/pubkey.asc | nginx-vylarisspace-repo.conf.sample) ;;
			*) return 1 ;;
		esac
	done < <(cd "$REPO_DIR" && find . -mindepth 1 ! -type d | sed 's|^\./||')
	return 0
}

# Read-only: refuse a directory that is not ours before anything is created.
repo_precheck() {
	[ ! -s "$REPO_DIR/conf/distributions" ] || return 0
	[ -e "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2> /dev/null)" ] || return 0
	repo_is_skeleton && return 0
	die "$REPO_DIR exists, is not empty and is not a repository of this tool. Choose another --repo-dir." 2
}

ensure_repo() {
	local c repo_fpr init_args=()
	if [ "$STAGING" -eq 1 ]; then init_args+=(--staging); fi
	if [ -s "$REPO_DIR/conf/distributions" ]; then
		skip "repository exists: $REPO_DIR"
		if [ "$STAGING" -eq 1 ] && ! grep -q -- '-staging$' "$REPO_DIR/conf/distributions"; then
			warn "--staging was given, but the repository was created without staging suites. They cannot be added by this script (edit $REPO_DIR/conf/distributions, see README.md)."
		fi
	else
		repo_precheck
		if [ -e "$REPO_DIR/conf/distributions" ]; then
			# (an empty file: repo-init.sh refuses a directory that has one)
			info "$REPO_DIR holds only the beginning of an earlier, stopped repository creation: continuing it"
			rm -f "$REPO_DIR/conf/distributions"
		elif [ -e "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2> /dev/null)" ]; then
			info "$REPO_DIR holds only the beginning of an earlier, stopped repository creation: continuing it"
		fi
		run_step "creating the repository" 5 env GNUPGHOME="$SIGN_HOME" VYLARIS_SIGN_KEY="$KEY_FPR" \
			bash "$SELF_DIR/repo-init.sh" "${init_args[@]}" --server-name "$DOMAIN" \
			--pubkey "$KEY_OUT/pubkey.asc" "$REPO_DIR"
		did "repository created: $REPO_DIR"
	fi
	# The repository must be signed by THE key of this state directory: with another key every server
	# would reject it (or a copied repository would be published under a key that is not ours).
	repo_fpr=$(pubkey_fpr "$REPO_DIR/public/pubkey.gpg")
	if [ "$repo_fpr" != "$KEY_FPR" ]; then
		die "the public key of the repository ($REPO_DIR/public/pubkey.gpg, fingerprint ${repo_fpr:-unreadable}) is not the signing key of this state directory ($KEY_FPR). Nothing was changed. Use the state directory that belongs to this repository (--state-dir), or another --repo-dir." 2
	fi
	chmod 755 "$REPO_DIR" "$REPO_DIR/public"
	c=$CODENAME
	if [ ! -s "$REPO_DIR/public/dists/$c/InRelease" ]; then
		# (umask 022: the files are served by nginx, which is another user; this script runs with 077)
		run_step "signing the empty indices" 5 env GNUPGHOME="$SIGN_HOME" bash -c 'umask 022; exec reprepro -b "$1" export' _ "$REPO_DIR"
		did "indices exported and signed"
	fi
	state_set REPO_DIR "$REPO_DIR"
}

# ---------------------------------------------------------------------------------------------
# step 4: nginx
# ---------------------------------------------------------------------------------------------
port_in_use() { # port
	ss -Hltn 2> /dev/null | awk -v p=":$1" '{n=split($4,a,":"); if (":" a[n] == p) f=1} END{exit f?0:1}'
}

nginx_group() {
	local u g
	u=$(awk '/^[[:space:]]*user[[:space:]]/{gsub(";",""); print $2; exit}' /etc/nginx/nginx.conf 2> /dev/null || true)
	u=${u:-www-data}
	g=$(id -gn "$u" 2> /dev/null || true)
	printf '%s' "${g:-root}"
}

ensure_credentials() {
	local f="$STATE_DIR/repo-auth" line salt hash group
	if [ -s "$f" ]; then
		line=$(head -n1 "$f")
		REPO_USER=${line%%:*}
		REPO_PASS=${line#*:}
		if [ -n "$AUTH_USER" ] && [ "$AUTH_USER" != "$REPO_USER" ]; then
			die "a login for user \"$REPO_USER\" already exists ($f). Servers already use it, so it is not changed. To change it on purpose, delete $f AND $NGX_HTPASSWD yourself and run again (then give every server the new login)." 2
		fi
		skip "repository login exists (user $REPO_USER), not changed"
	else
		if [ -e "$NGX_HTPASSWD" ]; then
			die "the password file $NGX_HTPASSWD of an earlier run exists, but $f (the login that belongs to it) is missing. A new password would lock out every server that uses the old one, so nothing was generated. Restore $f from your backup. To change the login on purpose: delete $NGX_HTPASSWD yourself and run again, then give every server the new login." 2
		fi
		REPO_USER=${AUTH_USER:-vylaris-server}
		REPO_PASS=$(openssl rand -hex 24)
		write_secret "$f" "$REPO_USER:$REPO_PASS"
		state_set LOGIN_SHOWN no
		LOGIN_FRESH=1
		did "repository login generated: $f (mode 600)"
	fi
	group=$(nginx_group)
	if [ -f "$NGX_HTPASSWD" ]; then
		salt=$(awk -F: -v u="$REPO_USER" '$1==u{print $2; exit}' "$NGX_HTPASSWD" | cut -d'$' -f3)
		if [ -n "$salt" ]; then
			hash=$(printf '%s\n' "$REPO_PASS" | openssl passwd -apr1 -salt "$salt" -stdin)
			if grep -qxF "$REPO_USER:$hash" "$NGX_HTPASSWD"; then
				chgrp "$group" "$NGX_HTPASSWD"
				chmod 640 "$NGX_HTPASSWD"
				skip "password file unchanged: $NGX_HTPASSWD"
				return 0
			fi
		fi
	fi
	hash=$(printf '%s\n' "$REPO_PASS" | openssl passwd -apr1 -stdin)
	printf '%s:%s\n' "$REPO_USER" "$hash" > "$TMP/htpasswd"
	install -m 640 -o root -g "$group" "$TMP/htpasswd" "$NGX_HTPASSWD"
	did "password file written: $NGX_HTPASSWD (mode 640, root:$group)"
}

render_nginx() {
	cat << NGINX_EOF
# Managed by setup-repo-host.sh (VylarisSpace repository host installer). Do not edit: the next
# run of the script overwrites this file. TLS is terminated by Cloudflare, this site listens on the
# loopback only and cloudflared forwards the requests to it.
server {
	listen 127.0.0.1:$LISTEN_PORT default_server;
	server_name $DOMAIN;

	# ONLY public/ is served. conf/, db/, logs/ and archive/ are outside of this root.
	root $REPO_DIR/public;
	autoindex off;
	server_tokens off;

	access_log /var/log/nginx/vylarisspace-repo.access.log;
	error_log /var/log/nginx/vylarisspace-repo.error.log;

	add_header X-Content-Type-Options "nosniff" always;
	add_header Referrer-Policy "no-referrer" always;
	add_header X-Robots-Tag "noindex, nofollow" always;

	if (\$request_method !~ ^(GET|HEAD)\$) {
		return 405;
	}
NGINX_EOF
	if [ "$AUTH_MODE" = auth ]; then
		cat << NGINX_EOF

	auth_basic "VylarisSpace repository";
	auth_basic_user_file $NGX_HTPASSWD;
NGINX_EOF
	fi
	cat << 'NGINX_EOF'

	# The public key is public by definition.
	location = /pubkey.gpg {
		auth_basic off;
	}
	location = /pubkey.asc {
		auth_basic off;
	}
	# Release/InRelease change on every publish: never cache the index files.
	location /dists/ {
		expires -1;
	}
	location /pool/ {
		expires 1h;
	}
	location ~ /\. {
		deny all;
	}
	location / {
		try_files $uri =404;
	}
}
NGINX_EOF
}

# Read-only: the refusals about the nginx site and the port. Sets NGX_HAD (our file name exists) and
# NGX_OLD_PORT (the port of the existing site). Called in step 1 (before anything is created) and again in step 4.
nginx_precheck() {
	NGX_HAD=0
	NGX_OLD_PORT=''
	if [ -f "$NGX_CONF" ]; then
		NGX_HAD=1
		if ! grep -q "^$NGX_HEADER" "$NGX_CONF" && [ "$FORCE" -eq 0 ]; then
			die "$NGX_CONF exists, but it was not written by this script (the line \"$NGX_HEADER\" is missing). It was not changed. Move it away, or run again with --force (a copy is then kept as $NGX_BAK)." 2
		fi
		NGX_OLD_PORT=$(sed -n '/^[[:space:]]*listen 127\.0\.0\.1:[0-9]* default_server;/{s/^[[:space:]]*listen 127\.0\.0\.1:\([0-9]*\) default_server;.*/\1/p;q;}' "$NGX_CONF")
	fi
	if port_in_use "$LISTEN_PORT" && [ "$NGX_OLD_PORT" != "$LISTEN_PORT" ]; then
		die "port $LISTEN_PORT is already used by another program. Choose a free one with --listen-port PORT." 2
	fi
}

ensure_nginx() {
	local had ngx_dump bak_note
	if [ "$(state_get NGINX_BY_US)" = yes ] && [ -L /etc/nginx/sites-enabled/default ]; then
		rm -f /etc/nginx/sites-enabled/default
		did "the stock nginx welcome site was disabled (nginx was installed by this script and only serves the repository)"
	fi
	if ! nginx -t > "$TMP/nginx.base" 2>&1; then
		cat "$TMP/nginx.base" >> "$LOG_FILE" 2> /dev/null || true
		tail -n 8 "$TMP/nginx.base" >&2
		die "the existing nginx configuration does not pass 'nginx -t' even without this script's site. It was not changed. Fix it first (the lines above say where), then run again." 2
	fi
	nginx_precheck
	had=$NGX_HAD
	if [ "$AUTH_MODE" = auth ]; then
		ensure_credentials
	else
		skip "no password (--public): anybody who knows $DOMAIN may download"
	fi
	render_nginx > "$TMP/nginx.conf"
	if [ "$had" -eq 1 ] && cmp -s "$TMP/nginx.conf" "$NGX_CONF"; then
		skip "nginx site unchanged: $NGX_CONF"
		nginx_running || nginx_reload || die "nginx is not running and could not be started" 2
	else
		if [ "$had" -eq 1 ]; then
			cp -p "$NGX_CONF" "$TMP/nginx.conf.bak"
			# Only an original that is not ours is worth a copy (a file of this script is written again by the next
			# run), and the first copy is never overwritten: a second foreign original gets a copy of its own.
			if ! grep -q "^$NGX_HEADER" "$NGX_CONF"; then
				bak_note=$NGX_BAK
				if [ -e "$NGX_BAK" ]; then bak_note="$NGX_BAK.$(date +%Y%m%d-%H%M%S)"; fi
				cp -p "$NGX_CONF" "$bak_note"
				info "the previous $NGX_CONF (not written by this script) is kept as $bak_note"
			fi
		fi
		install -m 644 -o root -g root "$TMP/nginx.conf" "$NGX_CONF"
		if ! nginx -t > "$TMP/nginx.out" 2>&1; then
			nginx_rollback "$had"
			cat "$TMP/nginx.out" >> "$LOG_FILE" 2> /dev/null || true
			tail -n 10 "$TMP/nginx.out" >&2
			die "nginx -t rejected the new site. The previous nginx setup was restored." 2
		fi
		# (captured first: grep -q ends early, and under pipefail the SIGPIPE of nginx -T would look like "not found")
		ngx_dump=$(nginx -T 2> /dev/null || true)
		if ! grep -qF -- "$NGX_CONF" <<< "$ngx_dump"; then
			nginx_rollback "$had"
			die "your nginx.conf does not include /etc/nginx/conf.d/*.conf, so the repository site would not be loaded. Nothing was changed." 2
		fi
		nginx_reload || {
			nginx_rollback "$had"
			nginx_reload || true
			die "nginx could not be reloaded with the new site. The previous setup was restored." 2
		}
		did "nginx site written and loaded: $NGX_CONF (127.0.0.1:$LISTEN_PORT)"
	fi
	state_set LISTEN_PORT "$LISTEN_PORT"
	state_set AUTH_MODE "$AUTH_MODE"
}

nginx_rollback() { # had-old-file
	if [ "$1" -eq 1 ]; then
		install -m 644 -o root -g root "$TMP/nginx.conf.bak" "$NGX_CONF"
	else
		rm -f "$NGX_CONF"
	fi
}

nginx_running() {
	{ command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet nginx 2> /dev/null; } || pgrep -x nginx > /dev/null 2>&1
}

# (9>&-: a daemon started here must not keep the lock of this run)
nginx_reload() {
	if command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet nginx 2> /dev/null; then
		systemctl reload nginx > /dev/null 2>&1 9>&-
	elif pgrep -x nginx > /dev/null 2>&1; then
		nginx -s reload > /dev/null 2>&1 9>&-
	else
		systemctl enable --now nginx > /dev/null 2>&1 9>&- || nginx > /dev/null 2>&1 9>&-
	fi
}

# ---------------------------------------------------------------------------------------------
# step 5: Cloudflare tunnel, route, DNS
# ---------------------------------------------------------------------------------------------
cf_ensure_tunnel() {
	local body e_http e_err e_codes
	cf_tunnel_inspect
	if [ -n "$TUNNEL_ID" ]; then
		state_set TUNNEL_ID "$TUNNEL_ID"
		[ -z "$TUNNEL_CREATED" ] || state_set TUNNEL_CREATED "$TUNNEL_CREATED"
		if [ "$ADOPTED" -eq 1 ]; then
			did "existing tunnel \"$TUNNEL_NAME\" taken over (it was completely empty; it stays in your account when you uninstall)"
		else
			skip "tunnel exists: $TUNNEL_NAME ($TUNNEL_ID)"
		fi
		return 0
	fi
	body=$(jq -nc --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')
	if ! cf_request POST "/accounts/$ACCOUNT_ID/cfd_tunnel" "$body"; then
		# A retry after a server error may hit "already exists": look again before failing.
		ADOPTED=0
		e_http=$CF_HTTP
		e_err=$CF_ERR
		e_codes=$CF_CODES
		cf_tunnel_inspect created-by-us
		if [ -z "$TUNNEL_ID" ]; then
			CF_HTTP=$e_http
			CF_ERR=$e_err
			CF_CODES=$e_codes
			cf_die "creating the tunnel $TUNNEL_NAME"
		fi
		state_set TUNNEL_ID "$TUNNEL_ID"
		state_set TUNNEL_CREATED yes
		did "tunnel found after a retry: $TUNNEL_NAME ($TUNNEL_ID)"
		return 0
	fi
	TUNNEL_ID=$(cf_jq '.result.id')
	[ -n "$TUNNEL_ID" ] && [ "$TUNNEL_ID" != null ] || die "Cloudflare: the answer for the new tunnel has no id" 4
	TUNNEL_CREATED=yes
	state_set TUNNEL_ID "$TUNNEL_ID"
	state_set TUNNEL_CREATED yes
	did "tunnel created: $TUNNEL_NAME ($TUNNEL_ID)"
}

cf_ensure_ingress() {
	local want cur body
	want=$(jq -nc --arg h "$DOMAIN" --arg s "http://127.0.0.1:$LISTEN_PORT" \
		'[{hostname:$h, service:$s}, {hostname:null, service:"http_status:404"}]')
	cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" || cf_die "reading the tunnel configuration"
	cur=$(cf_jq '[.result.config.ingress[]? | {hostname:(.hostname // null), service:.service}]' | jq -c .)
	if [ "$cur" = "$want" ]; then
		skip "tunnel route already set: $DOMAIN -> http://127.0.0.1:$LISTEN_PORT"
		return 0
	fi
	body=$(jq -nc --arg h "$DOMAIN" --arg s "http://127.0.0.1:$LISTEN_PORT" \
		'{config:{ingress:[{hostname:$h, service:$s}, {service:"http_status:404"}]}}')
	cf_request PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$body" || cf_die "setting the tunnel route"
	did "tunnel route set: $DOMAIN -> http://127.0.0.1:$LISTEN_PORT"
}

# --force-dns: the records of the domain that are in the way. Saved (log + file, mode 600) BEFORE anything
# changes. Our CNAME is made first (the first record is changed in place, A -> CNAME, so there is no moment
# without an answer), the other records are deleted afterwards. If Cloudflare refuses the change while the
# other records exist (an A/AAAA record cannot stand next to a CNAME), those are deleted first and the
# change is made then; the saved file has everything to put them back.
cf_dns_replace() { # json-body
	local body=$1 file keep id line other=() n i
	file="$STATE_DIR/dns-backup-$(date +%Y%m%d-%H%M%S).json"
	printf '%s\n' "$DNS_RECORDS_JSON" | jq . > "$file.new"
	chmod 600 "$file.new"
	mv -f "$file.new" "$file"
	while IFS= read -r line; do
		logf "DNS record before --force-dns: $line"
		info "old record: $line (saved in $file)"
	done < <(printf '%s' "$DNS_RECORDS_JSON" | jq -r '.[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME") | "\(.type) \(.content) ttl=\(.ttl) proxied=\(.proxied)"')
	keep=${DNS_OWN_ID:-${DNS_IDS[0]}}
	for id in "${DNS_IDS[@]}"; do
		[ "$id" = "$keep" ] || other+=("$id")
	done
	if ! cf_request PATCH "/zones/$ZONE_ID/dns_records/$keep" "$body"; then
		# Only an answer about the content (HTTP 400/409: a CNAME next to other records) is a reason to delete
		# the others first. A refused token (401/403), a rate limit, a server error or no answer at all is not:
		# nothing is deleted then.
		case "$CF_HTTP" in
			400 | 409) ;;
			*) cf_die "changing the DNS record (nothing was deleted, nothing was changed; the old records are saved in $file)" ;;
		esac
		logf "DNS: Cloudflare refused to change the record while others exist: $CF_ERR"
		for id in "${other[@]}"; do
			cf_request DELETE "/zones/$ZONE_ID/dns_records/$id" || cf_die "removing the old DNS record (the old records are saved in $file)"
		done
		other=()
		cf_request PATCH "/zones/$ZONE_ID/dns_records/$keep" "$body" || cf_die "changing the DNS record (the old records are saved in $file)"
	fi
	n=${#other[@]}
	for ((i = 0; i < n; i++)); do
		cf_request DELETE "/zones/$ZONE_ID/dns_records/${other[$i]}" || cf_die "removing the old DNS record (the new record is in place; the old ones are saved in $file)"
	done
	did "DNS record replaced ($((${#DNS_IDS[@]})) old record(s) saved in $file): $DOMAIN -> $TUNNEL_ID.cfargotunnel.com (CNAME, proxied)"
}

cf_ensure_dns() {
	local target="$TUNNEL_ID.cfargotunnel.com" body cur_content cur_proxied e_http e_err e_codes
	cf_dns_inspect
	body=$(jq -nc --arg n "$DOMAIN" --arg c "$target" \
		'{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1, comment:"VylarisSpace repository tunnel"}')
	if [ "$DNS_ACTION" = create ]; then
		if cf_request POST "/zones/$ZONE_ID/dns_records" "$body"; then
			did "DNS record created: $DOMAIN -> $target (proxied)"
			return 0
		fi
		# The record may have been created although the answer was an error (a 5xx, a timeout): look again.
		e_http=$CF_HTTP
		e_err=$CF_ERR
		e_codes=$CF_CODES
		cf_dns_inspect
		if [ "$DNS_ACTION" != update ]; then
			CF_HTTP=$e_http
			CF_ERR=$e_err
			CF_CODES=$e_codes
			cf_die "creating the DNS record"
		fi
		info "the first attempt to create the DNS record ended with an error ($e_err), but the record exists: checking it"
	fi
	if [ "$DNS_ACTION" = update ]; then
		cf_request GET "/zones/$ZONE_ID/dns_records/$DNS_OWN_ID" || cf_die "reading the DNS record"
		cur_content=$(cf_jq '.result.content')
		cur_proxied=$(cf_jq '.result.proxied')
		if [ "$cur_content" = "$target" ] && [ "$cur_proxied" = true ]; then
			skip "DNS record is right: $DOMAIN -> $target (proxied)"
			return 0
		fi
		cf_request PATCH "/zones/$ZONE_ID/dns_records/$DNS_OWN_ID" "$body" || cf_die "updating the DNS record"
		did "DNS record updated: $DOMAIN -> $target (was $cur_content, proxied $cur_proxied)"
		return 0
	fi
	cf_dns_replace "$body"
}

# Fetch the run token of the tunnel and keep it in a root-only file for the service.
cf_store_tunnel_token() {
	local tok
	cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" || cf_die "fetching the tunnel run token"
	tok=$(cf_jq '.result')
	cf_wipe
	[[ $tok =~ ^[A-Za-z0-9_.=+/-]{20,4096}$ ]] || die "Cloudflare: the tunnel run token has an unexpected form" 4
	mkdir -p "$TUNNEL_ENV_DIR"
	chmod 700 "$TUNNEL_ENV_DIR"
	if [ -f "$TUNNEL_ENV" ] && [ "$(cat "$TUNNEL_ENV")" = "TUNNEL_TOKEN=$tok" ]; then
		skip "tunnel run token unchanged ($TUNNEL_ENV, mode 600)"
		TOKEN_CHANGED=0
	else
		write_secret "$TUNNEL_ENV" "TUNNEL_TOKEN=$tok"
		did "tunnel run token stored: $TUNNEL_ENV (mode 600, never printed)"
		TOKEN_CHANGED=1
	fi
	tok=''
}

# ---------------------------------------------------------------------------------------------
# step 6: cloudflared
# ---------------------------------------------------------------------------------------------
install_cloudflared() {
	local tmpk="$TMP/cfkey" fpr count version='' url got='' bad='' downloaded=0
	if [ -n "$CLOUDFLARED_DEB" ]; then
		[ -f "$CLOUDFLARED_DEB" ] || die "no such file: $CLOUDFLARED_DEB" 1
		[ "$(dpkg-deb -f "$CLOUDFLARED_DEB" Package 2> /dev/null)" = cloudflared ] || die "$CLOUDFLARED_DEB is not a cloudflared package" 1
		version=$(dpkg-deb -f "$CLOUDFLARED_DEB" Version)
		if [ "$(dpkg-query -W -f='${Version}' cloudflared 2> /dev/null || true)" = "$version" ]; then
			skip "cloudflared $version is installed already"
			return 0
		fi
		run_step "installing $CLOUDFLARED_DEB" 3 env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends "$(readlink -f "$CLOUDFLARED_DEB")"
		did "cloudflared $version installed from $CLOUDFLARED_DEB"
		return 0
	fi
	if command -v cloudflared > /dev/null 2>&1; then
		skip "cloudflared is installed already ($(cloudflared --version 2> /dev/null | head -n1))"
		return 0
	fi
	# The key is looked for at the two addresses Cloudflare publishes it; either must carry exactly the pinned key.
	for url in "${CFD_KEY_URLS[@]}"; do
		rm -f "$tmpk.raw" "$tmpk.gpg"
		if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 -o "$tmpk.raw" "$url" 2> /dev/null; then
			logf "cloudflared key: cannot download $url"
			continue
		fi
		downloaded=1
		if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmpk.raw"; then
			gpg --batch --dearmor < "$tmpk.raw" > "$tmpk.gpg" 2> /dev/null 9>&- || continue
		else
			cp "$tmpk.raw" "$tmpk.gpg"
		fi
		count=$(gpg --batch --show-keys --with-colons "$tmpk.gpg" 2> /dev/null 9>&- | grep -c '^pub:' || true)
		fpr=$(pubkey_fpr "$tmpk.gpg")
		if [ "$count" -eq 1 ] && [ "$fpr" = "$CFD_KEY_FPR" ]; then
			got=$url
			break
		fi
		bad="$bad $url: fingerprint ${fpr:-none}, $count key(s);"
		logf "cloudflared key: $url does not have the pinned fingerprint (got ${fpr:-none}, $count keys)"
	done
	if [ "$downloaded" -eq 0 ]; then
		die "cannot download the Cloudflare package key from ${CFD_KEY_URLS[*]}. Check the internet connection, or give an own package with --cloudflared-deb FILE." 3
	fi
	if [ -z "$got" ]; then
		die "the Cloudflare package key does not have the expected fingerprint ($bad expected $CFD_KEY_FPR). Nothing was installed. Use --cloudflared-deb FILE if Cloudflare changed its key, and check the script for an update." 2
	fi
	info "Cloudflare package key taken from $got (fingerprint checked)"
	install -m 644 "$tmpk.gpg" "$CFD_KEY_FILE"
	printf '%s\n' "$CFD_REPO_LINE" > "$TMP/cloudflared.list"
	install -m 644 "$TMP/cloudflared.list" "$CFD_LIST_FILE"
	export DEBIAN_FRONTEND=noninteractive
	run_step "apt-get update (cloudflared repository)" 3 apt-get -qq update \
		-o Dir::Etc::sourcelist="sources.list.d/cloudflared.list" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
	run_step "installing cloudflared" 3 apt-get -qq install -y --no-install-recommends cloudflared
	did "cloudflared $(dpkg-query -W -f='${Version}' cloudflared 2> /dev/null) installed from pkg.cloudflare.com (key $(fpr_groups "$CFD_KEY_FPR") checked)"
}

render_unit() {
	local bin
	bin=$(readlink -f "$(command -v cloudflared)")
	cat << UNIT_EOF
# Managed by setup-repo-host.sh (VylarisSpace repository host installer).
# The tunnel token is NOT on the command line (ps) and not in this world-readable file: systemd
# reads it from $TUNNEL_ENV (root only, mode 600) into the environment of the service.
[Unit]
Description=VylarisSpace repository tunnel (Cloudflare)
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$TUNNEL_ENV
ExecStart=$bin --no-autoupdate tunnel run
Restart=always
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
}

ensure_service() {
	local changed=0
	command -v systemctl > /dev/null 2>&1 || die "systemd (systemctl) is not available here. Use --skip-tunnel-service and run cloudflared yourself (the command is printed)." 3
	render_unit > "$TMP/unit"
	if [ -f "$UNIT_FILE" ] && cmp -s "$TMP/unit" "$UNIT_FILE"; then
		skip "service file unchanged: $UNIT_FILE"
	else
		install -m 644 "$TMP/unit" "$UNIT_FILE"
		systemctl daemon-reload
		changed=1
		did "service file written: $UNIT_FILE"
	fi
	if systemctl is-active --quiet "$SERVICE_NAME" 2> /dev/null; then
		if [ "$changed" -eq 1 ] || [ "$TOKEN_CHANGED" -eq 1 ]; then
			systemctl restart "$SERVICE_NAME" 9>&-
			did "service restarted: $SERVICE_NAME"
		else
			skip "service is running: $SERVICE_NAME"
		fi
	else
		systemctl enable --now "$SERVICE_NAME" > /dev/null 2>&1 9>&- || die "could not start $SERVICE_NAME (see: journalctl -u $SERVICE_NAME)" 3
		did "service enabled and started: $SERVICE_NAME"
	fi
}

# The state of the tunnel comes from .result.status only ("connections" of this call is deprecated and
# will be empty). healthy: fine. degraded: at least one connection, less redundancy than usual: go on.
wait_tunnel_healthy() {
	local waited=0 st='' conns n
	while :; do
		if cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID"; then
			st=$(cf_jq '.result.status // ""')
			conns=$(cf_jq '[.result.connections[]?] | length')
			n=''
			[ "$conns" -le 0 ] || n=" ($conns connection(s))"
			case "$st" in
				healthy)
					did "tunnel is healthy$n"
					return 0
					;;
				degraded)
					warn "the tunnel is degraded: it is up with reduced redundancy$n. That works; Cloudflare reports it when not all of its connections are up. Continuing."
					return 0
					;;
			esac
		fi
		[ "$waited" -lt "$TUNNEL_WAIT" ] || break
		sleep 3
		waited=$((waited + 3))
	done
	warn "the tunnel is not healthy after ${TUNNEL_WAIT}s (status: ${st:-unknown}). cloudflared needs outgoing TCP and UDP port 7844 to Cloudflare: check the firewall. See: journalctl -u $SERVICE_NAME -n 30"
	FINAL_RC=6
	return 1
}

print_manual_tunnel() {
	say ""
	say "  The tunnel service was NOT installed (--skip-tunnel-service). Until cloudflared runs, https://$DOMAIN does not answer."
	say "  Run cloudflared yourself:"
	say "    with docker:"
	say "      docker run -d --name vylarisspace-tunnel --restart unless-stopped --network host \\"
	say "        --env-file $TUNNEL_ENV cloudflare/cloudflared:latest tunnel --no-autoupdate run"
	say "    with a cloudflared you installed:"
	say "      set -a; . $TUNNEL_ENV; set +a; cloudflared --no-autoupdate tunnel run"
	say "  ($TUNNEL_ENV holds the tunnel token, root only. Keep it out of command lines.)"
}

# ---------------------------------------------------------------------------------------------
# step 7: package
# ---------------------------------------------------------------------------------------------
published_version() { # suite arch -> version or empty
	[ -f "$REPO_DIR/conf/distributions" ] || return 0
	reprepro -b "$REPO_DIR" -A "$2" -T deb list "$1" hestia 2> /dev/null | awk '{print $NF; exit}' || true
}

# Refuses a checkout whose archive would not match the package. Called in step 1 (before anything is
# created) and only when something is going to be built or published.
checkout_clean_or_die() {
	local st
	[ -n "$CHECKOUT" ] || die "this script is not inside a git checkout. The source archive that belongs to the package (GPL) is made with git, so run it from a checkout (git clone of the repository)." 2
	[ "$ALLOW_DIRTY" -eq 0 ] || return 0
	st=$(git -C "$CHECKOUT" status --porcelain --untracked-files=normal 2>&1) || die "git cannot read the checkout $CHECKOUT: $st" 2
	if [ -n "$st" ]; then
		die "the checkout $CHECKOUT has uncommitted changes or untracked files. The source archive would not match the package. Commit your changes (git add <files>; git commit) or move stray files out of the checkout; --allow-dirty publishes anyway (the source archive then lacks them). Nothing was changed." 2
	fi
}

# Decides what step 7 will do, without changing anything: sets BUILD_PLAN (skip|build), BUILD_REV, BUILD_VER
# and BUILD_PUB (the version that is published already). "Already published" is decided first: a rerun that
# builds nothing does not care about the state of the tree.
plan_build() {
	local control base tag want pub pub_base pub_rev rev
	[ -n "$CHECKOUT" ] || die "this script is not inside a git checkout. The version of the package and the source archive that belongs to it (GPL) come from a checkout (git clone of the repository); or give the package with --deb FILE from a checkout." 2
	control="$CHECKOUT/src/deb/hestia/control"
	[ -f "$control" ] || die "$control not found" 3
	base=$(awk '/^Version:/{print $2; exit}' "$control")
	tag=''
	case "$base" in *~*) tag="~${base#*~}" ;; esac
	base=${base%%~*}
	pub=$(published_version "$CODENAME" "$HOST_ARCH")
	BUILD_PLAN=build
	BUILD_PUB=$pub
	rev=${PKGREV:-$DEFAULT_PKGREV}
	if [ -n "$pub" ]; then
		pub_base=${pub%%-*}
		pub_rev=${pub#*-}
		pub_rev=${pub_rev%%[+~]*}
		want="$base-$rev+$DISTRO_SUFFIX$tag"
		if [ "$REBUILD" -eq 1 ] && [ -z "$PKGREV" ]; then
			if [ "$pub_base" = "$base" ]; then rev=$((pub_rev + 1)); else rev=$DEFAULT_PKGREV; fi
			want="$base-$rev+$DISTRO_SUFFIX$tag"
		elif [ "$REBUILD" -eq 0 ] && dpkg --compare-versions "$pub" ge "$want"; then
			BUILD_PLAN=skip
			return 0
		fi
		if ! dpkg --compare-versions "$want" gt "$pub"; then
			die "the version to build ($want) is not newer than the published one ($pub). Use a higher --pkgrev (or --rebuild)." 2
		fi
	fi
	BUILD_REV=$rev
	BUILD_VER="$base-$rev+$DISTRO_SUFFIX$tag"
}

# Step 1: everything that can be refused about the package is refused here, before anything is created.
preflight_package() {
	local f
	NEED_BUILD=0
	if [ "${#DEBS[@]}" -gt 0 ]; then
		for f in "${DEBS[@]}"; do
			[ -f "$f" ] || die "no such file: $f" 1
			[ "$(dpkg-deb -f "$f" Package 2> /dev/null)" = hestia ] || die "$f is not a hestia package" 1
		done
		checkout_clean_or_die
	else
		plan_build
		if [ "$BUILD_PLAN" = build ]; then
			checkout_clean_or_die
			NEED_BUILD=1
		fi
	fi
}

build_package() { # sets BUILT_DEB
	local ver bdir ddir rev
	BUILT_DEB=''
	if [ "$BUILD_PLAN" = skip ]; then
		skip "hestia $BUILD_PUB is published for $CODENAME already; not rebuilt (use --rebuild to publish a new revision of this checkout)"
		if [ -n "$(state_get PUBLISHED_COMMIT)" ] && [ "$(state_get PUBLISHED_COMMIT)" != "$(git -C "$CHECKOUT" rev-parse HEAD)" ]; then
			info "note: the checkout has changed since $BUILD_PUB was built. Use --rebuild to publish it."
		fi
		return 0
	fi
	ver=$BUILD_VER
	rev=$BUILD_REV
	# a fresh private directory for every build (removed again when the script ends)
	rm -rf /var/tmp/vylarisspace-build /var/tmp/vylarisspace-build.* 2> /dev/null || true
	BUILD_BASE=$(mktemp -d /var/tmp/vylarisspace-build.XXXXXX)
	bdir="$BUILD_BASE/work"
	ddir="$BUILD_BASE/deb"
	mkdir -p "$bdir" "$ddir" "$BUILD_BASE/archive"
	info "building the panel package $ver from $CHECKOUT"
	info "this takes a few minutes and needs internet (npm, composer). Log: $LOG_FILE.build"
	: > "$LOG_FILE.build"
	if ! (
		# the build creates the package directories itself: they need the normal umask, not this script's
		umask 022
		cd "$CHECKOUT"
		BUILD_DIR="$bdir" DEB_DIR="$ddir" ARCHIVE_DIR="$BUILD_BASE/archive" \
			bash src/hst_autocompile.sh --hestia --noinstall --keepbuild --pkgrev "$rev" '~localsrc' < /dev/null
	) >> "$LOG_FILE.build" 2>&1 9>&-; then
		tail -n 25 "$LOG_FILE.build" >&2
		die "the package build failed. Full output: $LOG_FILE.build" 5
	fi
	BUILT_DEB=$(find "$ddir" -maxdepth 1 -name 'hestia_*.deb' -print -quit)
	[ -n "$BUILT_DEB" ] || die "the build produced no hestia_*.deb in $ddir" 5
	if [ "$(dpkg-deb -f "$BUILT_DEB" Version)" != "$ver" ]; then
		warn "the built package has version $(dpkg-deb -f "$BUILT_DEB" Version), expected $ver"
	fi
	rm -rf "$bdir"
	did "package built: $(basename "$BUILT_DEB")"
}

publish_packages() {
	local f out rc=0 args=()
	local files=()
	if [ "${#DEBS[@]}" -gt 0 ]; then
		for f in "${DEBS[@]}"; do
			files+=("$(readlink -f "$f")")
		done
	else
		build_package
		[ -z "$BUILT_DEB" ] || files+=("$BUILT_DEB")
	fi
	if [ "${#files[@]}" -gt 0 ]; then
		[ -n "$CHECKOUT" ] || die "this script is not inside a git checkout, so the source archive of the package cannot be made." 2
		args=(--source-repo "$CHECKOUT")
		[ "$ALLOW_DIRTY" -eq 0 ] || args+=(--allow-dirty)
		out="$TMP/publish.out"
		env GNUPGHOME="$SIGN_HOME" VYLARIS_SIGN_KEY="$KEY_FPR" \
			bash "$SELF_DIR/repo-publish.sh" "${args[@]}" "$REPO_DIR" "${files[@]}" > "$out" 2>&1 9>&- || rc=$?
		cat "$out" >> "$LOG_FILE" 2> /dev/null || true
		if [ "$rc" -ne 0 ]; then
			tail -n 15 "$out" >&2
			if [ "$rc" -eq 2 ]; then die "publishing was refused (see above). Nothing was damaged." 2; fi
			die "publishing failed (repo-publish.sh exit $rc)." 5
		fi
		grep -E '^(published|  note|  signed by|  source archive)' "$out" | sed 's/^/  /' || true
		did "published ${#files[@]} package file(s)"
		if [ -n "$CHECKOUT" ]; then state_set PUBLISHED_COMMIT "$(git -C "$CHECKOUT" rev-parse HEAD)"; fi
	fi
	collect_suites
	if [ -z "$SERVED_SUITES" ]; then
		warn "the repository is running but serves no hestia package yet. Build/publish one (run again without --deb, or with --deb FILE)."
	fi
}

collect_suites() {
	local s out=''
	for s in $(awk '/^Codename:/{print $2}' "$REPO_DIR/conf/distributions"); do
		case "$s" in *-staging) continue ;; esac
		if [ -n "$(reprepro -b "$REPO_DIR" -T deb list "$s" hestia 2> /dev/null || true)" ]; then
			out="$out $s"
		fi
	done
	SERVED_SUITES=${out# }
	VERIFY_SUITE=$CODENAME
	case " $SERVED_SUITES " in
		*" $CODENAME "*) ;;
		*) [ -z "$SERVED_SUITES" ] || VERIFY_SUITE=${SERVED_SUITES%% *} ;;
	esac
}

# ---------------------------------------------------------------------------------------------
# step 8: verification
# ---------------------------------------------------------------------------------------------
# curl with the repository login without it showing up in a command line.
auth_curl() { # curl-args...  (uses REPO_USER/REPO_PASS in AUTH_MODE=auth)
	if [ "$AUTH_MODE" = auth ]; then
		printf 'user = "%s:%s"\n' "$REPO_USER" "$REPO_PASS" | curl -K - "$@"
	else
		curl "$@"
	fi
}

gpgv_check() { # file -> 0 when signed by the primary key of the repository
	local out got
	out=$(gpgv --keyring "$REPO_DIR/public/pubkey.gpg" --status-fd 1 "$1" 2> /dev/null 9>&-) || return 1
	got=$(printf '%s\n' "$out" | awk '$2=="VALIDSIG"{print $12; exit}')
	[ "$got" = "$KEY_FPR" ]
}

verify_local() {
	local p base="http://127.0.0.1:$LISTEN_PORT" url code ir="$TMP/InRelease.local" hint
	hint="This is a fault on this machine (nginx or the repository) and it will not fix itself by waiting. Look at /var/log/nginx/vylarisspace-repo.error.log and $LOG_FILE, fix it, then run the same command again."
	url="$base/dists/$VERIFY_SUITE/InRelease"
	if [ "$AUTH_MODE" = auth ]; then
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true)
		[ "$code" = 401 ] || die "local check failed: $url without a login answered $code, expected 401. $hint" 5
		info "local: without login -> 401 (password protection works)"
	fi
	code=$(auth_curl -s -o "$ir" -w '%{http_code}' --max-time 15 "$url" || true)
	[ "$code" = 200 ] || die "local check failed: $url answered $code, expected 200. $hint" 5
	gpgv_check "$ir" || die "local check failed: InRelease of $VERIFY_SUITE is NOT signed by $KEY_FPR. $hint" 5
	info "local: InRelease downloaded and its signature is valid for $(fpr_groups "$KEY_FPR")"
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$base/pubkey.gpg" || true)
	[ "$code" = 200 ] || die "local check failed: pubkey.gpg answered $code. $hint" 5
	for p in conf/distributions db/ archive/ logs/; do
		code=$(auth_curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$base/$p" || true)
		case "$code" in
			404 | 403) ;;
			*) die "local check failed: private path /$p answered $code (expected 404). $hint" 5 ;;
		esac
	done
	info "local: pubkey.gpg is open, conf/ db/ archive/ logs/ are not reachable"
	did "local verification passed"
}

verify_public() {
	local url="https://$DOMAIN/dists/$VERIFY_SUITE/InRelease" ir="$TMP/InRelease.public" waited=0 code='' last=''
	while :; do
		code=$(auth_curl -sS -o "$ir" -w '%{http_code}' --connect-timeout 8 --max-time 20 "$url" 2> "$TMP/pub.err") || true
		code=${code:-000}
		if [ "$code" = 200 ] && gpgv_check "$ir" && cmp -s "$ir" "$TMP/InRelease.local"; then
			did "public check passed: $url answers and is signed by $(fpr_groups "$KEY_FPR")"
			return 0
		fi
		last="HTTP $code"
		[ "$code" != 000 ] || last="no answer ($(head -c 150 "$TMP/pub.err" | tr '\n' ' '))"
		[ "$waited" -lt "$VERIFY_WAIT" ] || break
		sleep 5
		waited=$((waited + 5))
	done
	warn "the public address does not answer correctly yet: $url -> $last"
	say "  That is normal in the first minutes: DNS and the tunnel need a little time (sometimes 5-10 minutes)."
	say "  If it stays like this: cloudflared needs outgoing TCP and UDP port 7844 to Cloudflare (firewall), and the"
	say "  tunnel must be healthy (bash $0 --status)."
	say "  Everything on this machine is installed. Wait a few minutes and run the same command again:"
	say "    bash $0 ... (it only checks again), or: bash $0 --status"
	FINAL_RC=6
	return 1
}

# ---------------------------------------------------------------------------------------------
# step 9: output for the owner
# ---------------------------------------------------------------------------------------------
client_text() { # full|masked: prints the instructions (German + English). masked: no password.
	local kind=${1:-masked} url="https://$DOMAIN" fpr="$KEY_FPR" installer='hst-install-ubuntu.sh' auth_shown auth_file="$STATE_DIR/repo-auth"
	cat << TEXT_EOF
VylarisSpace repository / Paket-Quelle
======================================
Address / Adresse : $url
Key fingerprint   : $(fpr_groups "$fpr")
Fingerabdruck des Signaturschluessels (pruefen Sie ihn immer auf einem zweiten Weg).
Serves hestia for / Pakete fuer : ${SERVED_SUITES:-(nothing published yet / noch nichts veroeffentlicht)}
State and keys / Zustand und Schluessel : $STATE_DIR  (back it up / sichern!)
TEXT_EOF
	if [ "$AUTH_MODE" = auth ]; then
		if [ "$kind" = full ]; then
			auth_shown="$REPO_USER:$REPO_PASS"
			printf 'Login (user:password) : %s\n' "$auth_shown"
		else
			auth_shown="<user:password from $auth_file>"
			printf 'Login : user %s, the password is in %s (mode 600).\n' "$REPO_USER" "$auth_file"
			printf '        It is printed only once. To print it again:\n'
			printf '          bash %s/%s --print-client-command --show-login\n' "$SELF_DIR" "$PROG"
			printf '        or: cat %s/CLIENT-INSTALL.txt\n' "$STATE_DIR"
		fi
		cat << TEXT_EOF

A) NEW panel server / NEUER Panel-Server (as root, in a checkout of this repository;
   Debian: hst-install-debian.sh instead of $installer)
   Safest, the login does not land in the shell history / am sichersten, Login nicht in der History.
   ONE line: paste it as a whole, then type the login at the prompt / EINE Zeile, ganz einfuegen:

     read -r -s -p 'Repository login (user:password): ' VYLARIS_REPO_AUTH && echo && export VYLARIS_REPO_AUTH && bash install/$installer --vylaris-repo $url --vylaris-key-fingerprint $fpr

   Short form (the login stays in the shell history / Login bleibt in der History):

     VYLARIS_REPO_AUTH='$auth_shown' bash install/$installer --vylaris-repo $url --vylaris-key-fingerprint $fpr

   (The login is given in the environment variable VYLARIS_REPO_AUTH on purpose: a command line
   option would be visible to every user in "ps" / Der Login steht absichtlich in einer
   Umgebungsvariablen, eine Option waere in "ps" sichtbar.)

B) Server with VylarisSpace/Hestia ALREADY installed / BEREITS installierter Server
   (copy src/vylaris/client-setup.sh to the server / auf den Server kopieren; as root):

     read -r -s -p 'Repository login (user:password): ' VYLARIS_REPO_AUTH && echo && export VYLARIS_REPO_AUTH && bash client-setup.sh --repo $url --key-fingerprint $fpr --update
TEXT_EOF
	else
		cat << TEXT_EOF
No password (public repository / oeffentliche Quelle).

A) NEW panel server / NEUER Panel-Server (as root, in a checkout of this repository;
   Debian: hst-install-debian.sh instead of $installer):

     bash install/$installer --vylaris-repo $url --vylaris-key-fingerprint $fpr

B) Server with VylarisSpace/Hestia ALREADY installed / BEREITS installierter Server
   (copy src/vylaris/client-setup.sh to the server / auf den Server kopieren; as root):

     bash client-setup.sh --repo $url --key-fingerprint $fpr --update
TEXT_EOF
	fi
}

write_client_file() {
	local f="$STATE_DIR/CLIENT-INSTALL.txt"
	# the file is mode 600 in the state directory: it has the password (the terminal shows it only once)
	client_text full > "$TMP/client.txt"
	if [ -f "$f" ] && cmp -s "$TMP/client.txt" "$f"; then
		chmod 600 "$f"
		skip "CLIENT-INSTALL.txt unchanged: $f"
	else
		write_secret "$f" "$(cat "$TMP/client.txt")"
		did "client instructions written: $f (mode 600)"
	fi
}

# The password goes to the terminal only when it was generated and not shown yet, or with --show-login.
login_kind() {
	if [ "$AUTH_MODE" = auth ] && { [ "$SHOW_LOGIN_OPT" -eq 1 ] || [ "$LOGIN_FRESH" -eq 1 ] || [ "$(state_get LOGIN_SHOWN)" = no ]; }; then
		printf 'full'
	else
		printf 'masked'
	fi
}

final_summary() {
	local kind
	kind=$(login_kind)
	say ""
	say "=================================================================================="
	if [ "$FINAL_RC" -eq 0 ] && [ "$SKIP_SERVICE" -eq 1 ]; then
		say " NOCH NICHT FERTIG: DER TUNNEL WIRD VON DIESEM SKRIPT NICHT GESTARTET"
		say " NOT DONE YET: THE TUNNEL IS NOT STARTED BY THIS SCRIPT (--skip-tunnel-service)"
	elif [ "$FINAL_RC" -eq 0 ]; then
		say " FERTIG / DONE  -  VylarisSpace repository host is running"
	else
		say " INSTALLIERT, ABER NOCH NICHT ERREICHBAR / INSTALLED, BUT NOT REACHABLE YET"
	fi
	say "=================================================================================="
	if [ "$FINAL_RC" -eq 0 ] && [ "$SKIP_SERVICE" -eq 1 ]; then
		say ""
		say "The repository is ready on this machine, but nobody can reach it from outside before you start"
		say "the tunnel yourself: https://$DOMAIN does not answer yet. Start cloudflared:"
		print_manual_tunnel
	fi
	cat << SUMMARY_EOF

URL                  : https://$DOMAIN
Schluessel-Fingerabdruck / key fingerprint:
  $(fpr_groups "$KEY_FPR")
Zustand, Schluessel, Login / state, keys, login: $STATE_DIR
Befehl fuer neue Server / command for new servers: $STATE_DIR/CLIENT-INSTALL.txt (mode 600)
Log: $LOG_FILE

SICHERN Sie $STATE_DIR (keys/, key.pass, repo-auth, state.env) auf einem anderen Rechner.
Geht der Schluessel verloren, muessen ALLE Server neu eingerichtet werden.
BACK UP $STATE_DIR to another machine. If the key is lost, EVERY server must be set up again.
Der Cloudflare-API-Token wurde nicht gespeichert; Sie koennen ihn im Dashboard loeschen.
The Cloudflare API token was not saved; you may delete it in the dashboard.

SUMMARY_EOF
	client_text "$kind"
	say ""
	if [ "$kind" = full ]; then
		state_set LOGIN_SHOWN yes
		say "Das Passwort wird nur dieses eine Mal ausgegeben. / The password is printed only this once."
		say "Nochmal anzeigen / To show it again: bash $SELF_DIR/$PROG --print-client-command --show-login   (or: cat $STATE_DIR/CLIENT-INSTALL.txt)"
	fi
	logf "summary shown (key fingerprint $KEY_FPR, domain $DOMAIN)"
}

# ---------------------------------------------------------------------------------------------
# state loading
# ---------------------------------------------------------------------------------------------
# The state directory is recorded in STATE_PTR. A later run uses that one, and refuses a different
# --state-dir: a new directory would mean a new signing key and a new repository password.
resolve_state_dir() {
	local stored=''
	if [ -f "$STATE_PTR" ]; then
		stored=$(head -n1 "$STATE_PTR")
		if [ "$STATE_DIR_GIVEN" -eq 1 ] && [ "$STATE_DIR" != "$stored" ]; then
			die "this machine already uses the state directory $stored (recorded in $STATE_PTR). The directory $STATE_DIR would get a NEW signing key and a NEW repository password and lock out every server. Nothing was changed. Run again with --state-dir $stored (or without --state-dir). Only if $stored never got a signing key (there is no keys/ directory in it) and you really want another directory: delete the file $STATE_PTR and run again." 2
		fi
		clean_path "the state directory recorded in $STATE_PTR" "$stored"
		STATE_DIR=$CLEANED
		state_dir_rules
	fi
	STATE_FILE="$STATE_DIR/state.env"
}

state_dir_rules() {
	case "$STATE_DIR/" in
		/tmp/* | /var/tmp/* | /run/*) die "--state-dir $STATE_DIR is on a temporary file system or in a temporary directory. The keys must live somewhere permanent." 1 ;;
	esac
}

# Create (or accept) the state directory. Install mode only: nothing else creates anything here.
# A directory that already exists is used only when it is ours (marker file) or empty and private;
# it is never given another mode.
init_state_dir() {
	local marker="$STATE_DIR/$STATE_MARKER" owner mode
	if [ -L "$STATE_DIR" ]; then
		die "$STATE_DIR is a symbolic link. Use the real directory." 2
	fi
	if [ -e "$STATE_DIR" ]; then
		[ -d "$STATE_DIR" ] || die "$STATE_DIR exists and is not a directory." 2
		if [ -f "$marker" ] && grep -qxF "$STATE_MARKER_TEXT" "$marker"; then
			chmod 700 "$STATE_DIR" # created by this script earlier
		elif [ -n "$(ls -A "$STATE_DIR" 2> /dev/null)" ]; then
			die "$STATE_DIR exists, is not empty and was not created by this script (its marker file $STATE_MARKER is missing). It was not touched. Choose an empty or new directory with --state-dir. If it IS the state directory of an earlier run of this script: printf '%s\\n' '$STATE_MARKER_TEXT' > $marker" 2
		else
			owner=$(stat -c %u "$STATE_DIR")
			mode=$(stat -c %a "$STATE_DIR")
			if [ "$owner" != 0 ] || [ $((8#$mode & 8#077)) -ne 0 ]; then
				die "$STATE_DIR exists (an empty directory that this script did not create) but is not private: owner id $owner, mode $mode. This script does not change the mode of a directory it did not create. Fix: chown root: $STATE_DIR; chmod 700 $STATE_DIR   (or choose a new directory)." 2
			fi
			printf '%s\n' "$STATE_MARKER_TEXT" > "$marker"
		fi
	else
		mkdir -p "$STATE_DIR"
		chmod 700 "$STATE_DIR"
	fi
	[ -f "$marker" ] || printf '%s\n' "$STATE_MARKER_TEXT" > "$marker"
}

# The state directory is recorded only when a signing key exists in it: from then on a different
# --state-dir is refused (it would mean a new key). An empty directory of a run that failed early pins nothing.
record_state_ptr() {
	mkdir -p "$TUNNEL_ENV_DIR"
	chmod 700 "$TUNNEL_ENV_DIR"
	if [ ! -f "$STATE_PTR" ] || [ "$(head -n1 "$STATE_PTR")" != "$STATE_DIR" ]; then
		write_secret "$STATE_PTR" "$STATE_DIR"
	fi
}

load_state() {
	local v
	resolve_state_dir
	v=$(state_get DOMAIN)
	if [ -n "$v" ] && [ -n "$DOMAIN" ] && [ "$v" != "$DOMAIN" ]; then
		die "this machine is already set up for $v (state: $STATE_FILE). Another domain is not taken over silently. To move to $DOMAIN: run with --uninstall-tunnel --delete-dns first (the signing key stays), then run again." 2
	fi
	DOMAIN=${DOMAIN:-$v}
	v=$(state_get TUNNEL_ID)
	if [ -n "$v" ] && [ -n "$TUNNEL_NAME" ] && [ "$TUNNEL_NAME" != "$(state_get TUNNEL_NAME)" ]; then
		die "this machine already uses the tunnel \"$(state_get TUNNEL_NAME)\" ($v, state: $STATE_FILE). The name \"$TUNNEL_NAME\" would mean a second tunnel, so it is not taken over silently. Run without --tunnel-name (or with --tunnel-name $(state_get TUNNEL_NAME)). To move to another tunnel: run --uninstall-tunnel --delete-dns first; a tunnel that this script did not create stays at Cloudflare and stays in the state, then also delete the lines TUNNEL_ID= and TUNNEL_CREATED= in $STATE_FILE." 2
	fi
	TUNNEL_NAME=${TUNNEL_NAME:-$(state_get TUNNEL_NAME)}
	TUNNEL_NAME=${TUNNEL_NAME:-vylarisspace-repo}
	v=$(state_get LISTEN_PORT)
	LISTEN_PORT=${LISTEN_PORT:-${v:-$DEFAULT_PORT}}
	v=$(state_get REPO_DIR)
	if [ -n "$v" ] && [ -n "$REPO_DIR" ] && [ "$v" != "$REPO_DIR" ]; then
		die "the repository of this host is $v (state), not $REPO_DIR. Moving it is not done automatically." 2
	fi
	REPO_DIR=${REPO_DIR:-${v:-/srv/vylarisspace-repo}}
	TUNNEL_ID=$(state_get TUNNEL_ID)
	TUNNEL_CREATED=$(state_get TUNNEL_CREATED)
	KEY_FPR=$(state_get KEY_FPR)
	AUTH_MODE=${AUTH_WANT:-$(state_get AUTH_MODE)}
	AUTH_MODE=${AUTH_MODE:-auth}
	if [ -n "$AUTH_USER" ] && [ "$AUTH_MODE" = public ]; then
		die "--auth-user needs password protection, but the host is saved as public: add --auth to switch back." 1
	fi
	KEY_OUT="$STATE_DIR/keys/out"
	SIGN_HOME="$STATE_DIR/keys/gnupg-signing"
}

# Checks what was given on the command line, before anything is read or created, and again with the
# complete values (state + defaults).
validate_inputs() {
	if [ -n "$LISTEN_PORT" ]; then
		[[ $LISTEN_PORT =~ ^[0-9]+$ ]] && [ "$LISTEN_PORT" -ge 1024 ] && [ "$LISTEN_PORT" -le 65535 ] || die "--listen-port must be a number from 1024 to 65535" 1
	fi
	if [ -n "$REPO_DIR" ]; then
		clean_path --repo-dir "$REPO_DIR"
		REPO_DIR=$CLEANED
	fi
	clean_path --state-dir "$STATE_DIR"
	STATE_DIR=$CLEANED
	state_dir_rules
	if [ -n "$REPO_DIR" ]; then
		case "$STATE_DIR/" in "$REPO_DIR"/*) die "--state-dir ($STATE_DIR) must not be inside the repository directory ($REPO_DIR): it holds the keys." 1 ;; esac
		case "$REPO_DIR/" in "$STATE_DIR"/*) die "--repo-dir ($REPO_DIR) must not be inside the state directory ($STATE_DIR)." 1 ;; esac
	fi
	if [ -n "$TUNNEL_NAME" ]; then
		[[ $TUNNEL_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "--tunnel-name: letters, digits, . _ - only" 1
	fi
	if [ -n "$AUTH_USER" ] && ! [[ $AUTH_USER =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; then
		die "--auth-user: letters, digits, . _ - only (no colon, space or quote)" 1
	fi
	if [ -n "$PKGREV" ] && ! [[ $PKGREV =~ ^[0-9]+$ ]]; then
		die "--pkgrev must be a number" 1
	fi
	if [ -n "$AUTH_USER" ] && { [ "$AUTH_MODE" = public ] || [ "$AUTH_WANT" = public ]; }; then
		die "--auth-user and --public exclude each other" 1
	fi
}

need_domain() {
	local d=''
	if [ -z "$DOMAIN" ]; then
		if [ -t 0 ]; then
			read -r -p "Domain for the repository (for example repo.example.com): " d
			DOMAIN=$d
		fi
		[ -n "$DOMAIN" ] || die "the domain is missing. Use --domain repo.example.com" 1
	fi
	normalize_domain
}

# The Cloudflare token goes to this address: https, except for a test server on this machine.
check_cf_base() {
	if [[ $CF_BASE =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] \
		|| [[ $CF_BASE =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]]; then
		return 0
	fi
	die "VYLARIS_CF_API_BASE must start with https:// (plain http:// is accepted only for 127.0.0.1 or localhost), and contain no user name or odd characters: $CF_BASE. The API token would be sent there." 1
}

# One run at a time (two runs could create two keys, two tunnels). The lock file lives in /run (a
# directory only root can write to); /run/lock and /var/lock are the fallbacks.
acquire_lock() {
	local dir='' d
	command -v flock > /dev/null 2>&1 || die "flock (package util-linux) is missing" 3
	for d in /run /run/lock /var/lock; do
		if [ -d "$d" ] && [ -w "$d" ]; then
			dir=$d
			break
		fi
	done
	[ -n "$dir" ] || die "there is no directory for the lock file (/run, /run/lock and /var/lock are not writable)." 3
	LOCK_FILE="$dir/vylarisspace-repo-host.lock"
	{ exec 9> "$LOCK_FILE"; } 2> /dev/null || die "cannot open the lock file $LOCK_FILE (is there a directory or a file of another user with this name? remove it and run again)." 3
	flock -n 9 || die "another run of this script is active (lock $LOCK_FILE). Wait until it has finished, then run again." 2
}

# A private temporary directory, on a memory file system (/run) when there is one: the tunnel token
# passes through it.
setup_tmp() {
	TMP=''
	if [ -d /run ] && [ -w /run ]; then
		TMP=$(mktemp -d /run/vylarisspace-repo-host.XXXXXX 2> /dev/null) || TMP=''
	fi
	[ -n "$TMP" ] || TMP=$(mktemp -d)
}

# ---------------------------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------------------------
mode_install() {
	need_domain
	validate_inputs
	need_token
	say "VylarisSpace repository host installer"
	say "  domain: $DOMAIN   repository: $REPO_DIR   state: $STATE_DIR   log: $LOG_FILE"
	if [ "$AUTH_MODE" = public ] && [ -z "$AUTH_WANT" ]; then
		say "  The host is saved as public (no password): add --auth to switch back to password protection."
	fi
	if [ -z "$(state_get DOMAIN)" ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
		say "  This will install packages (nginx, reprepro, ...), create a signing key, a repository, a"
		say "  Cloudflare tunnel and a DNS record for $DOMAIN."
		ask_yes "Continue?" || die "stopped by you. Nothing was changed." 2
	fi

	# Step 1 first installs the packages and makes the (empty) state directory. Then every refusal that can be
	# known in advance comes, and only after that the first thing is created: the tunnel at Cloudflare (the first
	# write with the token, so a token that may only read stops the run here, before key and repository).
	step 1 "System, packages, checks, Cloudflare access, tunnel"
	detect_system
	die_if_earlier_run_without_key
	init_state_dir
	remove_stale_policy_rc
	ensure_packages
	find_checkout
	preflight_package
	check_disk "$NEED_BUILD"
	repo_precheck
	nginx_precheck
	cf_preflight
	state_set TUNNEL_NAME "$TUNNEL_NAME"
	cf_ensure_tunnel
	state_set DOMAIN "$DOMAIN" # (only now: a run that failed before the tunnel exists does not pin the domain)

	step 2 "Signing key"
	ensure_signing_key

	step 3 "Repository"
	ensure_repo

	step 4 "nginx (127.0.0.1:$LISTEN_PORT, ${AUTH_MODE})"
	ensure_nginx

	step 5 "Cloudflare tunnel route and DNS"
	cf_ensure_ingress
	cf_ensure_dns
	cf_store_tunnel_token

	step 6 "cloudflared"
	if [ "$SKIP_SERVICE" -eq 1 ]; then
		skip "cloudflared service (--skip-tunnel-service)"
		print_manual_tunnel
	else
		install_cloudflared
		ensure_service
		wait_tunnel_healthy || true
	fi

	step 7 "Package"
	publish_packages

	step 8 "Verification"
	verify_local
	if [ "$SKIP_SERVICE" -eq 1 ]; then
		skip "public check: the tunnel is not run by this script (--skip-tunnel-service)"
	else
		verify_public || true
	fi

	step 9 "Result"
	write_client_file
	final_summary
	exit "$FINAL_RC"
}

load_for_readonly() {
	resolve_state_dir
	[ -f "$STATE_FILE" ] || die "no state found in $STATE_DIR: this machine is not set up yet (run the installer first)." 1
	DOMAIN=$(state_get DOMAIN)
	KEY_FPR=$(state_get KEY_FPR)
	TUNNEL_ID=$(state_get TUNNEL_ID)
	TUNNEL_CREATED=$(state_get TUNNEL_CREATED)
	TUNNEL_NAME=$(state_get TUNNEL_NAME)
	LISTEN_PORT=$(state_get LISTEN_PORT)
	REPO_DIR=$(state_get REPO_DIR)
	AUTH_MODE=$(state_get AUTH_MODE)
	AUTH_MODE=${AUTH_MODE:-auth}
	[ -n "$DOMAIN" ] && [ -n "$KEY_FPR" ] && [ -n "$LISTEN_PORT" ] && [ -n "$REPO_DIR" ] || die "the state in $STATE_FILE is incomplete" 1
	if [ "$AUTH_MODE" = auth ]; then
		[ -s "$STATE_DIR/repo-auth" ] || die "$STATE_DIR/repo-auth is missing" 1
		REPO_USER=$(head -n1 "$STATE_DIR/repo-auth")
		REPO_PASS=${REPO_USER#*:}
		REPO_USER=${REPO_USER%%:*}
	fi
}

mode_print() {
	detect_system
	load_for_readonly
	collect_suites
	if [ "$SHOW_LOGIN_OPT" -eq 1 ]; then
		client_text full
	else
		client_text masked
	fi
	logf "client command printed"
}

mode_status() {
	local rc=0 code st conns s v enabled n zrc
	detect_system
	load_for_readonly
	collect_suites
	say "VylarisSpace repository host - status"
	say "  domain        : $DOMAIN  (key fingerprint $(fpr_groups "$KEY_FPR"))"
	say "  repository    : $REPO_DIR  access: $AUTH_MODE  local port: $LISTEN_PORT"
	if systemctl is-active --quiet nginx 2> /dev/null; then
		say "  nginx         : running"
	elif pgrep -x nginx > /dev/null 2>&1; then
		say "  nginx         : running (without systemd)"
	else
		say "  nginx         : NOT running"
		rc=6
	fi
	if [ -f "$NGX_CONF" ]; then
		code=$(auth_curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$LISTEN_PORT/dists/${VERIFY_SUITE:-$CODENAME}/InRelease" || true)
		if [ "$code" = 200 ]; then
			say "  local site    : answers (InRelease HTTP 200)"
		else
			say "  local site    : does NOT answer correctly (HTTP ${code:-none})"
			rc=6
		fi
	else
		say "  local site    : $NGX_CONF is missing"
		rc=6
	fi
	if command -v systemctl > /dev/null 2>&1 && [ -f "$UNIT_FILE" ]; then
		enabled=$(systemctl is-enabled "$SERVICE_NAME" 2> /dev/null || true)
		if systemctl is-active --quiet "$SERVICE_NAME" 2> /dev/null; then
			say "  cloudflared   : service $SERVICE_NAME running (${enabled:-?}), $(cloudflared --version 2> /dev/null | head -n1)"
		else
			say "  cloudflared   : service $SERVICE_NAME NOT running (${enabled:-?})"
			rc=6
		fi
	else
		say "  cloudflared   : no service installed by this script"
	fi
	# (the token prompt says that Enter skips the tunnel check; an API problem is reported, not fatal)
	TOKEN_OPTIONAL=1
	if read_token; then
		zrc=0
		cf_find_zone_try || zrc=$?
		if [ "$zrc" -eq 2 ]; then
			say "  tunnel        : not checked (the domain $DOMAIN is not in the Cloudflare account of this token)"
		elif [ "$zrc" -ne 0 ]; then
			say "  tunnel        : not checked (${CF_ERR:-no answer from Cloudflare})"
		elif [ -z "$TUNNEL_ID" ]; then
			say "  tunnel        : not checked (no tunnel id in the state)"
		elif cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID"; then
			st=$(cf_jq '.result.status // "unknown"')
			conns=$(cf_jq '[.result.connections[]?] | length')
			n=''
			[ "$conns" -le 0 ] || n=", $conns connection(s)"
			case "$st" in
				healthy) say "  tunnel        : $TUNNEL_NAME ($TUNNEL_ID) status $st$n" ;;
				degraded) say "  tunnel        : $TUNNEL_NAME ($TUNNEL_ID) status $st$n (up with reduced redundancy)" ;;
				*)
					say "  tunnel        : $TUNNEL_NAME ($TUNNEL_ID) status $st$n"
					rc=6
					;;
			esac
		elif [ "$CF_HTTP" = 404 ]; then
			say "  tunnel        : $TUNNEL_NAME ($TUNNEL_ID) does NOT exist at Cloudflare any more (run the installer again to create it)"
			rc=6
		else
			say "  tunnel        : not checked (${CF_ERR:-no answer from Cloudflare})"
		fi
	else
		say "  tunnel        : not checked (no API token given: set CLOUDFLARE_API_TOKEN, use --cf-token-file FILE, or type it at the prompt)"
	fi
	say "  published     :"
	for s in $(awk '/^Codename:/{print $2}' "$REPO_DIR/conf/distributions"); do
		v=$(reprepro -b "$REPO_DIR" -T deb list "$s" hestia 2> /dev/null | sed 's/^[^:]*|[^:]*|\([^:]*\): hestia /\1 /' | tr '\n' ';' || true)
		say "    $s: ${v:-nothing}"
	done
	exit "$rc"
}

mode_uninstall() {
	local id content type ours=0
	detect_system
	load_for_readonly
	if [ "$DELETE_DNS" -eq 1 ]; then
		need_token
		# Everything that can fail at Cloudflare is asked BEFORE anything is stopped or removed: a wrong token or
		# a missing permission ends the run here, with nothing torn down.
		cf_find_zone
		cf_dns_list
		if [ -n "$TUNNEL_ID" ] && [ "$TUNNEL_CREATED" = yes ]; then
			if ! cf_request GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" && [ "$CF_HTTP" != 404 ]; then
				cf_die "reading the tunnel $TUNNEL_ID"
			fi
		fi
		if [ "$TUNNEL_CREATED" = yes ]; then
			say "This stops the cloudflared service and DELETES the DNS record of $DOMAIN and the tunnel $TUNNEL_NAME (created by this script)."
		else
			say "This stops the cloudflared service and DELETES the DNS record of $DOMAIN. The tunnel $TUNNEL_NAME was not created by this script: it is left alone."
		fi
	else
		say "This stops and removes the cloudflared service (tunnel and DNS record stay)."
	fi
	say "The repository, the nginx site and the signing key are kept."
	ask_yes "Continue?" || die "stopped by you. Nothing was changed." 2
	if command -v systemctl > /dev/null 2>&1 && [ -f "$UNIT_FILE" ]; then
		systemctl disable --now "$SERVICE_NAME" > /dev/null 2>&1 || true
		rm -f "$UNIT_FILE"
		systemctl daemon-reload || true
		did "service $SERVICE_NAME stopped and removed"
	else
		skip "no service $SERVICE_NAME installed"
	fi
	rm -f "$TUNNEL_ENV"
	if [ "$DELETE_DNS" -eq 1 ]; then
		while IFS=$'\t' read -r id type content; do
			if [ -n "$TUNNEL_ID" ] && [ "$type" = CNAME ] && [ "${content,,}" = "$TUNNEL_ID.cfargotunnel.com" ]; then
				cf_request DELETE "/zones/$ZONE_ID/dns_records/$id" || cf_die "deleting the DNS record (the cloudflared service is stopped already)"
				did "DNS record deleted: $DOMAIN"
				ours=1
			else
				skip "DNS record $type $content is not ours, left alone"
			fi
		done < <(printf '%s' "$DNS_RECORDS_JSON" | jq -r '.[] | [.id, .type, .content] | @tsv')
		[ "$ours" -eq 1 ] || skip "no DNS record of this tunnel found for $DOMAIN"
		if [ -n "$TUNNEL_ID" ] && [ "$TUNNEL_CREATED" = yes ]; then
			cf_request DELETE "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/connections" || true
			if cf_request DELETE "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID"; then
				did "tunnel deleted: $TUNNEL_NAME"
			elif [ "$CF_HTTP" = 404 ]; then
				skip "tunnel $TUNNEL_NAME was gone already"
			else
				cf_die "deleting the tunnel (the cloudflared service and the DNS record are gone already)"
			fi
			state_del TUNNEL_ID
			state_del TUNNEL_CREATED
			say "  The domain and tunnel are forgotten; the key and repository stay. Run the installer again with a domain to set up a tunnel."
		else
			if [ -n "$TUNNEL_ID" ]; then
				skip "tunnel $TUNNEL_NAME ($TUNNEL_ID) was not created by this script: it is left alone (delete it in the Cloudflare dashboard if nothing uses it)"
			fi
			say "  The domain is forgotten; the key and repository stay. Run the installer again with a domain to set up DNS again (the tunnel above is reused)."
		fi
		state_del DOMAIN
	fi
	exit 0
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
main() {
	parse_args "$@"
	if [ "$DELETE_DNS" -eq 1 ] && [ "$MODE" != uninstall ]; then
		printf '%s: --delete-dns only works together with --uninstall-tunnel (try --help)\n' "$PROG" >&2
		exit 1
	fi
	[ "$(id -u)" -eq 0 ] || die "run this as root (sudo -i, then run the command again)." 3
	check_cf_base
	setup_tmp
	trap cleanup EXIT
	( umask 077 && touch "$LOG_FILE" ) 2> /dev/null || LOG_FILE=/dev/null
	logf "start: $PROG mode=$MODE (temporary files: $TMP)"
	if [ "$TRACE_WAS_ON" -eq 1 ]; then
		say "note: shell tracing (bash -x) was switched off, secrets are in use"
	fi
	case "$MODE" in
		install | uninstall) acquire_lock ;;
	esac
	normalize_domain
	validate_inputs
	case "$MODE" in
		install)
			load_state
			mode_install
			;;
		print) mode_print ;;
		status) mode_status ;;
		uninstall) mode_uninstall ;;
	esac
}

main "$@"
