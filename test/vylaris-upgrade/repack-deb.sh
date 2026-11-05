#!/usr/bin/env bash
# repack-deb.sh - make a variant of a built hestia deb for the guard and recovery phases.
#
#   repack-deb.sh own     <in.deb> <out.deb> <version>   same package, new version (a later own revision)
#   repack-deb.sh foreign <in.deb> <out.deb> <version>   stand-in for the upstream package: no
#                                                        Vylaris-Edition field, none of the files that only
#                                                        this edition ships (themes, apt hook, checker, prerm),
#                                                        one file web/foreign.txt, and a postinst that only
#                                                        writes /root/foreign-postinst-ran
#
# The foreign stand-in keeps the real preinst of the input package on purpose: dpkg runs the preinst
# of the NEW package before the prerm of the installed one, so that is what a real upstream
# package would do too. Host side, needs dpkg-deb. The input is only read.
set -euo pipefail

kind=${1:-}
in=${2:-}
out=${3:-}
ver=${4:-}
{ [ "$kind" = own ] || [ "$kind" = foreign ]; } && [ -f "$in" ] && [ -n "$out" ] && [ -n "$ver" ] || {
	sed -n '2,13p' "$0"
	exit 2
}
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
dpkg-deb -R "$in" "$d/t"
sed -i "s/^Version: .*/Version: $ver/" "$d/t/DEBIAN/control"
if [ "$kind" = foreign ]; then
	sed -i '/^Vylaris-Edition:/d' "$d/t/DEBIAN/control"
	rm -rf "$d"/t/usr/local/hestia/web/css/themes/vylaris* "$d/t/etc" "$d/t/DEBIAN/prerm" "$d/t/DEBIAN/md5sums"
	rm -f "$d/t/usr/local/hestia/bin/v-check-package-source"
	echo "stand-in for a foreign hestia package" > "$d/t/usr/local/hestia/web/foreign.txt"
	printf '#!/bin/sh\ntouch /root/foreign-postinst-ran\nexit 0\n' > "$d/t/DEBIAN/postinst"
	chmod 755 "$d/t/DEBIAN/postinst"
fi
dpkg-deb --root-owner-group -Zgzip -b "$d/t" "$out" > /dev/null
echo "repacked $kind: $(dpkg-deb -f "$out" Package Version | tr '\n' ' ') Vylaris-Edition='$(dpkg-deb -f "$out" Vylaris-Edition)' -> $out"
