#!/usr/bin/env bash
# build-debs.sh - build the two test packages from a SCRATCH COPY of the checkout.
#
#   deb A: version <base>-100+ubuntu24.04   (what the server is installed with)
#   deb B: version <base>-101+ubuntu24.04   (the "update": A plus the file
#                                            web/vylaris-build-marker.txt)
#
# Usage: build-debs.sh <repo-checkout> <work-dir> <out-dir>
#
# The checkout itself is only READ (git ls-files); nothing is written into it. The panel is
# built by src/hst_autocompile.sh of the scratch copy exactly like a release build
# (npm ci + npm run build + composer install --no-dev, dpkg-deb). Needs on this host:
# Ubuntu 24.04 (the package version suffix comes from lsb_release), node + npm, composer,
# dpkg-deb, network access to the npm registry and Packagist.
set -euo pipefail

[ $# -eq 3 ] || {
	sed -n '2,15p' "$0"
	exit 1
}
SRC=$(cd "$1" && pwd)
WORK=$2
OUT=$3
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd)
OUT=$(cd "$OUT" && pwd)

case "$(lsb_release -is 2> /dev/null)$(lsb_release -rs 2> /dev/null)" in
	Ubuntu24.04) ;;
	*)
		echo "build-debs.sh: this host must be Ubuntu 24.04 (the deb suffix +ubuntu24.04 is derived from it)" >&2
		exit 1
		;;
esac
for t in node npm composer dpkg-deb git; do
	command -v "$t" > /dev/null || {
		echo "build-debs.sh: $t not found" >&2
		exit 1
	}
done

build_one() {
	local label=$1 pkgrev=$2 marker=$3
	local tree="$WORK/tree-$label" bd="$WORK/build-$label" deb="$WORK/deb-$label"
	rm -rf "$tree" "$bd" "$deb"
	mkdir -p "$tree" "$bd" "$deb"
	# the working tree (tracked + untracked, not ignored), as a release build would use it
	(cd "$SRC" && git ls-files -z --cached --others --exclude-standard | grep -zv '^test/vylaris-upgrade/' \
		| tar --null -T - -cf -) | tar -C "$tree" -xf -
	if [ -n "$marker" ]; then
		printf '%s\n' "$marker" > "$tree/web/vylaris-build-marker.txt"
	fi
	echo "=== building deb $label (pkgrev $pkgrev) from scratch copy $tree"
	(
		cd "$tree"
		BUILD_DIR="$bd" DEB_DIR="$deb" ARCHIVE_DIR="$WORK/archive" \
			bash src/hst_autocompile.sh --hestia --noinstall --keepbuild --dontinstalldeps --pkgrev "$pkgrev" '~localsrc'
	) > "$WORK/build-$label.log" 2>&1 || {
		tail -30 "$WORK/build-$label.log" >&2
		echo "build $label failed (log: $WORK/build-$label.log)" >&2
		exit 1
	}
	local f
	f=$(ls "$deb"/hestia_*.deb)
	cp "$f" "$OUT/"
	echo "built $(basename "$f")"
}

build_one A 100 ''
build_one B 101 'VylarisSpace upgrade test: this file exists only in build B (revision 101).'
ls -l "$OUT"/hestia_*.deb
