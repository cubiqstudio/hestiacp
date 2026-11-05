#!/bin/bash
# Unit test for the configure-only guard at the top of src/deb/hestia/postinst:
# dpkg also calls the old postinst with abort-upgrade, abort-remove and so on, which
# must not start the upgrade procedure. A marker command in the fake hestia.conf shows
# whether the script went past the guard. Writes /usr/local/hestia and /etc/hestiacp,
# so it only runs inside a throw-away container (see run-in-docker.sh).

if [ ! -e /.dockerenv ] && [ "${VYLARIS_UNIT_FORCE:-}" != "1" ]; then
	echo "skip: not inside a container (use run-in-docker.sh or set VYLARIS_UNIT_FORCE=1)"
	exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POSTINST="$REPO/src/deb/hestia/postinst"
mkdir -p /usr/local/hestia/data/users /etc/hestiacp
fails=0
n=0
for arg in abort-upgrade abort-remove abort-deconfigure triggered "" configure; do
	n=$((n + 1))
	marker="/tmp/postinst-marker-$n"
	echo "touch $marker" > /etc/hestiacp/hestia.conf
	bash "$POSTINST" $arg > /dev/null 2>&1
	rc=$?
	if [ -e "$marker" ]; then ran="yes"; else ran="no"; fi
	if [ "$arg" = "configure" ]; then want="yes"; else want="no"; fi
	if [ "$ran" = "$want" ] && [ "$rc" -eq 0 ]; then
		echo "ok   postinst '${arg:-<no argument>}': upgrade procedure started: $ran (exit $rc)"
	else
		echo "FAIL postinst '${arg:-<no argument>}': started $ran, want $want (exit $rc)"
		fails=$((fails + 1))
	fi
done
if [ "$fails" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$fails check(s) failed."
	exit 1
fi
