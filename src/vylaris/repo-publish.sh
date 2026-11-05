#!/usr/bin/env bash
#
# repo-publish.sh - add hestia .deb files to the VylarisSpace apt repository, verify the signed
# result, keep the last N builds for rollbacks and store the matching source archive.
#
# Usage:
#   repo-publish.sh [options] <repo-dir> <hestia_*.deb>...
#   repo-publish.sh [options] --rollback <repo-dir> <suite> <version>
#   repo-publish.sh [options] --promote  <repo-dir> <suite> [<version>]
#
# Suite selection (from the version suffix that src/hst_autocompile.sh adds, "<ver>-<pkgrev>+<distro>"):
#   +debian12 -> bookworm   +debian13 -> trixie   +ubuntu22.04 -> jammy   +ubuntu24.04 -> noble
# A version without a known suffix needs --suite. A "~tag" after the suffix (CI builds) is accepted.
#
# Options:
#   --suite NAME            publish into this suite (for example noble-staging) instead of the
#                           suite derived from the version.
#   --keep N                keep the last N builds per suite and architecture in <repo-dir>/archive
#                           (default 3, or VYLARIS_KEEP_VERSIONS).
#   --source-repo DIR       git checkout the package was built from (default: the checkout that
#                           contains this script). The archive is made with "git archive".
#   --source-commit REV     commit to archive (default HEAD). The short hash is part of the file name.
#   --allow-dirty           archive even though the working tree has uncommitted changes
#                           (the archive then does not contain them!).
#   --no-source             do not store a source archive. Only for tests: distributing binaries
#                           without the matching source violates the GPL.
#   --allow-other-packages  accept packages other than "hestia" (stage 2: hestia-nginx, ...).
#   -h, --help
#
# Modes:
#   --rollback   make <version> from the archive the version served in <suite>. The repository
#                index holds ONE version per suite and architecture (reprepro limitation), so a
#                rollback replaces the current version in the index with the archived one.
#                Servers with the client-setup.sh pins then downgrade at their next upgrade.
#   --promote    publish the archived build of <suite>-staging (newest or <version>) into <suite>.
#
# Environment:
#   GNUPGHOME            GnuPG home with the signing key (the same as for repo-init.sh).
#   VYLARIS_KEEP_VERSIONS  default for --keep.
#
# Exit codes: 0 ok, 1 usage or environment error, 2 refused (unsafe, not newer, wrong package),
#             3 signature or index verification failed.

set -euo pipefail
umask 022

SOURCE_FILE=''
SOURCE_COMMIT=''
PROG=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
KEEP="${VYLARIS_KEEP_VERSIONS:-3}"
SUITE_OVERRIDE=''
SRC_REPO=''
SRC_COMMIT='HEAD'
ALLOW_DIRTY=0
NO_SOURCE=0
ALLOW_OTHER=0
MODE='publish'
SUPPORTED_ARCHS='amd64 arm64'

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

# Print the versions given on stdin (one per line), newest first, using dpkg's ordering.
sort_versions_desc() {
	local arr=() v t i j n
	while IFS= read -r v; do
		[ -n "$v" ] && arr+=("$v")
	done
	n=${#arr[@]}
	for ((i = 0; i < n; i++)); do
		for ((j = i + 1; j < n; j++)); do
			if dpkg --compare-versions "${arr[j]}" gt "${arr[i]}"; then
				t=${arr[i]}
				arr[i]=${arr[j]}
				arr[j]=$t
			fi
		done
	done
	if [ "$n" -gt 0 ]; then
		printf '%s\n' "${arr[@]}"
	fi
}

suite_from_version() {
	local ver="$1" m
	if [[ "$ver" =~ \+(debian|ubuntu)([0-9]+(\.[0-9]+)?)(~[A-Za-z0-9.+~]*)?$ ]]; then
		m="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
		case "$m" in
			debian12) echo bookworm ;;
			debian13) echo trixie ;;
			ubuntu22.04) echo jammy ;;
			ubuntu24.04) echo noble ;;
			*) return 1 ;;
		esac
		return 0
	fi
	return 1
}

POSITIONAL=()
while [ $# -gt 0 ]; do
	case "$1" in
		--suite)
			[ $# -ge 2 ] || die "--suite needs a value"
			SUITE_OVERRIDE="$2"
			shift 2
			;;
		--keep)
			[ $# -ge 2 ] || die "--keep needs a value"
			KEEP="$2"
			shift 2
			;;
		--source-repo)
			[ $# -ge 2 ] || die "--source-repo needs a value"
			SRC_REPO="$2"
			shift 2
			;;
		--source-commit)
			[ $# -ge 2 ] || die "--source-commit needs a value"
			SRC_COMMIT="$2"
			shift 2
			;;
		--allow-dirty)
			ALLOW_DIRTY=1
			shift
			;;
		--no-source)
			NO_SOURCE=1
			shift
			;;
		--allow-other-packages)
			ALLOW_OTHER=1
			shift
			;;
		--rollback)
			MODE='rollback'
			shift
			;;
		--promote)
			MODE='promote'
			shift
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

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
	die "--keep must be a number >= 1"
fi
[ "${#POSITIONAL[@]}" -ge 1 ] || {
	usage >&2
	exit 1
}
for tool in reprepro gpg gpgv dpkg-deb dpkg sha256sum flock; do
	command -v "$tool" > /dev/null 2>&1 || die "$tool is not installed"
done

REPO=$(realpath -m -- "${POSITIONAL[0]}")
[ -f "$REPO/conf/distributions" ] || die "$REPO is not an initialised repository (run repo-init.sh first)" 2
PUBLIC="$REPO/public"
ARCHIVE="$REPO/archive"
KEYRING="$PUBLIC/pubkey.gpg"
[ -s "$KEYRING" ] || die "missing $KEYRING" 2
if inside_git_tree "$REPO"; then
	die "refusing: $REPO lies inside a git working tree" 2
fi

# Serialise all writers.
exec 9> "$REPO/.publish.lock"
flock -n 9 || die "another publish is running on $REPO" 2

# Fingerprint of the primary key that must have signed the indices.
PRIMARY_FPR=$(gpg --batch --show-keys --with-colons "$KEYRING" 2> /dev/null | awk -F: '$1=="fpr"{print $10;exit}')
[ -n "$PRIMARY_FPR" ] || die "cannot read the key in $KEYRING" 2

check_key_expiry() {
	local now exp days line kind
	now=$(date +%s)
	while IFS= read -r line; do
		kind=${line%%:*}
		exp=$(printf '%s' "$line" | cut -d: -f7)
		[ -n "$exp" ] || continue
		days=$(((exp - now) / 86400))
		if [ "$days" -lt 0 ]; then
			die "the signing key ($kind) is EXPIRED. Servers will reject the repository. Extend or replace the key first (README.md, key rotation)." 2
		elif [ "$days" -lt 60 ]; then
			echo "$PROG: WARNING: the signing key ($kind) expires in $days days. Plan the key rotation now." >&2
		fi
	done < <(gpg --batch --show-keys --with-colons "$KEYRING" 2> /dev/null | grep '^\(pub\|sub\):')
}
check_key_expiry

# Package name and architecture of a deb file, validated.
deb_field() {
	dpkg-deb -f "$1" "$2"
}

suite_exists() {
	grep -q "^Codename: $1\$" "$REPO/conf/distributions"
}

current_version() { # suite arch -> version or empty
	reprepro -b "$REPO" -A "$2" -T deb list "$1" hestia 2> /dev/null | awk '{print $NF}' | head -n1
}

# Check that Release/InRelease are signed by the repository key and that the indices match the deb.
verify_published() { # suite deb pkg version arch
	local suite="$1" deb="$2" pkg="$3" ver="$4" arch="$5" rel out sha size got pk f
	rel="$PUBLIC/dists/$suite"
	for f in InRelease Release Release.gpg; do
		[ -s "$rel/$f" ] || die "missing $rel/$f after publishing" 3
	done
	out=$(gpgv --keyring "$KEYRING" --status-fd 1 "$rel/InRelease" 2> /dev/null) || die "InRelease signature check FAILED for $suite" 3
	got=$(printf '%s\n' "$out" | awk '$2=="VALIDSIG"{print $12;exit}')
	[ "$got" = "$PRIMARY_FPR" ] || die "InRelease of $suite is signed by $got, expected $PRIMARY_FPR" 3
	gpgv --keyring "$KEYRING" "$rel/Release.gpg" "$rel/Release" > /dev/null 2>&1 || die "Release.gpg signature check FAILED for $suite" 3

	# Chain: Release (signed) -> Packages.gz (sha256) -> deb (sha256, size).
	pk="main/binary-$arch/Packages.gz"
	sha=$(sha256sum "$rel/$pk" | awk '{print $1}')
	if ! awk -v f="$pk" -v s="$sha" '/^SHA256:/{x=1;next} /^[A-Za-z0-9-]+:/{x=0} x && $3==f && $1==s {ok=1} END{exit ok?0:1}' "$rel/Release"; then
		die "Release of $suite does not list the current $pk (sha256 mismatch)" 3
	fi
	sha=$(sha256sum "$deb" | awk '{print $1}')
	size=$(stat -c %s "$deb")
	if ! zcat "$rel/$pk" | awk -v p="$pkg" -v v="$ver" -v s="$sha" -v z="$size" '
		BEGIN{RS=""; FS="\n"}
		{ n=""; vv=""; ss=""; zz=""
		  for(i=1;i<=NF;i++){
		    if($i ~ /^Package: /) n=substr($i,10)
		    if($i ~ /^Version: /) vv=substr($i,10)
		    if($i ~ /^SHA256: /) ss=substr($i,9)
		    if($i ~ /^Size: /) zz=substr($i,7)
		  }
		  if(n==p && vv==v && ss==s && zz==z) ok=1 }
		END{exit ok?0:1}'; then
		die "$pk does not contain $pkg $ver with the expected sha256/size" 3
	fi
}

prune_archive() { # suite arch
	local suite="$1" arch="$2" dir f v keep_list=() i=0 pkgname
	dir="$ARCHIVE/$suite"
	[ -d "$dir" ] || return 0
	local -a vers=()
	for f in "$dir"/hestia_*_"$arch".deb; do
		[ -e "$f" ] || continue
		pkgname=$(deb_field "$f" Package)
		[ "$pkgname" = "hestia" ] || continue
		vers+=("$(deb_field "$f" Version)")
	done
	[ "${#vers[@]}" -gt 0 ] || return 0
	while IFS= read -r v; do
		i=$((i + 1))
		if [ "$i" -le "$KEEP" ]; then
			keep_list+=("$v")
		fi
	done < <(printf '%s\n' "${vers[@]}" | sort_versions_desc)
	for f in "$dir"/hestia_*_"$arch".deb; do
		[ -e "$f" ] || continue
		v=$(deb_field "$f" Version)
		local k found=0
		for k in "${keep_list[@]}"; do
			[ "$k" = "$v" ] && found=1
		done
		if [ "$found" -eq 0 ]; then
			rm -f -- "$f"
			echo "  pruned from archive : $(basename "$f")"
		fi
	done
}

archive_name() { # pkg version arch
	echo "${1}_${2}_${3}.deb"
}

# Resolve and check the source commit BEFORE anything is published, so that a refusal leaves the
# repository untouched.
preflight_source() {
	if [ "$NO_SOURCE" -eq 1 ]; then
		return 0
	fi
	command -v git > /dev/null 2>&1 || die "git is not installed (needed for the source archive; or use --no-source)" 2
	if [ -z "$SRC_REPO" ]; then
		SRC_REPO=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2> /dev/null) \
			|| die "cannot find the source checkout; use --source-repo DIR or --no-source" 2
	fi
	SOURCE_COMMIT=$(git -C "$SRC_REPO" rev-parse --verify "$SRC_COMMIT^{commit}" 2> /dev/null) || die "unknown source commit: $SRC_COMMIT" 2
	if [ "$(git -C "$SRC_REPO" rev-parse HEAD)" = "$SOURCE_COMMIT" ] && [ -n "$(git -C "$SRC_REPO" status --porcelain --untracked-files=no)" ]; then
		if [ "$ALLOW_DIRTY" -eq 0 ]; then
			die "the source checkout has uncommitted changes; the archive would not match the package. Commit first or use --allow-dirty." 2
		fi
		echo "$PROG: WARNING: working tree is dirty; the source archive contains only commit ${SOURCE_COMMIT:0:12}" >&2
	fi
}

store_source() { # deb-version
	local ver="$1" base_rev commit short control_ver want out name tmp
	SOURCE_FILE=''
	if [ "$NO_SOURCE" -eq 1 ]; then
		echo "  source archive      : SKIPPED (--no-source). Do not distribute these binaries without source."
		return 0
	fi
	commit="$SOURCE_COMMIT"
	short=${commit:0:12}
	# 1.10.5-100+ubuntu24.04~ci1 -> 1.10.5-100
	base_rev=${ver%%+*}
	base_rev=${base_rev%%~*}
	control_ver=$(git -C "$SRC_REPO" show "$commit:src/deb/hestia/control" 2> /dev/null | awk '/^Version:/{print $2;exit}')
	want=${base_rev%%-*}
	if [ -n "$control_ver" ] && [ "${control_ver%%~*}" != "$want" ]; then
		echo "$PROG: WARNING: src/deb/hestia/control in $short says $control_ver, the package is $ver. Check that the right commit is archived." >&2
	fi
	name="vylarisspace-${base_rev}-${short}.tar.gz"
	out="$PUBLIC/sources/$name"
	if [ ! -e "$out" ]; then
		tmp=$(mktemp "$PUBLIC/sources/.tmp.XXXXXX")
		git -C "$SRC_REPO" archive --format=tar.gz --prefix="vylarisspace-${base_rev}/" "$commit" > "$tmp"
		mv -f -- "$tmp" "$out"
		chmod 644 "$out"
	fi
	(cd "$PUBLIC/sources" && sha256sum -- *.tar.gz > SHA256SUMS)
	if [ ! -e "$PUBLIC/sources/README" ]; then
		cat > "$PUBLIC/sources/README" << 'SRC_EOF'
Source code of the VylarisSpace packages served from this repository.

Each file vylarisspace-<version>-<revision>-<commit>.tar.gz is the exact source tree
(git archive) from which the package with that version was built. The panel is licensed under
GPL-3.0-or-later; the license text is the file LICENSE inside every archive.
Build instructions: src/hst_autocompile.sh and VYLARIS-PACKAGING.md inside the archive.
SHA256SUMS lists the checksums of the archives.
SRC_EOF
		chmod 644 "$PUBLIC/sources/README"
	fi
	SOURCE_FILE="$out"
}

# Publish one deb file into a suite. Echo a summary.
publish_one() { # deb suite do_source(1|0)
	local deb="$1" suite="$2" do_source="$3" pkg ver arch cur sha aname
	[ -f "$deb" ] || die "no such file: $deb"
	pkg=$(deb_field "$deb" Package) || die "not a deb file: $deb"
	ver=$(deb_field "$deb" Version)
	arch=$(deb_field "$deb" Architecture)
	if [ "$pkg" != "hestia" ] && [ "$ALLOW_OTHER" -eq 0 ]; then
		die "$deb is package '$pkg'. Stage 1 of this repository carries ONLY 'hestia' (hestia-nginx, hestia-php and hestia-web-terminal come from the upstream repository). Use --allow-other-packages for stage 2." 2
	fi
	case " $SUPPORTED_ARCHS " in
		*" $arch "*) ;;
		*) die "$deb has architecture '$arch' (supported: $SUPPORTED_ARCHS)" 2 ;;
	esac
	suite_exists "$suite" || die "suite '$suite' is not configured in conf/distributions" 2
	sha=$(sha256sum "$deb" | awk '{print $1}')
	aname=$(archive_name "$pkg" "$ver" "$arch")

	# A version number is used once. Re-using it for different content (for example after a rollback)
	# would leave servers with two different builds under one version.
	if [ -f "$ARCHIVE/$suite/$aname" ] && [ "$(sha256sum "$ARCHIVE/$suite/$aname" | awk '{print $1}')" != "$sha" ]; then
		die "$pkg $ver was published to $suite before with different content. Increase the package revision (--pkgrev)." 2
	fi

	cur=$(current_version "$suite" "$arch")
	if [ -n "$cur" ] && dpkg --compare-versions "$ver" eq "$cur"; then
		if [ -f "$ARCHIVE/$suite/$aname" ] && [ "$(sha256sum "$ARCHIVE/$suite/$aname" | awk '{print $1}')" = "$sha" ]; then
			echo "  note                : $ver is already published in $suite with identical content; nothing to do"
		else
			die "$suite already serves $pkg $ver with different content. Increase the package revision (--pkgrev)." 2
		fi
	elif [ -n "$cur" ] && dpkg --compare-versions "$ver" lt "$cur"; then
		die "$suite already serves $cur, which is newer than $ver. The index holds one version per suite; use --rollback to go back deliberately." 2
	else
		reprepro -b "$REPO" includedeb "$suite" "$deb" > /dev/null
	fi

	mkdir -p "$ARCHIVE/$suite"
	chmod 700 "$ARCHIVE/$suite"
	if [ ! -f "$ARCHIVE/$suite/$aname" ]; then
		cp -- "$deb" "$ARCHIVE/$suite/$aname"
	fi
	verify_published "$suite" "$deb" "$pkg" "$ver" "$arch"

	echo "published             : $pkg $ver ($arch) -> suite $suite"
	echo "  sha256              : $sha"
	echo "  size                : $(stat -c %s "$deb") bytes"
	echo "  signed by           : $PRIMARY_FPR (InRelease and Release.gpg verified, indices match the deb)"
	prune_archive "$suite" "$arch"
	if [ "$do_source" -eq 1 ]; then
		store_source "$ver"
		if [ -n "$SOURCE_FILE" ]; then
			echo "  source archive      : sources/$(basename "$SOURCE_FILE") (commit $SOURCE_COMMIT)"
			echo "  source sha256       : $(sha256sum "$SOURCE_FILE" | awk '{print $1}')"
		fi
	fi
	mkdir -p "$REPO/logs"
	printf '%s suite=%s pkg=%s version=%s arch=%s sha256=%s commit=%s\n' "$(date -u +%FT%TZ)" "$suite" "$pkg" "$ver" "$arch" "$sha" "${SOURCE_COMMIT:-none}" >> "$REPO/logs/publish.log"
}

case "$MODE" in
	publish)
		[ "${#POSITIONAL[@]}" -ge 2 ] || {
			usage >&2
			exit 1
		}
		DEBS=("${POSITIONAL[@]:1}")
		preflight_source
		for d in "${DEBS[@]}"; do
			[ -f "$d" ] || die "no such file: $d"
		done
		# Decide all suites first, so that a problem with the last file leaves the repository untouched.
		SUITES=()
		for d in "${DEBS[@]}"; do
			if [ -n "$SUITE_OVERRIDE" ]; then
				S="$SUITE_OVERRIDE"
			else
				V=$(deb_field "$d" Version) || die "not a deb file: $d"
				S=$(suite_from_version "$V") || die "cannot derive the suite from version '$V' (expected +debian12, +debian13, +ubuntu22.04 or +ubuntu24.04). Use --suite." 2
			fi
			suite_exists "$S" || die "suite '$S' (for $d) is not configured in conf/distributions" 2
			if [ "$(deb_field "$d" Package)" != "hestia" ] && [ "$ALLOW_OTHER" -eq 0 ]; then
				die "$d is package '$(deb_field "$d" Package)'. Stage 1 carries ONLY 'hestia'. Use --allow-other-packages for stage 2." 2
			fi
			SUITES+=("$S")
		done
		for i in "${!DEBS[@]}"; do
			publish_one "${DEBS[$i]}" "${SUITES[$i]}" 1
		done
		;;
	rollback)
		[ "${#POSITIONAL[@]}" -eq 3 ] || {
			usage >&2
			exit 1
		}
		SUITE="${POSITIONAL[1]}"
		VER="${POSITIONAL[2]}"
		suite_exists "$SUITE" || die "suite '$SUITE' is not configured" 2
		FOUND=0
		for arch in $SUPPORTED_ARCHS; do
			f="$ARCHIVE/$SUITE/$(archive_name hestia "$VER" "$arch")"
			[ -f "$f" ] || continue
			FOUND=1
			cur=$(current_version "$SUITE" "$arch")
			if [ -n "$cur" ] && [ "$cur" = "$VER" ]; then
				echo "$arch: $VER is already the served version"
				continue
			fi
			if [ -n "$cur" ]; then
				reprepro -b "$REPO" -A "$arch" -T deb remove "$SUITE" hestia > /dev/null
			fi
			reprepro -b "$REPO" includedeb "$SUITE" "$f" > /dev/null
			verify_published "$SUITE" "$f" hestia "$VER" "$arch"
			echo "rolled back           : hestia $VER ($arch) is now served in $SUITE (was ${cur:-nothing})"
			echo "  sha256              : $(sha256sum "$f" | awk '{print $1}')"
			printf '%s ROLLBACK suite=%s version=%s arch=%s from=%s\n' "$(date -u +%FT%TZ)" "$SUITE" "$VER" "$arch" "${cur:-none}" >> "$REPO/logs/publish.log"
		done
		[ "$FOUND" -eq 1 ] || die "no archived build of hestia $VER for suite $SUITE (see $ARCHIVE/$SUITE)" 2
		echo "NOTE: servers configured by client-setup.sh pin the repository with priority 1001. For such a"
		echo "server the older version is a downgrade candidate: apt moves it back to $VER at the next"
		echo "'apt-get upgrade' / 'apt-get install --only-upgrade hestia' (tested). The upgrade scripts in the"
		echo "package are forward-only, so try the downgrade on a test server first. Preferred fix: publish a"
		echo "corrected build with a HIGHER revision instead of rolling back."
		;;
	promote)
		if [ "${#POSITIONAL[@]}" -lt 2 ] || [ "${#POSITIONAL[@]}" -gt 3 ]; then
			usage >&2
			exit 1
		fi
		SUITE="${POSITIONAL[1]}"
		VER="${POSITIONAL[2]:-}"
		STAGING="$SUITE-staging"
		suite_exists "$SUITE" || die "suite '$SUITE' is not configured" 2
		suite_exists "$STAGING" || die "suite '$STAGING' is not configured (repo-init.sh --staging)" 2
		if [ -z "$VER" ]; then
			VER=$(for f in "$ARCHIVE/$STAGING"/hestia_*.deb; do [ -e "$f" ] && deb_field "$f" Version; done | sort_versions_desc | head -n1)
		fi
		[ -n "$VER" ] || die "nothing archived for $STAGING" 2
		FOUND=0
		for arch in $SUPPORTED_ARCHS; do
			f="$ARCHIVE/$STAGING/$(archive_name hestia "$VER" "$arch")"
			[ -f "$f" ] || continue
			FOUND=1
			publish_one "$f" "$SUITE" 0
		done
		[ "$FOUND" -eq 1 ] || die "no archived build of hestia $VER for $STAGING" 2
		;;
esac
