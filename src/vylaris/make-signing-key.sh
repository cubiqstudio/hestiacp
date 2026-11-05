#!/usr/bin/env bash
#
# make-signing-key.sh - create the signing key pair of the VylarisSpace apt repository.
#
# Run this ONCE on a machine the owner controls (never inside the git working tree
# and never on a customer server). It creates a NEW key; it never touches or reuses
# install/deb/deb_signing.key (that file is the upstream project's public key).
#
# Layout of the key:
#   primary key  : ed25519 (or RSA 4096), capability "certify" only, expires after 2 years
#   subkey       : same algorithm, capability "sign" only, same expiry
# The primary key is meant to live OFFLINE. Only the signing subkey goes to the
# machine that runs reprepro (see README.md in this directory).
#
# Usage:
#   make-signing-key.sh [options] <target-dir> <gnupghome>
#
#   <target-dir>   receives pubkey.asc, vylarisspace-keyring.gpg, the revocation
#                  certificate and the secret key exports (mode 600).
#   <gnupghome>    new, empty GnuPG home directory in which the key is generated.
#
# Options:
#   --uid TEXT              user id of the key (default: "VylarisSpace Package Signing Key").
#                           No e-mail address is added on purpose.
#   --algo ed25519|rsa4096  default ed25519. See README.md for the compatibility notes.
#   --expire SPEC           gpg expiry spec, default 2y.
#   --passphrase-file FILE  protect the secret keys with the passphrase in FILE (first line).
#   --no-passphrase         generate unprotected secret keys (tests only; must be chosen
#                           explicitly because there is no default).
#   --signing-home DIR      additionally create a second GnuPG home that contains ONLY the
#                           signing subkey (the primary key is a stub, "sec#") and no passphrase,
#                           for the unattended reprepro host.
#   -h, --help
#
# Exit codes: 0 ok, 1 usage or environment error, 2 refused (unsafe location or existing key).

set -euo pipefail
umask 077

PROG=$(basename "$0")
UID_TEXT='VylarisSpace Package Signing Key'
ALGO='ed25519'
EXPIRE='2y'
PASS_FILE=''
NO_PASS=0
SIGNING_HOME=''

die() {
	echo "$PROG: $1" >&2
	exit "${2:-1}"
}

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

# Is the path (or its nearest existing parent) inside a git working tree?
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
		--uid)
			[ $# -ge 2 ] || die "--uid needs a value"
			UID_TEXT="$2"
			shift 2
			;;
		--algo)
			[ $# -ge 2 ] || die "--algo needs a value"
			ALGO="$2"
			shift 2
			;;
		--expire)
			[ $# -ge 2 ] || die "--expire needs a value"
			EXPIRE="$2"
			shift 2
			;;
		--passphrase-file)
			[ $# -ge 2 ] || die "--passphrase-file needs a value"
			PASS_FILE="$2"
			shift 2
			;;
		--no-passphrase)
			NO_PASS=1
			shift
			;;
		--signing-home)
			[ $# -ge 2 ] || die "--signing-home needs a value"
			SIGNING_HOME="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			POSITIONAL+=("$@")
			break
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

[ "${#POSITIONAL[@]}" -eq 2 ] || {
	usage >&2
	exit 1
}
TARGET=$(realpath -m -- "${POSITIONAL[0]}")
GNUPGHOME_NEW=$(realpath -m -- "${POSITIONAL[1]}")

command -v gpg > /dev/null 2>&1 || die "gpg is not installed"

case "$ALGO" in
	ed25519 | rsa4096) ;;
	*) die "--algo must be ed25519 or rsa4096" ;;
esac
case "$EXPIRE" in
	*[!0-9a-zA-Z-]*) die "invalid --expire value" ;;
esac
case "$UID_TEXT" in
	*$'\n'* | '') die "invalid --uid" ;;
esac

if [ -n "$PASS_FILE" ] && [ "$NO_PASS" -eq 1 ]; then
	die "--passphrase-file and --no-passphrase exclude each other"
fi
if [ -z "$PASS_FILE" ] && [ "$NO_PASS" -eq 0 ]; then
	die "choose --passphrase-file FILE (production) or --no-passphrase (tests only)"
fi
if [ -n "$PASS_FILE" ]; then
	[ -s "$PASS_FILE" ] || die "passphrase file is missing or empty: $PASS_FILE"
	PASS_FILE=$(realpath -- "$PASS_FILE")
	if inside_git_tree "$PASS_FILE"; then
		die "refusing: the passphrase file lies inside a git working tree" 2
	fi
fi

# Never write key material into a git working tree.
for d in "$TARGET" "$GNUPGHOME_NEW" ${SIGNING_HOME:+"$(realpath -m -- "$SIGNING_HOME")"}; do
	if inside_git_tree "$d"; then
		die "refusing: $d lies inside a git working tree. Choose a directory outside of any repository." 2
	fi
done

if [ -e "$GNUPGHOME_NEW" ] && [ -n "$(ls -A "$GNUPGHOME_NEW" 2> /dev/null)" ]; then
	die "refusing: $GNUPGHOME_NEW exists and is not empty (a key may already exist there)" 2
fi
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2> /dev/null)" ]; then
	die "refusing: $TARGET exists and is not empty" 2
fi
if [ -n "$SIGNING_HOME" ]; then
	SIGNING_HOME=$(realpath -m -- "$SIGNING_HOME")
	if [ -e "$SIGNING_HOME" ] && [ -n "$(ls -A "$SIGNING_HOME" 2> /dev/null)" ]; then
		die "refusing: $SIGNING_HOME exists and is not empty" 2
	fi
fi

# gpg-agent needs a unix socket inside the GnuPG home (limit about 107 bytes in total), unless
# /run/user/<uid>/gnupg exists. Fail early with a clear message instead of a gpg-agent error.
for d in "$GNUPGHOME_NEW" ${SIGNING_HOME:+"$SIGNING_HOME"}; do
	if [ "${#d}" -gt 80 ] && [ ! -d "/run/user/$(id -u)/gnupg" ]; then
		die "the GnuPG home path is too long for the gpg-agent socket (${#d} > 80 characters): $d. Use a shorter path."
	fi
done

mkdir -p "$TARGET" "$GNUPGHOME_NEW"
chmod 700 "$TARGET" "$GNUPGHOME_NEW"
export GNUPGHOME="$GNUPGHOME_NEW"

GPG_PASS=()
if [ -n "$PASS_FILE" ]; then
	GPG_PASS=(--pinentry-mode loopback --passphrase-file "$PASS_FILE")
fi

PARAMS=$(mktemp "$GNUPGHOME_NEW/params.XXXXXX")
trap 'rm -f "$PARAMS"' EXIT

{
	echo '%echo generating VylarisSpace repository signing key'
	if [ "$ALGO" = ed25519 ]; then
		echo 'Key-Type: eddsa'
		echo 'Key-Curve: ed25519'
		echo 'Key-Usage: cert'
		echo 'Subkey-Type: eddsa'
		echo 'Subkey-Curve: ed25519'
		echo 'Subkey-Usage: sign'
	else
		echo 'Key-Type: rsa'
		echo 'Key-Length: 4096'
		echo 'Key-Usage: cert'
		echo 'Subkey-Type: rsa'
		echo 'Subkey-Length: 4096'
		echo 'Subkey-Usage: sign'
	fi
	echo "Name-Real: $UID_TEXT"
	echo "Expire-Date: $EXPIRE"
	echo '%no-protection'
	echo '%commit'
	echo '%echo done'
} > "$PARAMS"

# The key is generated without protection first and protected afterwards (see below), because that
# is the only way to give the signing home an unprotected subkey while the primary stays protected.
gpg --homedir "$GNUPGHOME_NEW" --batch --quiet --generate-key "$PARAMS" 2>&1 \
	| grep -v '^gpg: \(done\|generating\)' || true

# Primary and signing subkey fingerprints.
COLONS=$(gpg --homedir "$GNUPGHOME_NEW" --batch --list-secret-keys --with-colons --with-subkey-fingerprints 2> /dev/null)
FPR=$(printf '%s\n' "$COLONS" | awk -F: '$1=="sec"{s=1;next} s==1 && $1=="fpr"{print $10;exit}')
SUBFPR=$(printf '%s\n' "$COLONS" | awk -F: '$1=="ssb"{s=1;next} s==1 && $1=="fpr"{print $10;exit}')
if [ -z "$FPR" ] || [ -z "$SUBFPR" ]; then
	die "key generation failed (no fingerprint found)"
fi
KEYID=${FPR: -16}

# Optional signing home for the unattended repository host: only the signing subkey, no passphrase,
# primary key reduced to a stub ("sec#"). Created before the passphrase is set on the main home.
if [ -n "$SIGNING_HOME" ]; then
	mkdir -p "$SIGNING_HOME"
	chmod 700 "$SIGNING_HOME"
	TMPSUB=$(mktemp "$GNUPGHOME_NEW/subkey.XXXXXX")
	gpg --homedir "$GNUPGHOME_NEW" --batch --yes --quiet --armor --output "$TMPSUB" --export-secret-subkeys "$FPR"
	gpg --homedir "$SIGNING_HOME" --batch --quiet --import "$TMPSUB" > /dev/null 2>&1
	rm -f "$TMPSUB"
	if ! gpg --homedir "$SIGNING_HOME" --batch --list-secret-keys --with-colons 2> /dev/null | grep -q '^sec:'; then
		die "could not create the signing home"
	fi
fi

# Protect the main home with the passphrase (unless --no-passphrase).
if [ -n "$PASS_FILE" ]; then
	gpg --homedir "$GNUPGHOME_NEW" --batch --yes --quiet "${GPG_PASS[@]}" --change-passphrase "$FPR" > /dev/null 2>&1 \
		|| die "could not set the passphrase"
fi

# Revocation certificate (store offline, use it if the primary key is ever compromised).
REV="$TARGET/revocation-certificate-$KEYID.asc"
# (gpg refuses --gen-revoke with --batch, so --no-tty and --command-fd answer the questions:
# really create, reason 0 = no reason given, empty description, confirm.)
printf 'y\n0\n\ny\n' | gpg --homedir "$GNUPGHOME_NEW" --no-tty --yes --quiet "${GPG_PASS[@]}" \
	--command-fd 0 --output "$REV" --gen-revoke "$FPR" > /dev/null 2>&1 || true
[ -s "$REV" ] || die "could not create the revocation certificate"

# Public key: armored and dearmored (binary keyring usable as apt signed-by file).
gpg --homedir "$GNUPGHOME_NEW" --batch --armor --export "$FPR" > "$TARGET/pubkey.asc"
gpg --homedir "$GNUPGHOME_NEW" --batch --export "$FPR" > "$TARGET/vylarisspace-keyring.gpg"
if [ ! -s "$TARGET/pubkey.asc" ] || [ ! -s "$TARGET/vylarisspace-keyring.gpg" ]; then
	die "public key export failed"
fi
chmod 644 "$TARGET/pubkey.asc" "$TARGET/vylarisspace-keyring.gpg"

CHECK_FPR=$(gpg --batch --show-keys --with-colons "$TARGET/vylarisspace-keyring.gpg" \
	| awk -F: '$1=="fpr"{print $10;exit}')
[ "$CHECK_FPR" = "$FPR" ] || die "exported keyring does not match the generated key"

# Secret exports. Mode 600. These files are the actual secrets.
gpg --homedir "$GNUPGHOME_NEW" --batch --yes --quiet "${GPG_PASS[@]}" --armor \
	--output "$TARGET/secret-primary-and-subkey-OFFLINE-BACKUP-$KEYID.asc" --export-secret-keys "$FPR"
gpg --homedir "$GNUPGHOME_NEW" --batch --yes --quiet "${GPG_PASS[@]}" --armor \
	--output "$TARGET/secret-signing-subkey-only-$KEYID.asc" --export-secret-subkeys "$FPR"
chmod 600 "$TARGET"/secret-*.asc "$REV"

cat << EOT

Signing key created.
  Primary key fingerprint : $FPR
  Key id (long)           : $KEYID
  Signing subkey          : $SUBFPR
  Algorithm / expiry      : $ALGO / $EXPIRE (check with: gpg --homedir '$GNUPGHOME_NEW' -K)
  GnuPG home              : $GNUPGHOME_NEW
  Output directory        : $TARGET

Files in the output directory:
  pubkey.asc                      public key, armored (publish this)
  vylarisspace-keyring.gpg        public key, binary (this is the apt signed-by file)
  revocation-certificate-$KEYID.asc
                                  keep offline, publish only if the key is compromised
  secret-primary-and-subkey-OFFLINE-BACKUP-$KEYID.asc
                                  full secret key (passphrase protected unless --no-passphrase);
                                  offline media only
  secret-signing-subkey-only-$KEYID.asc
                                  only the signing subkey; this goes to the signing host

Next steps (details in src/vylaris/README.md):
  1. Copy the whole output directory to offline media (two copies, different places), then delete
     the secret-primary file and the primary key from the machine that runs reprepro.
  2. Export for the repository host:  export VYLARIS_SIGN_KEY=$FPR
  3. On the signing host the primary key must be a stub:  gpg --homedir <signing-home> -K
     (the line of the primary key shows "sec#", the subkey "ssb")
  4. Calendar reminder: the key expires in $EXPIRE. Servers reject a repository signed by an
     expired key, so publish the renewed public key well before that date.
  5. Never commit anything from this directory. Never reuse install/deb/deb_signing.key.
EOT
if [ -n "$SIGNING_HOME" ]; then
	echo "  Signing GnuPG home for the repository host: $SIGNING_HOME"
	echo "  (signing subkey only, WITHOUT passphrase; protect it with file permissions and disk encryption)"
fi
if [ "$NO_PASS" -eq 1 ]; then
	echo
	echo "WARNING: --no-passphrase was used. The secret keys are NOT protected. Do not use this for production."
fi
