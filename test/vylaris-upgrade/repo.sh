#!/usr/bin/env bash
# repo.sh - the throw-away signed apt repository of the upgrade test (host side).
#
#   repo.sh init <state-dir>            test CA, server certificate for $REPO_HOST, signing key,
#                                       empty signed repository (src/vylaris/*.sh)
#   repo.sh publish <state-dir> <deb>   publish a deb (src/vylaris/repo-publish.sh --allow-dirty)
#   repo.sh clean <state-dir>           remove the short GnuPG homes created under /tmp
#
# Everything is generated fresh, nothing is reused from the project. The GnuPG homes live
# under /tmp/vylup-gnupg-* because gpg-agent needs a short socket path (about 80 characters).
# <state-dir>/env holds the values the other scripts source.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VYL="$ROOT/src/vylaris"
REPO_HOST=${REPO_HOST:-repo.vylaris.test}

cmd=${1:-}
state=${2:-}
[ -n "$cmd" ] && [ -n "$state" ] || {
	sed -n '2,12p' "$0"
	exit 1
}
mkdir -p "$state"
state=$(cd "$state" && pwd)

case "$cmd" in
	init)
		[ ! -e "$state/env" ] || {
			echo "repo.sh: $state already initialised" >&2
			exit 1
		}
		# test CA + server certificate (SAN = the repository host name)
		mkdir -p "$state/ca"
		openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj "/CN=VylarisSpace upgrade test CA" \
			-keyout "$state/ca/ca.key" -out "$state/ca/ca.crt" 2> /dev/null
		openssl req -newkey rsa:3072 -nodes -subj "/CN=$REPO_HOST" -keyout "$state/ca/server.key" \
			-out "$state/ca/server.csr" 2> /dev/null
		printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' "$REPO_HOST" > "$state/ca/ext.cnf"
		openssl x509 -req -in "$state/ca/server.csr" -CA "$state/ca/ca.crt" -CAkey "$state/ca/ca.key" \
			-CAcreateserial -days 30 -extfile "$state/ca/ext.cnf" -out "$state/ca/server.crt" 2> /dev/null
		chmod 644 "$state"/ca/*
		# signing key: primary + signing subkey, no passphrase (test only), second home with the subkey only
		prim=$(mktemp -d /tmp/vylup-gnupg-primary.XXXXXX)
		sign=$(mktemp -d /tmp/vylup-gnupg-sign.XXXXXX)
		rmdir "$prim" "$sign"
		"$VYL/make-signing-key.sh" --no-passphrase --signing-home "$sign" --uid "VylarisSpace upgrade test key" \
			"$state/keys" "$prim" > "$state/keys.log" 2>&1 || {
			cat "$state/keys.log" >&2
			exit 1
		}
		fpr=$(gpg --show-keys --with-colons "$state/keys/pubkey.asc" | awk -F: '$1=="fpr"{print $10; exit}')
		export GNUPGHOME=$sign VYLARIS_SIGN_KEY=$fpr
		"$VYL/repo-init.sh" --archs amd64 --server-name "$REPO_HOST" "$state/repo" > "$state/repo-init.log" 2>&1 \
			|| {
				cat "$state/repo-init.log" >&2
				exit 1
			}
		{
			echo "REPO_HOST=$REPO_HOST"
			echo "KEY_FPR=$fpr"
			echo "SIGN_HOME=$sign"
			echo "PRIM_HOME=$prim"
		} > "$state/env"
		echo "repository initialised: host=$REPO_HOST fingerprint=$fpr"
		;;
	publish)
		deb=${3:?deb}
		# shellcheck disable=SC1091
		. "$state/env"
		export GNUPGHOME=$SIGN_HOME VYLARIS_SIGN_KEY=$KEY_FPR
		"$VYL/repo-publish.sh" --allow-dirty --keep 5 "$state/repo" "$deb"
		;;
	clean)
		if [ -f "$state/env" ]; then
			# shellcheck disable=SC1091
			. "$state/env"
			for d in "$SIGN_HOME" "$PRIM_HOME"; do
				GNUPGHOME=$d gpgconf --kill gpg-agent 2> /dev/null || true
				rm -rf "$d"
			done
		fi
		;;
	*)
		echo "repo.sh: unknown command $cmd" >&2
		exit 1
		;;
esac
