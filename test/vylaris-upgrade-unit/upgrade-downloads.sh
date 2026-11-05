#!/bin/bash
# Unit test for the download helpers of func/upgrade.sh (upgrade_b2_tool,
# upgrade_phpmyadmin): a failed download must keep the installed component and must
# never stop the upgrade. wget is replaced by a stub, no network is used.
# The test writes /usr/local/bin/b2 and /usr/share/phpmyadmin, so it only runs inside a
# throw-away container (see run-in-docker.sh) or with VYLARIS_UNIT_FORCE=1.
#
#   test/vylaris-upgrade-unit/run-in-docker.sh

if [ ! -e /.dockerenv ] && [ "${VYLARIS_UNIT_FORCE:-}" != "1" ]; then
	echo "skip: not inside a container (use run-in-docker.sh or set VYLARIS_UNIT_FORCE=1)"
	exit 0
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck disable=SC2034
HESTIA="$REPO"
# shellcheck source=func/upgrade.sh
source "$REPO/func/upgrade.sh"
eval "$(grep '^version_ge()' "$REPO/func/main.sh")"

# wget stub: WGET_MODE=ok writes a valid file, fail exits 4 after a partial write,
# empty writes nothing and succeeds, html writes a text page and succeeds
mkdir -p "$WORK/stub"
cat > "$WORK/stub/wget" << 'STUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
	case "$1" in
		-O) out="$2"; shift ;;
	esac
	shift
done
case "$WGET_MODE" in
	ok-b2) printf '\177ELFnewbinary' > "$out" ;;
	ok-pma)
		d="$(mktemp -d)"
		mkdir -p "$d/phpMyAdmin-9.9.9-all-languages/libraries"
		echo new > "$d/phpMyAdmin-9.9.9-all-languages/index.php"
		echo "<?php" > "$d/phpMyAdmin-9.9.9-all-languages/libraries/vendor_config.php"
		tar czf "$out" -C "$d" phpMyAdmin-9.9.9-all-languages
		rm -rf "$d"
		;;
	fail) printf 'partial' > "$out"; exit 4 ;;
	empty) : > "$out" ;;
	html) echo "<html>not found</html>" > "$out" ;;
esac
exit 0
STUB
chmod +x "$WORK/stub/wget"
PATH="$WORK/stub:$PATH"

fails=0
check() { # NAME CONDITION-RESULT(0 = true)
	if [ "$2" -eq 0 ]; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		fails=$((fails + 1))
	fi
}

# ---- b2 ----
# shellcheck disable=SC2034
b2_v="9.9.9"
install_old_b2() {
	rm -f /usr/local/bin/b2 /usr/local/bin/.b2.*
	mkdir -p /usr/local/bin
	printf '#!/bin/sh\necho "b2 command line tool, version 1.0.0"\n' > /usr/local/bin/b2
	chmod 755 /usr/local/bin/b2
}

for mode in fail empty html; do
	install_old_b2
	WGET_MODE=$mode upgrade_b2_tool > "$WORK/out" 2>&1
	rc=$?
	check "b2 download '$mode': function returns 0 (does not stop the upgrade)" $rc
	grep -q "version 1.0.0" /usr/local/bin/b2
	check "b2 download '$mode': old tool is still in place" $?
	ls /usr/local/bin/.b2.* > /dev/null 2>&1
	[ $? -ne 0 ]
	check "b2 download '$mode': no temporary file is left" $?
	grep -q "Warning" "$WORK/out"
	check "b2 download '$mode': a warning is printed" $?
done

install_old_b2
WGET_MODE=ok-b2 upgrade_b2_tool > "$WORK/out" 2>&1
check "b2 download ok: function returns 0" $?
[ "$(head -c 4 /usr/local/bin/b2 | tail -c 3)" = "ELF" ] && [ -x /usr/local/bin/b2 ]
check "b2 download ok: new tool is installed and executable" $?
ls /usr/local/bin/.b2.* > /dev/null 2>&1
[ $? -ne 0 ]
check "b2 download ok: no temporary file is left" $?
rm -f /usr/local/bin/b2

# no b2 installed: nothing happens
WGET_MODE=ok-b2 upgrade_b2_tool > /dev/null 2>&1
[ ! -e /usr/local/bin/b2 ]
check "b2 not installed: not installed by the upgrade" $?

# ---- phpMyAdmin ----
# shellcheck disable=SC2034
DB_SYSTEM="mysql"
# shellcheck disable=SC2034
pma_v="9.9.9"
jq() { echo "1.0.0"; }
hestia_pma_setup() {
	rm -rf /usr/share/phpmyadmin /etc/phpmyadmin /var/lib/phpmyadmin
	mkdir -p /usr/share/phpmyadmin/doc/html /usr/share/phpmyadmin/libraries /etc/phpmyadmin
	echo old > /usr/share/phpmyadmin/index.php
	echo "doc" > /usr/share/phpmyadmin/doc/html/index.html
	echo "<?php 'configFile' => ROOT_PATH . 'config.inc.php'," > /usr/share/phpmyadmin/libraries/vendor_config.php
}
# the permission commands need the mail user and group
getent group hestiamail > /dev/null || groupadd hestiamail 2> /dev/null
getent passwd hestiamail > /dev/null || useradd -g hestiamail hestiamail 2> /dev/null

for mode in fail empty html; do
	hestia_pma_setup
	WGET_MODE=$mode upgrade_phpmyadmin > "$WORK/out" 2>&1
	check "phpMyAdmin download '$mode': function returns 0" $?
	[ "$(cat /usr/share/phpmyadmin/index.php)" = "old" ] && [ -f /usr/share/phpmyadmin/doc/html/index.html ]
	check "phpMyAdmin download '$mode': installed version and its docs are untouched" $?
	grep -q "Warning" "$WORK/out"
	check "phpMyAdmin download '$mode': a warning is printed" $?
done

hestia_pma_setup
WGET_MODE=ok-pma upgrade_phpmyadmin > "$WORK/out" 2>&1
[ "$(cat /usr/share/phpmyadmin/index.php)" = "new" ]
check "phpMyAdmin download ok: new files are installed" $?
[ ! -e phpMyAdmin-9.9.9-all-languages ] && [ ! -e /usr/share/phpmyadmin/pma.tar.gz ]
check "phpMyAdmin download ok: nothing left in the working directory" $?
rm -rf /usr/share/phpmyadmin /etc/phpmyadmin /var/lib/phpmyadmin

if [ "$fails" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$fails check(s) failed."
	exit 1
fi
