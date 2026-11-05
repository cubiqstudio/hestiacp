#!/usr/bin/env bash
#
# repo-init.sh - create the reprepro layout of the VylarisSpace apt repository.
#
# Usage:
#   VYLARIS_SIGN_KEY=<fingerprint> repo-init.sh [options] <repo-dir>
#
# Environment:
#   VYLARIS_SIGN_KEY   fingerprint (or key id) of the signing key. Required. The secret key (or
#                      signing subkey) must be in the GnuPG home that is used (GNUPGHOME).
#   GNUPGHOME          GnuPG home with the signing key (default ~/.gnupg).
#
# Options:
#   --pubkey FILE      public key to publish (armored or binary). Default: exported from GNUPGHOME.
#   --archs "A B"      architectures, default "amd64 arm64".
#   --staging          also create a <codename>-staging suite for each codename.
#   --server-name HOST host name used in the nginx sample (default: repo.example.invalid).
#   -h, --help
#
# Layout created in <repo-dir> (the web server must serve ONLY <repo-dir>/public):
#   conf/              reprepro configuration (private)
#   db/ logs/          reprepro state (private, back it up)
#   archive/<suite>/   last N published debs per suite for rollbacks (private)
#   public/dists  public/pool   the apt repository
#   public/pubkey.gpg  public/pubkey.asc   public key (binary and armored)
#   public/sources/    source archives for the GPL source offer (repo-publish.sh)
#   nginx-vylarisspace-repo.conf.sample
#
# Suites (one per supported codename; apt uses the codename of the server):
#   bookworm (Debian 12), trixie (Debian 13), jammy (Ubuntu 22.04), noble (Ubuntu 24.04)

set -euo pipefail
umask 022

PROG=$(basename "$0")
ARCHS='amd64 arm64'
CODENAMES='bookworm trixie jammy noble'
STAGING=0
PUBKEY=''
SERVER_NAME='repo.example.invalid'

die() {
	echo "$PROG: $1" >&2
	exit "${2:-1}"
}

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

inside_git_tree() {
	local p
	p=$(realpath -m -- "$1")
	while [ ! -e "$p" ] && [ "$p" != "/" ]; do
		p=$(dirname "$p")
	done
	[ -d "$p" ] || p=$(dirname "$p")
	while :; do
		if [ -e "$p/.git" ]; then
			return 0
		fi
		[ "$p" = "/" ] && break
		p=$(dirname "$p")
	done
	return 1
}

POSITIONAL=()
while [ $# -gt 0 ]; do
	case "$1" in
		--pubkey)
			[ $# -ge 2 ] || die "--pubkey needs a value"
			PUBKEY="$2"
			shift 2
			;;
		--archs)
			[ $# -ge 2 ] || die "--archs needs a value"
			ARCHS="$2"
			shift 2
			;;
		--staging)
			STAGING=1
			shift
			;;
		--server-name)
			[ $# -ge 2 ] || die "--server-name needs a value"
			SERVER_NAME="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			die "unknown option: $1"
			;;
		*)
			POSITIONAL+=("$1")
			shift
			;;
	esac
done

[ "${#POSITIONAL[@]}" -eq 1 ] || {
	usage >&2
	exit 1
}
REPO=$(realpath -m -- "${POSITIONAL[0]}")
if [ -z "$REPO" ] || [ "$REPO" = "/" ]; then
	die "invalid repository directory"
fi

command -v reprepro > /dev/null 2>&1 || die "reprepro is not installed (apt-get install reprepro)"
command -v gpg > /dev/null 2>&1 || die "gpg is not installed"

SIGN_KEY="${VYLARIS_SIGN_KEY:-}"
[ -n "$SIGN_KEY" ] || die "VYLARIS_SIGN_KEY is not set (fingerprint of the signing key, see make-signing-key.sh)"
if ! [[ "$SIGN_KEY" =~ ^[0-9A-Fa-f]{8,40}!?$ ]]; then
	die "VYLARIS_SIGN_KEY must be a hex key id or fingerprint (optionally followed by !)"
fi
case "$ARCHS" in
	*[!a-z0-9\ ]*) die "invalid --archs value" ;;
esac
case "$SERVER_NAME" in
	*[!a-zA-Z0-9.-]*) die "invalid --server-name value" ;;
esac

if inside_git_tree "$REPO"; then
	die "refusing: $REPO lies inside a git working tree. Keep the repository (packages, database) outside of git." 2
fi
if [ -e "$REPO/conf/distributions" ]; then
	die "refusing: $REPO is already initialised (conf/distributions exists)" 2
fi

# The secret key must be usable for signing.
if ! gpg --batch --list-secret-keys --with-colons "${SIGN_KEY%\!}" 2> /dev/null | grep -q '^\(sec\|ssb\)'; then
	die "no secret key found for $SIGN_KEY in GNUPGHOME=${GNUPGHOME:-$HOME/.gnupg}" 2
fi

mkdir -p "$REPO"/conf "$REPO"/db "$REPO"/logs "$REPO"/archive \
	"$REPO"/public/dists "$REPO"/public/pool "$REPO"/public/sources
chmod 700 "$REPO"/db "$REPO"/logs "$REPO"/archive "$REPO"/conf

# --- conf/distributions -----------------------------------------------------------------------
DIST="$REPO/conf/distributions"
: > "$DIST"
write_suite() {
	local name="$1" label="$2"
	{
		echo "Origin: VylarisSpace"
		echo "Label: $label"
		echo "Codename: $name"
		echo "Suite: $name"
		echo "Description: VylarisSpace panel package for $name"
		echo "Components: main"
		echo "Architectures: $ARCHS"
		echo "SignWith: $SIGN_KEY"
		echo
	} >> "$DIST"
}
for c in $CODENAMES; do
	write_suite "$c" 'VylarisSpace'
	if [ "$STAGING" -eq 1 ]; then
		write_suite "$c-staging" 'VylarisSpace staging'
	fi
done

cat > "$REPO/conf/options" << 'OPTIONS_EOF'
# Directories are relative to the base directory given with -b.
# Only public/ is served by the web server; conf, db, logs and archive stay private.
outdir +b/public
dbdir +b/db
logdir +b/logs
OPTIONS_EOF

# --- public key ---------------------------------------------------------------------------------
TMPKEY=$(mktemp)
trap 'rm -f "$TMPKEY"' EXIT
if [ -n "$PUBKEY" ]; then
	[ -s "$PUBKEY" ] || die "public key file not found: $PUBKEY"
	cp -- "$PUBKEY" "$TMPKEY"
else
	gpg --batch --export "${SIGN_KEY%\!}" > "$TMPKEY"
fi
[ -s "$TMPKEY" ] || die "could not obtain the public key"
# Normalise: dearmored binary keyring and armored copy, whatever the input was.
if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$TMPKEY"; then
	gpg --batch --dearmor < "$TMPKEY" > "$REPO/public/pubkey.gpg"
else
	cp -- "$TMPKEY" "$REPO/public/pubkey.gpg"
fi
gpg --batch --yes --armor --export-options export-minimal \
	--no-default-keyring --keyring "$REPO/public/pubkey.gpg" --export > "$REPO/public/pubkey.asc"
chmod 644 "$REPO/public/pubkey.gpg" "$REPO/public/pubkey.asc"

PUB_FPRS=$(gpg --batch --show-keys --with-colons "$REPO/public/pubkey.gpg" 2> /dev/null | awk -F: '$1=="fpr"{print $10}')
[ -n "$PUB_FPRS" ] || die "the public key file contains no key"
if ! printf '%s\n' "$PUB_FPRS" | grep -qi "${SIGN_KEY%\!}\$"; then
	echo "$PROG: warning: $SIGN_KEY is not the fingerprint of a key in public/pubkey.gpg (is it a short key id?)" >&2
fi

# --- nginx sample -------------------------------------------------------------------------------
cat > "$REPO/nginx-vylarisspace-repo.conf.sample" << NGINX_EOF
# Sample nginx server block for the VylarisSpace apt repository (static files only).
# Copy to /etc/nginx/conf.d/, adjust the names and paths, then: nginx -t && systemctl reload nginx
#
# Basic auth (optional, recommended for a private repository), one user per server:
#   printf '%s:%s\n' server01 "\$(openssl passwd -apr1)" >> /etc/nginx/vylarisspace-repo.htpasswd
#   chgrp www-data /etc/nginx/vylarisspace-repo.htpasswd && chmod 640 /etc/nginx/vylarisspace-repo.htpasswd
# The same credentials go into /etc/apt/auth.conf.d/vylarisspace.conf on the server
# (src/vylaris/client-setup.sh does that when VYLARIS_REPO_AUTH=user:password is set).
# One user per server lets you lock out a single server.

server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name $SERVER_NAME;

	ssl_certificate     /etc/ssl/vylarisspace-repo/fullchain.pem;   # your certificate
	ssl_certificate_key /etc/ssl/vylarisspace-repo/privkey.pem;

	# ONLY the public/ directory is served. conf/, db/, logs/ and archive/ must never be reachable.
	root $REPO/public;
	autoindex off;
	server_tokens off;

	# Remove these three lines for a public repository.
	auth_basic           "VylarisSpace repository";
	auth_basic_user_file /etc/nginx/vylarisspace-repo.htpasswd;
	satisfy              all;

	# The public key is public by definition. Leaving it open lets a server fetch it
	# before credentials are configured (optional).
	location = /pubkey.gpg {
		auth_basic off;
	}
	location = /pubkey.asc {
		auth_basic off;
	}

	# Release/InRelease change on every publish: do not cache the index files.
	location /dists/ {
		expires -1;
		add_header Cache-Control "no-cache";
	}
	location /pool/ {
		expires 1h;
	}

	location ~ /\. {
		deny all;
	}
	location / {
		try_files \$uri =404;
	}
}
NGINX_EOF

# Export the (still empty) indices once: this creates and signs dists/<suite>/Release for every suite
# and proves that the signing key works.
reprepro -b "$REPO" export > /dev/null

echo "Repository initialised: $REPO"
echo "  suites        : $(grep '^Codename:' "$DIST" | awk '{print $2}' | tr '\n' ' ')"
echo "  architectures : $ARCHS"
echo "  signing key   : $SIGN_KEY"
echo "  served root   : $REPO/public"
echo "  indices       : exported and signed (test of the signing key: ok)"
echo "  next          : repo-publish.sh $REPO <hestia_*.deb>"
