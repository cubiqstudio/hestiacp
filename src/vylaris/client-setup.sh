#!/usr/bin/env bash
#
# client-setup.sh - make a SERVER trust the VylarisSpace apt repository.
#
# Self-contained and idempotent: run it again at any time (for example to refresh the key or
# change credentials). It does not run apt unless --update is given. The installers use the same
# steps (reference implementation); the part between the "shared" markers is identical in all three.
#
# What it writes (paths are relative to --root, default /):
#   /usr/share/keyrings/vylarisspace-keyring.gpg   the repository key (dearmored; no apt-key, no trusted.gpg.d)
#   /etc/apt/sources.list.d/vylarisspace.list      deb [arch=.. signed-by=..] <repo> <codename> main
#   /etc/apt/preferences.d/vylarisspace            pins: package hestia ONLY from the own repository
#   /etc/apt/auth.conf.d/vylarisspace.conf         only with credentials, mode 0600
#
# Why the pins matter: the fork carries the same package name (hestia) and base version as the
# upstream project. Without the pins a later upstream release (1.10.6 and up) would win the version
# comparison and replace the fork, including its interface, within one apt upgrade.
# apt uses the FIRST stanza that matches, so the pin file has this order:
#   1. Upstream      : "origin apt.hestiacp.com" and "release o=apt.hestiacp.com", priority -1.
#   2. Own repository: "origin <host of the repository>", priority 1001. The pin is bound to the HOST,
#                      not to the Origin field of the Release file: any repository can CLAIM
#                      "Origin: VylarisSpace". Moving the repository to another host therefore means
#                      running this script again (it rewrites the pin). A file:// repository (tests
#                      only) has no host and is matched with an empty origin.
#   3. Everything else: "origin *", priority -1 for package hestia (a third repository that carries a
#                      package of that name never wins and cannot be installed by accident).
#   Priority 1001 (above 1000) also lets apt move a server back to the own repository's version if
#   it is lower than the installed one (rollback via repo-publish.sh --rollback).
#
# Trust in the key: a key that is DOWNLOADED (the default is <repo>/pubkey.gpg) is only accepted with
# its fingerprint (--key-fingerprint), because a key from the same server proves nothing about who owns
# it. Get the fingerprint on the owner's machine from the public key, never from the server:
#   gpg --show-keys --with-fingerprint pubkey.asc
# The fingerprint of the PRIMARY key is compared (case and spaces are ignored); the key file must contain
# exactly one primary key (its signing subkeys are trusted with it). A key given as a local file may
# omit the fingerprint, the script then prints it for you to compare.
#
# Usage:
#   VYLARIS_REPO_URL=https://<host>/<path> VYLARIS_REPO_KEY_FPR=<fingerprint> client-setup.sh [options]
#
# Options (environment variable in brackets; there is no default host):
#   --repo URL           [VYLARIS_REPO_URL]  base URL of the repository: https://<host>[:port]/<path>
#                                            (no user info, IPv6 literal, query or fragment)
#   --key URL|FILE       [VYLARIS_REPO_KEY]  public key; default: <repo>/pubkey.gpg. Armored or binary.
#   --key-fingerprint F  [VYLARIS_REPO_KEY_FPR]  refuse the key unless its primary fingerprint is F
#                                            (required for a key that is downloaded)
#   --auth-file FILE                         file whose first line is user:password
#                        [VYLARIS_REPO_AUTH]  user:password (environment is preferred over a
#                                             command line option, which would show up in ps)
#   --allow-insecure-http [VYLARIS_ALLOW_INSECURE_HTTP=yes]
#                        accept an http:// repository or key URL (tests on trusted networks only;
#                        credentials are never sent over http)
#   --suite NAME         suite/codename, default VERSION_CODENAME from <root>/etc/os-release
#                        (use <codename>-staging for the staging suite)
#   --arch ARCH          default: dpkg --print-architecture
#   --root DIR           operate on DIR instead of / (chroot or test directory). apt is not run.
#   --keyring-path PATH  path of the keyring as apt sees it (default /usr/share/keyrings/vylarisspace-keyring.gpg);
#                        the file is written to <root>/PATH
#   --upstream-host H    host of the upstream repository to pin away (default apt.hestiacp.com)
#   --update             run apt-get update restricted to the own source list (not with --root)
#   -h, --help
#
# Exit codes: 0 ok, 1 usage error, 2 refused (bad URL, key, fingerprint), 3 environment (missing tool, not root).

set -euo pipefail

# Repository credentials must never reach a trace: tracing (bash -x, set -x) is switched off for the
# whole run when credentials may be present (environment or --auth-file).
case $- in
	*x*)
		set +x
		vyl_trace='on'
		[ -z "${VYLARIS_REPO_AUTH:-}" ] || vyl_trace='off'
		for vyl_a in "$@"; do
			case "$vyl_a" in
				--auth-file | --auth-file=*) vyl_trace='off' ;;
			esac
		done
		if [ "$vyl_trace" = 'on' ]; then
			set -x
		else
			echo "Note: tracing (set -x) is switched off, repository credentials are in use." >&2
		fi
		unset vyl_a vyl_trace
		;;
esac

PROG=$(basename "$0")
vylaris_repo_url="${VYLARIS_REPO_URL:-}"
vylaris_repo_key="${VYLARIS_REPO_KEY:-}"
vylaris_repo_key_fpr="${VYLARIS_REPO_KEY_FPR:-}"
vylaris_repo_auth="${VYLARIS_REPO_AUTH:-}"
# The credentials are read once and must not stay in the environment of the child processes
unset VYLARIS_REPO_AUTH
vylaris_allow_http="${VYLARIS_ALLOW_INSECURE_HTTP:-no}"
AUTH_FILE=''
SUITE=''
ARCH=''
ROOT=''
KEYRING_PATH='/usr/share/keyrings/vylarisspace-keyring.gpg'
vyl_upstream_host='apt.hestiacp.com'
vyl_scheme=''
vyl_host=''
vyl_port=''
vyl_path=''
vyl_machine=''
vyl_key_kind=''
vyl_key_fpr=''
vyl_auth_user=''
vyl_auth_pass=''
DO_UPDATE=0
CHANGED=0

die() {
	echo "$PROG: $1" >&2
	exit "${2:-1}"
}

# Hook used by the shared part: a refusal
vyl_fail() {
	die "$1" 2
}

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)
			[ $# -ge 2 ] || die "--repo needs a value"
			vylaris_repo_url="$2"
			shift 2
			;;
		--key)
			[ $# -ge 2 ] || die "--key needs a value"
			vylaris_repo_key="$2"
			shift 2
			;;
		--key-fingerprint)
			[ $# -ge 2 ] || die "--key-fingerprint needs a value"
			vylaris_repo_key_fpr="$2"
			shift 2
			;;
		--auth-file)
			[ $# -ge 2 ] || die "--auth-file needs a value"
			AUTH_FILE="$2"
			shift 2
			;;
		--allow-insecure-http)
			vylaris_allow_http='yes'
			shift
			;;
		--suite)
			[ $# -ge 2 ] || die "--suite needs a value"
			SUITE="$2"
			shift 2
			;;
		--arch)
			[ $# -ge 2 ] || die "--arch needs a value"
			ARCH="$2"
			shift 2
			;;
		--root)
			[ $# -ge 2 ] || die "--root needs a value"
			ROOT="$2"
			shift 2
			;;
		--keyring-path)
			[ $# -ge 2 ] || die "--keyring-path needs a value"
			KEYRING_PATH="$2"
			shift 2
			;;
		--upstream-host)
			[ $# -ge 2 ] || die "--upstream-host needs a value"
			vyl_upstream_host="$2"
			shift 2
			;;
		--update)
			DO_UPDATE=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

# ---- shared with src/vylaris/client-setup.sh: keep both copies identical (checked by a diff) ----
# Needs a function vyl_fail "message" that stops the run, and the variables vylaris_repo_url,
# vylaris_repo_key, vylaris_repo_key_fpr, vylaris_repo_auth, vylaris_allow_http, vyl_upstream_host.
# Sets vyl_scheme, vyl_host, vyl_port, vyl_path, vyl_machine, vyl_auth_user, vyl_auth_pass,
# vyl_key_kind (net|local) and (after vyl_load_key) vyl_key_fpr.

# Strict parser for repository URLs, no eval. On success prints scheme|host|port|path|url with the
# host in lower case without a trailing dot, the effective port (empty for file://), the path without
# trailing slashes and url as the normalized form. On failure prints the reason and returns 1.
# Accepted: https:// (http:// only with an explicit opt-in, file:// for tests) with a DNS name or an
# IPv4 address, an optional :port and an optional /path. Refused: user info (user@host), IPv6
# literals, query, fragment, percent escapes, empty, . and .. path segments, every other scheme.
vyl_parse_url() {
	local url="$1" scheme rest hostport host port path host_re
	host_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
	case "$url" in
		*://*) ;;
		*)
			echo "it is not a URL, expected https://<host>/<path>"
			return 1
			;;
	esac
	scheme="$(printf '%s' "${url%%://*}" | tr '[:upper:]' '[:lower:]')"
	rest="${url#*://}"
	case "$scheme" in
		https | http | file) ;;
		*)
			echo "the scheme is not supported, use https:// (http:// needs an explicit opt-in, file:// is for tests)"
			return 1
			;;
	esac
	if ! [[ "$rest" =~ ^[A-Za-z0-9._:/~+-]*$ ]]; then
		echo "it contains characters that are not allowed (user name or password, IPv6 address, query, fragment, space, %, ...)"
		return 1
	fi
	host=''
	port=''
	if [ "$scheme" = 'file' ]; then
		case "$rest" in
			/*) ;;
			*)
				echo "a file:// URL needs an absolute path (file:///path)"
				return 1
				;;
		esac
		path="$rest"
	else
		hostport="${rest%%/*}"
		path=''
		case "$rest" in
			*/*) path="/${rest#*/}" ;;
		esac
		host="${hostport%%:*}"
		if [[ "$hostport" == *:* ]]; then
			port="${hostport#*:}"
			if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
				echo "the port is not valid"
				return 1
			fi
			port=$((10#$port))
		fi
		host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
		host="${host%.}"
		if [ "${#host}" -gt 253 ] || ! [[ "$host" =~ $host_re ]]; then
			echo "the host name is not valid"
			return 1
		fi
		if [ -z "$port" ]; then
			if [ "$scheme" = 'https' ]; then
				port=443
			else
				port=80
			fi
		fi
	fi
	while [ "${path%/}" != "$path" ]; do
		path="${path%/}"
	done
	case "$path/" in
		*//* | */./* | */../*)
			echo "the path must not contain empty, . or .. segments"
			return 1
			;;
	esac
	if [ "$scheme" = 'file' ]; then
		if [ -z "$path" ]; then
			echo "a file:// URL needs a directory"
			return 1
		fi
		url="file://$path"
	else
		url="$scheme://$host"
		if { [ "$scheme" = 'https' ] && [ "$port" != 443 ]; } || { [ "$scheme" = 'http' ] && [ "$port" != 80 ]; }; then
			url="$url:$port"
		fi
		url="$url$path"
	fi
	printf '%s|%s|%s|%s|%s\n' "$scheme" "$host" "$port" "$path" "$url"
}

# Success only when the URL is https:// and has exactly the host and port of the repository
# (a prefix match is not enough: https://repo.example.evil.test is another host).
vyl_same_https_endpoint() {
	local parsed s h p
	parsed="$(vyl_parse_url "$1")" || return 1
	IFS='|' read -r s h p _ _ <<< "$parsed"
	[ "$s" = 'https' ] && [ "$vyl_scheme" = 'https' ] && [ "$h" = "$vyl_host" ] && [ "$p" = "$vyl_port" ]
}

# Download a URL. The credentials go (through a curl config on stdin, not visible in ps) only to the
# exact host and port of the repository over https. A redirect may not leave https.
vyl_curl() {
	local parsed url out="$2" proto='=https'
	parsed="$(vyl_parse_url "$1")" || return 1
	url="${parsed##*|}"
	if [ "${vylaris_allow_http:-no}" = 'yes' ]; then
		proto='=https,http'
	fi
	if [ -n "${vyl_auth_user:-}" ] && vyl_same_https_endpoint "$url"; then
		printf 'user = "%s:%s"\n' "$vyl_auth_user" "$vyl_auth_pass" \
			| curl -fsSL --proto "$proto" --proto-redir "$proto" --max-time 60 --config - -o "$out" "$url"
	else
		curl -fsSL --proto "$proto" --proto-redir "$proto" --max-time 60 -o "$out" "$url"
	fi
}

# All checks of the repository options that need no network and no tool except bash.
# Normalizes the variables, reads the credentials once and removes them from the environment.
vyl_validate_options() {
	local parsed reason key_lc kscheme
	if ! parsed="$(vyl_parse_url "$vylaris_repo_url")"; then
		reason="$parsed"
		vyl_fail "Invalid repository URL: $(printf '%s' "$vylaris_repo_url" | sed 's#://[^/@]*@#://***@#')
Reason: $reason.
Expected https://<host>[:port]/<path>"
	fi
	IFS='|' read -r vyl_scheme vyl_host vyl_port vyl_path vylaris_repo_url <<< "$parsed"
	if [ "$vyl_scheme" = 'http' ]; then
		if [ "${vylaris_allow_http:-no}" != 'yes' ]; then
			vyl_fail "Refusing the plain http:// repository $vylaris_repo_url
Nothing protects the connection: anybody on the way could change what is downloaded or read the login.
Use an https:// URL. Only for a test on a network you trust, you can accept the risk with
--allow-insecure-http (or VYLARIS_ALLOW_INSECURE_HTTP=yes). The packages stay signed, but nothing
else is protected and credentials are never sent over http."
		fi
		echo "WARNING: the repository is used over plain http:// (--allow-insecure-http). For tests on trusted networks only." >&2
	fi
	if [ -n "$vyl_host" ] && [ "$vyl_host" = "$vyl_upstream_host" ]; then
		vyl_fail "The repository host $vyl_host is the upstream HestiaCP host, which is pinned away for package hestia. Use the host of the VylarisSpace repository."
	fi
	vyl_machine="$vyl_host"
	if { [ "$vyl_scheme" = 'https' ] && [ "$vyl_port" != 443 ]; } || { [ "$vyl_scheme" = 'http' ] && [ "$vyl_port" != 80 ]; }; then
		vyl_machine="$vyl_host:$vyl_port"
	fi
	vyl_machine="$vyl_machine$vyl_path"

	# Key source: a URL (network) or a local file
	if [ -z "$vylaris_repo_key" ]; then
		vylaris_repo_key="$vylaris_repo_url/pubkey.gpg"
	fi
	key_lc="$(printf '%s' "$vylaris_repo_key" | tr '[:upper:]' '[:lower:]')"
	case "$key_lc" in
		http://* | https://*)
			if ! parsed="$(vyl_parse_url "$vylaris_repo_key")"; then
				reason="$parsed"
				vyl_fail "Invalid repository key URL: $vylaris_repo_key
Reason: $reason."
			fi
			IFS='|' read -r kscheme _ _ _ vylaris_repo_key <<< "$parsed"
			if [ "$kscheme" = 'http' ] && [ "${vylaris_allow_http:-no}" != 'yes' ]; then
				vyl_fail "Refusing to download the repository key over plain http://: $vylaris_repo_key
Use an https:// URL, or --allow-insecure-http (tests on trusted networks only)."
			fi
			vyl_key_kind='net'
			;;
		file://*)
			vylaris_repo_key="${vylaris_repo_key:7}"
			vyl_key_kind='local'
			;;
		*)
			vyl_key_kind='local'
			;;
	esac
	if [ "$vyl_key_kind" = 'local' ] && { [ ! -f "$vylaris_repo_key" ] || [ ! -r "$vylaris_repo_key" ]; }; then
		vyl_fail "Cannot read the repository key file: $vylaris_repo_key"
	fi

	# Fingerprint of the PRIMARY key (the first fpr record after pub in gpg --with-colons)
	if [ -n "$vylaris_repo_key_fpr" ]; then
		vylaris_repo_key_fpr="$(printf '%s' "$vylaris_repo_key_fpr" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
		if ! [[ "$vylaris_repo_key_fpr" =~ ^[0-9A-F]{40}$ ]]; then
			vyl_fail "The key fingerprint must be 40 hexadecimal digits (spaces are ignored, upper or lower case)."
		fi
	fi
	if [ "$vyl_key_kind" = 'net' ] && [ -z "$vylaris_repo_key_fpr" ]; then
		vyl_fail "The repository key would be downloaded from $vylaris_repo_key
A key that comes over the network proves nothing about who owns it, so its fingerprint is required.
Get it on the owner's machine from the public key (not from the server):
  gpg --show-keys --with-fingerprint pubkey.asc
and pass the 40 digit fingerprint of the primary key with --vylaris-key-fingerprint (client-setup.sh:
--key-fingerprint) or VYLARIS_REPO_KEY_FPR. Alternatively give the key as a local file
(--vylaris-key <file>, client-setup.sh: --key <file>) that you received from the owner on a trusted channel."
	fi

	# Credentials: read once, then removed from the environment and from the option variable
	vyl_auth_user=''
	vyl_auth_pass=''
	if [ -n "$vylaris_repo_auth" ]; then
		if [[ "$vylaris_repo_auth" != *:* ]]; then
			vyl_fail "Credentials must have the form user:password."
		fi
		vyl_auth_user="${vylaris_repo_auth%%:*}"
		vyl_auth_pass="${vylaris_repo_auth#*:}"
		if [ -z "$vyl_auth_user" ] || [ -z "$vyl_auth_pass" ] || [[ "$vyl_auth_user$vyl_auth_pass" =~ [[:space:]\"\'\\] ]]; then
			vyl_fail "User and password must not be empty or contain spaces, quotes or backslashes (use a generated token)."
		fi
		if [ "$vyl_scheme" = 'http' ]; then
			vyl_fail "Refusing to send credentials over plain http. Use an https:// repository URL."
		fi
	fi
	vylaris_repo_auth=''
	unset VYLARIS_REPO_AUTH
}

# Fetch (network) or copy (local file) the key and check it. Leaves $1/key.gpg, a binary keyring with
# exactly one public key, and sets vyl_key_fpr (fingerprint of the primary key). Refuses on any doubt:
# no key, secret key material, more than one primary key (everything in the file would be trusted by
# apt), or a fingerprint that differs from the one given.
vyl_load_key() {
	local dir="$1" colons n
	if [ "$vyl_key_kind" = 'net' ]; then
		vyl_curl "$vylaris_repo_key" "$dir/key.raw" || vyl_fail "Cannot download the repository key from $vylaris_repo_key"
	else
		cp -- "$vylaris_repo_key" "$dir/key.raw" || vyl_fail "Cannot read the repository key file $vylaris_repo_key"
	fi
	[ -s "$dir/key.raw" ] || vyl_fail "The repository key file is empty."
	if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$dir/key.raw"; then
		gpg --batch --dearmor < "$dir/key.raw" > "$dir/key.gpg" 2> /dev/null || vyl_fail "The repository key is not valid armor."
	else
		cp -- "$dir/key.raw" "$dir/key.gpg"
	fi
	colons="$(gpg --batch --show-keys --with-colons "$dir/key.gpg" 2> /dev/null || true)"
	if printf '%s\n' "$colons" | grep -q '^\(sec\|ssb\):'; then
		vyl_fail "The key file contains SECRET key material. Refusing."
	fi
	n="$(printf '%s\n' "$colons" | grep -c '^pub:' || true)"
	if [ "$n" -lt 1 ]; then
		vyl_fail "The repository key file contains no public key."
	fi
	if [ "$n" -gt 1 ]; then
		vyl_fail "The repository key file contains $n primary keys, exactly one is expected (apt would trust all of them)."
	fi
	# Validity field of the primary key: e = expired, r = revoked, d = disabled, i = invalid, n = not valid
	case "$(printf '%s\n' "$colons" | awk -F: '$1=="pub"{print $2;exit}')" in
		e | r | d | i | n) vyl_fail "The repository key is expired, revoked or not valid. Ask the repository owner for a current key." ;;
	esac
	vyl_key_fpr="$(printf '%s\n' "$colons" | awk -F: '$1=="pub"{p=1;next} p==1&&$1=="fpr"{print $10;exit}')"
	[ -n "$vyl_key_fpr" ] || vyl_fail "The repository key file contains no public key."
	if [ -n "$vylaris_repo_key_fpr" ] && [ "$vyl_key_fpr" != "$vylaris_repo_key_fpr" ]; then
		vyl_fail "Key fingerprint mismatch: expected $vylaris_repo_key_fpr, the key contains $vyl_key_fpr"
	fi
}

# Print the apt preferences for package hestia. Arguments: the upstream host, and (when a repository
# is configured) the scheme and host of the own repository.
# apt uses the FIRST stanza that matches a package version, so the order is what matters:
#   1. the upstream repository, by host and by the Origin it claims  -> -1 (never)
#   2. the own repository, by host                                   -> 1001
#   3. every other remote source                                     -> -1 (never)
# The own stanza is bound to the host, not to the Origin field of the Release file: a repository
# that only CLAIMS Origin: VylarisSpace must not win. A file:// repository (tests only) has no host,
# apt matches it with an empty origin. "origin *" does not match the installed package (dpkg status).
vyl_pin_content() {
	local upstream="$1" own_scheme="${2:-}" own_host="${3:-}"
	echo "# Managed by VylarisSpace (installer or client-setup.sh). Do not edit or remove: without these pins"
	echo "# an upstream release of the \"hestia\" package would replace VylarisSpace (same package name)."
	echo "# apt uses the FIRST matching stanza, keep the order."
	echo
	echo "# 1. Never from the upstream repository (its host name, or the Origin it claims)."
	echo "Package: hestia"
	echo "Pin: origin $upstream"
	echo "Pin-Priority: -1"
	echo
	echo "Package: hestia"
	echo "Pin: release o=$upstream"
	echo "Pin-Priority: -1"
	if [ -n "$own_scheme" ]; then
		echo
		if [ "$own_scheme" = 'file' ]; then
			echo "# 2. From the VylarisSpace repository. A file:// repository has no host (tests only): any local source."
			echo "Package: hestia"
			echo "Pin: origin \"\""
		else
			echo "# 2. Only from the VylarisSpace repository host."
			echo "Package: hestia"
			echo "Pin: origin $own_host"
		fi
		echo "Pin-Priority: 1001"
	fi
	echo
	echo "# 3. From no other remote source."
	echo "Package: hestia"
	echo "Pin: origin *"
	echo "Pin-Priority: -1"
}
# ---- end of the part shared with src/vylaris/client-setup.sh -------------------------------------

# --- validation ------------------------------------------------------------------------------------
if [ -z "$vylaris_repo_url" ]; then
	die "no repository configured. Set VYLARIS_REPO_URL or pass --repo https://<host>/<path>. There is deliberately no default host."
fi
if ! [[ "$vyl_upstream_host" =~ ^[A-Za-z0-9.-]+$ ]]; then
	die "invalid --upstream-host" 2
fi
vyl_upstream_host=$(printf '%s' "$vyl_upstream_host" | tr '[:upper:]' '[:lower:]')
vyl_upstream_host=${vyl_upstream_host%.}
if ! [[ "$KEYRING_PATH" =~ ^/[A-Za-z0-9._/+-]+$ ]]; then
	die "invalid --keyring-path" 2
fi

if [ -n "$AUTH_FILE" ]; then
	[ -r "$AUTH_FILE" ] || die "cannot read --auth-file $AUTH_FILE" 2
	IFS= read -r vylaris_repo_auth < "$AUTH_FILE" || true
fi
had_auth=0
if [ -n "$vylaris_repo_auth" ]; then
	had_auth=1
fi
# URL, http opt-in, key source, fingerprint format and credentials format; reads the credentials
# once into vyl_auth_user / vyl_auth_pass
vyl_validate_options
if [ "$had_auth" -eq 1 ] && [ "$vyl_scheme" = file ]; then
	echo "$PROG: note: credentials are written but not needed for a file:// repository" >&2
fi

ROOT=${ROOT%/}
R="$ROOT"
if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
	die "must run as root (or use --root DIR)" 3
fi
for tool in gpg awk cmp install; do
	command -v "$tool" > /dev/null 2>&1 || die "$tool is not installed (apt-get install gnupg)" 3
done
if [ "$vyl_key_kind" = net ]; then
	command -v curl > /dev/null 2>&1 || die "curl is not installed" 3
fi

if [ -z "$ARCH" ]; then
	if command -v dpkg > /dev/null 2>&1; then
		ARCH=$(dpkg --print-architecture)
	else
		die "cannot detect the architecture; pass --arch" 3
	fi
fi
if ! [[ "$ARCH" =~ ^[a-z0-9]+$ ]]; then
	die "invalid architecture" 2
fi
if [ -z "$SUITE" ]; then
	OSREL="$R/etc/os-release"
	[ -r "$OSREL" ] || die "cannot read $OSREL; pass --suite" 3
	SUITE=$(sed -n 's/^VERSION_CODENAME=//p' "$OSREL" | head -n1 | tr -d '"'"'"' ')
	[ -n "$SUITE" ] || die "no VERSION_CODENAME in $OSREL; pass --suite" 3
fi
if ! [[ "$SUITE" =~ ^[a-z0-9-]+$ ]]; then
	die "invalid suite name: $SUITE" 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 022

# write_file <dest> <mode> <source-file>: install only when the content or mode differs.
write_file() {
	local dest="$1" mode="$2" src="$3" cur
	mkdir -p "$(dirname "$dest")"
	if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
		cur=$(stat -c %a "$dest")
		if [ "$cur" != "$mode" ]; then
			chmod "$mode" "$dest"
			echo "  mode fixed  : $dest ($cur -> $mode)"
			CHANGED=1
		else
			echo "  unchanged   : $dest"
		fi
		return 0
	fi
	install -m "$mode" "$src" "$dest"
	echo "  written     : $dest"
	CHANGED=1
}

# --- 1. key ----------------------------------------------------------------------------------------
echo "VylarisSpace repository setup ($SUITE, $ARCH${ROOT:+, root=$ROOT})"
vyl_load_key "$TMP"
write_file "$R$KEYRING_PATH" 644 "$TMP/key.gpg"
if [ -n "$vylaris_repo_key_fpr" ]; then
	echo "  key fingerprint: $vyl_key_fpr (matches the given fingerprint)"
else
	echo "  key fingerprint: $vyl_key_fpr"
	echo "  NOT verified: no --key-fingerprint was given for this local key file. Compare the fingerprint above"
	echo "  with the one the repository owner published (gpg --show-keys --with-fingerprint pubkey.asc)."
fi

# --- 2. source list ----------------------------------------------------------------------------
printf '# Managed by VylarisSpace client-setup.sh. Re-run the script instead of editing.\ndeb [arch=%s signed-by=%s] %s %s main\n' \
	"$ARCH" "$KEYRING_PATH" "$vylaris_repo_url" "$SUITE" > "$TMP/list"
write_file "$R/etc/apt/sources.list.d/vylarisspace.list" 644 "$TMP/list"

# --- 3. pins -----------------------------------------------------------------------------------
vyl_pin_content "$vyl_upstream_host" "$vyl_scheme" "$vyl_host" > "$TMP/pref"
write_file "$R/etc/apt/preferences.d/vylarisspace" 644 "$TMP/pref"

# --- 4. credentials -----------------------------------------------------------------------------
AUTH_DEST="$R/etc/apt/auth.conf.d/vylarisspace.conf"
if [ -n "$vyl_auth_user" ] && [ "$vyl_scheme" != file ]; then
	umask 077
	printf '# Managed by VylarisSpace client-setup.sh\nmachine %s login %s password %s\n' \
		"$vyl_machine" "$vyl_auth_user" "$vyl_auth_pass" > "$TMP/auth"
	mkdir -p "$(dirname "$AUTH_DEST")"
	write_file "$AUTH_DEST" 600 "$TMP/auth"
	umask 022
	# apt only reads the file as root; keep it root-owned when we are root.
	if [ "$(id -u)" -eq 0 ]; then
		chown root:root "$AUTH_DEST"
	fi
elif [ -f "$AUTH_DEST" ]; then
	echo "  kept        : $AUTH_DEST (no credentials given this time)"
else
	echo "  skipped     : no credentials (public repository)"
fi
# The credentials are in the file now (or not needed): drop them from this shell
vyl_auth_user=''
vyl_auth_pass=''

# --- 5. optional update (own list only) --------------------------------------------------------
if [ "$DO_UPDATE" -eq 1 ]; then
	if [ -n "$ROOT" ]; then
		die "--update cannot be combined with --root" 1
	fi
	apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/vylarisspace.list \
		-o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
fi

if [ "$CHANGED" -eq 0 ]; then
	echo "Nothing to change - already configured."
fi
echo "Check with: apt-cache policy hestia   (candidate must come from $vylaris_repo_url, not from $vyl_upstream_host)"
