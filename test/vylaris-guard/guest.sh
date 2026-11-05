#!/usr/bin/env bash
# guest.sh - package guard test, runs INSIDE the test container (started by run.sh).
# /debs/own-old.deb  VylarisSpace package, older revision (the guarded build)
# /debs/own-new.deb  VylarisSpace package, newer revision
# Everything else (the foreign stand-ins, a local apt repository) is made here.
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
fail=0
pass=0

say() { printf '\n### %s\n' "$*"; }
ok() { # description, condition command...
	local d=$1
	shift
	if "$@" > /dev/null 2>&1; then
		echo "PASS: $d"
		pass=$((pass + 1))
	else
		echo "FAIL: $d"
		fail=$((fail + 1))
	fi
}
ver() { dpkg-query -W -f='${Version}' hestia 2> /dev/null; }
theme_present() { [ -e /usr/local/hestia/web/css/themes/vylaris.min.css ]; }
# show a command, run it, show its exit code
run() {
	echo "\$ $*"
	"$@" 2>&1 | sed 's/^/    /'
	rc=${PIPESTATUS[0]}
	echo "    [exit $rc]"
	return "$rc"
}
state() { echo "    installed hestia: $(ver) / vylaris theme: $(theme_present && echo present || echo MISSING)"; }

sfx=$(. /etc/os-release && echo "${ID}${VERSION_ID}")
OLD_V=$(dpkg-deb -f /debs/own-old.deb Version)
NEW_V=$(dpkg-deb -f /debs/own-new.deb Version)
FOREIGN_V="1.10.6-1+$sfx"
NEWER_V="1.10.6-100+$sfx"

# ---------------------------------------------------------------- stand-in packages
mkdir -p /work /srv/repo
repack() { # source-deb new-version out-deb strip-marker(yes|no) [prerm-exit0]
	local d=/work/repack-tree
	rm -rf "${d:?}"
	dpkg-deb -R "$1" "$d"
	sed -i "s/^Version: .*/Version: $2/" "$d/DEBIAN/control"
	if [ "$4" = yes ]; then
		sed -i '/^Vylaris-Edition:/d' "$d/DEBIAN/control"
		# like upstream: no VylarisSpace files, no hook, no prerm
		rm -rf "${d:?}"/usr/local/hestia/web/css/themes/vylaris* "${d:?}/etc" "${d:?}/DEBIAN/prerm"
		rm -f "$d/usr/local/hestia/bin/v-check-package-source"
		echo "upstream stand-in" > "$d/usr/local/hestia/web/foreign.txt"
	fi
	if [ -n "${5:-}" ]; then
		printf '#!/bin/sh\nexit 0\n' > "$d/DEBIAN/prerm"
		chmod 755 "$d/DEBIAN/prerm"
	fi
	dpkg-deb --root-owner-group -Zgzip -b "$d" "$3" > /dev/null
	rm -rf "${d:?}"
}
tiny() { # name version out-deb
	local d=/work/tiny-tree
	rm -rf "${d:?}"
	mkdir -p "$d/DEBIAN" "$d/usr/share/$1"
	printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@example.org>\nDescription: stand-in\n' "$1" "$2" > "$d/DEBIAN/control"
	echo x > "$d/usr/share/$1/file"
	dpkg-deb --root-owner-group -Zgzip -b "$d" "$3" > /dev/null
	rm -rf "${d:?}"
}

repack /debs/own-new.deb "$FOREIGN_V" /work/foreign.deb yes
repack /debs/own-new.deb "$FOREIGN_V" /work/foreign-prerm.deb yes prerm
repack /debs/own-new.deb "$NEWER_V" /work/own-newer.deb no
mkdir -p "/work/dir with space"
cp /work/foreign.deb "/work/dir with space/foreign hestia.deb"
cp /work/foreign.deb /work/-foreign.deb
tiny hestia-nginx 1.28.0-1 /work/hestia-nginx.deb
tiny hestia-php 8.4.0-1 /work/hestia-php.deb
tiny hestia-web-terminal 1.0-1 /work/hestia-web-terminal.deb
tiny hestia-foo 1.0-1 /work/hestia-foo.deb
tiny hestia-tools 1.0-1 /work/hestia-tools.deb
tiny nothestia 1.0-1 /work/nothestia.deb

cp /work/foreign.deb "/srv/repo/hestia_${FOREIGN_V}_amd64.deb"
cp /work/own-newer.deb "/srv/repo/hestia_${NEWER_V}_amd64.deb"
(cd /srv/repo && dpkg-scanpackages --multiversion . > Packages 2> /dev/null && apt-ftparchive release . > Release)
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
echo 'deb [trusted=yes] file:/srv/repo ./' > /etc/apt/sources.list.d/test.list
apt-get update > /dev/null 2>&1

reset_own() { # make the guarded older build the installed one, no override, hook and checker present
	rm -f /etc/hestiacp/allow-foreign-hestia
	dpkg -i /debs/own-old.deb > /dev/null 2>&1
}

say "0. first install of the guarded package (nothing else installed): must not be blocked"
run apt-get install -y /debs/own-old.deb | tail -3
ok "installed version is $OLD_V" test "$(ver)" = "$OLD_V"
echo "    control field: Vylaris-Edition: $(dpkg-deb -f /debs/own-old.deb Vylaris-Edition)"
ok "prerm, preinst, postinst in the control data, executable" bash -c 'dpkg-deb -e /debs/own-old.deb /work/ctl && test -x /work/ctl/prerm && test -x /work/ctl/preinst && test -x /work/ctl/postinst'
ok "hook is owned by the package: dpkg -S" bash -c 'dpkg -S /etc/apt/apt.conf.d/90vylarisspace-guard | grep -q "^hestia:"'
ok "checker is owned by the package: dpkg -S" bash -c 'dpkg -S /usr/local/hestia/bin/v-check-package-source | grep -q "^hestia:"'
echo "    hook:"
sed 's/^/      /' /etc/apt/apt.conf.d/90vylarisspace-guard
ls -l /etc/apt/apt.conf.d/90vylarisspace-guard /usr/local/hestia/bin/v-check-package-source /var/lib/dpkg/info/hestia.prerm | sed 's/^/    /'
ok "package lists only root-owned files" bash -c '! dpkg-deb -c /debs/own-old.deb | awk "\$2 != \"root/root\"" | grep -q .'

say "1. dpkg -i of the foreign package (version $FOREIGN_V, no marker): refused by prerm"
run dpkg -i /work/foreign.deb
ok "dpkg -i refused" bash -c '! dpkg -i /work/foreign.deb > /dev/null 2>&1'
state
ok "own version still installed" test "$(ver)" = "$OLD_V"
ok "VylarisSpace theme still present" theme_present
ok "foreign file not unpacked" test ! -e /usr/local/hestia/web/foreign.txt
ok "package not left in a broken state (dpkg -s says installed)" bash -c 'dpkg -s hestia | grep -q "^Status: install ok installed"'

say "2. apt-get install ./foreign.deb: refused by the apt hook before dpkg runs"
run apt-get install -y /work/foreign.deb
ok "apt refused" bash -c '! apt-get install -y /work/foreign.deb > /dev/null 2>&1'
state
ok "own version still installed" test "$(ver)" = "$OLD_V"
ok "theme still present" theme_present
ok "hook stopped it before unpacking (hook message, not the prerm message)" bash -c 'apt-get install -y /work/foreign.deb 2>&1 | grep -q "is a package named hestia that is not a"'

say "3. apt-get install hestia=$FOREIGN_V from a repository"
run apt-get install -y "hestia=$FOREIGN_V"
ok "apt refused" bash -c "! apt-get install -y hestia=$FOREIGN_V > /dev/null 2>&1"
ok "own version still installed" test "$(ver)" = "$OLD_V"

say "4. apt hook removed: the prerm layer alone must stop apt-get install ./foreign.deb"
mv /etc/apt/apt.conf.d/90vylarisspace-guard /work/hook.saved
run apt-get install -y /work/foreign.deb
ok "apt refused by the prerm" bash -c '! apt-get install -y /work/foreign.deb > /dev/null 2>&1'
ok "prerm message shown" bash -c 'apt-get install -y /work/foreign.deb 2>&1 | grep -q "^REFUSED: the package that is about to replace"'
ok "own version still installed" test "$(ver)" = "$OLD_V"
mv /work/hook.saved /etc/apt/apt.conf.d/90vylarisspace-guard

say "5. foreign package that ships its own prerm (exit 0): apt and dpkg -i"
echo "(a) apt-get install ./foreign-prerm.deb"
run apt-get install -y /work/foreign-prerm.deb
ok "apt hook refuses it" bash -c '! apt-get install -y /work/foreign-prerm.deb > /dev/null 2>&1'
ok "own version still installed after apt" test "$(ver)" = "$OLD_V"
echo "(b) dpkg -i ./foreign-prerm.deb (no apt hook involved)"
run dpkg -i /work/foreign-prerm.deb
state
if [ "$(ver)" = "$FOREIGN_V" ]; then
	echo "BYPASS-KNOWN: dpkg -i accepted it. When the installed prerm fails, dpkg runs the NEW package's 'prerm failed-upgrade';"
	echo "              a foreign package with a prerm that exits 0 passes. The upstream hestia package has no prerm."
fi
reset_own
state

say "6. own newer revision: apt-get install ./own-new.deb and from the repository"
run apt-get install -y /debs/own-new.deb | tail -2
ok "own newer revision installed ($NEW_V)" test "$(ver)" = "$NEW_V"
run apt-get install -y "hestia=$NEWER_V" | tail -2
ok "own newer version from the repository installed ($NEWER_V)" test "$(ver)" = "$NEWER_V"
theme_present && echo "    theme present"

say "7. downgrade to the own older build"
run apt-get install -y /debs/own-old.deb | tail -2
ok "apt without --allow-downgrades keeps the newer one (apt's own rule)" test "$(ver)" = "$NEWER_V"
run apt-get install -y --allow-downgrades /debs/own-old.deb | tail -2
ok "downgrade with --allow-downgrades works ($OLD_V)" test "$(ver)" = "$OLD_V"
run dpkg -i /debs/own-new.deb
ok "dpkg -i of own newer works" test "$(ver)" = "$NEW_V"
run dpkg -i /debs/own-old.deb
ok "dpkg -i of own older works" test "$(ver)" = "$OLD_V"

say "8. override"
echo "(a) file /etc/hestiacp/allow-foreign-hestia"
mkdir -p /etc/hestiacp
touch /etc/hestiacp/allow-foreign-hestia
run apt-get install -y /work/foreign.deb | tail -3
ok "apt installs the foreign package with the override file" test "$(ver)" = "$FOREIGN_V"
ok "theme is gone as expected (the replaced package does not ship it)" bash -c '! test -e /usr/local/hestia/web/css/themes/vylaris.min.css'
ok "hook removed with the replaced package" test ! -e /etc/apt/apt.conf.d/90vylarisspace-guard
echo "(b) back: foreign installed, install the VylarisSpace package again (no override needed)"
rm -f /etc/hestiacp/allow-foreign-hestia
run apt-get install -y --allow-downgrades /debs/own-old.deb | tail -2
ok "own package installs over the foreign one" test "$(ver)" = "$OLD_V"
ok "guard files are back" test -e /etc/apt/apt.conf.d/90vylarisspace-guard
echo "(c) environment variable VYLARIS_ALLOW_FOREIGN_HESTIA=yes"
VYLARIS_ALLOW_FOREIGN_HESTIA=yes run dpkg -i /work/foreign.deb
ok "dpkg -i with the variable installs the foreign package" test "$(ver)" = "$FOREIGN_V"
reset_own
VYLARIS_ALLOW_FOREIGN_HESTIA=yes run apt-get install -y /work/foreign.deb | tail -2
ok "apt with the variable installs the foreign package" test "$(ver)" = "$FOREIGN_V"
reset_own
ok "VYLARIS_ALLOW_FOREIGN_HESTIA=no does not override" bash -c '! VYLARIS_ALLOW_FOREIGN_HESTIA=no dpkg -i /work/foreign.deb > /dev/null 2>&1'
ok "reset ok" test "$(ver)" = "$OLD_V"

say "9. remove and purge are not blocked, the hook goes with the package"
run dpkg -r hestia | tail -3
ok "dpkg -r works" bash -c '! dpkg -s hestia 2>/dev/null | grep -q "^Status: install ok installed"'
ok "hook removed with the package" test ! -e /etc/apt/apt.conf.d/90vylarisspace-guard
dpkg -i /debs/own-old.deb > /dev/null 2>&1
run apt-get purge -y hestia | tail -2
ok "apt-get purge works" bash -c '! dpkg -s hestia 2>/dev/null | grep -q "^Status: install ok installed"'
ok "hook removed with the package (purge)" test ! -e /etc/apt/apt.conf.d/90vylarisspace-guard
dpkg -i /debs/own-old.deb > /dev/null 2>&1

say "10. apt keeps working when bin/v-check-package-source is missing"
rm -f /usr/local/hestia/bin/v-check-package-source
run apt-get update | tail -2
run apt-get install -y /work/hestia-foo.deb | tail -2
ok "apt installs another package with the checker deleted" dpkg -s hestia-foo
run apt-get install -y --reinstall /debs/own-old.deb | tail -2
ok "apt reinstalls the own package (restores the checker)" test -x /usr/local/hestia/bin/v-check-package-source
rm -f /usr/local/hestia/bin/v-check-package-source
ok "foreign package still refused by the prerm while the checker is missing" bash -c '! apt-get install -y /work/foreign.deb > /dev/null 2>&1'
ok "own version still installed" test "$(ver)" = "$OLD_V"
apt-get install -y --reinstall /debs/own-old.deb > /dev/null 2>&1

say "10b. a broken checker must not block apt (only the deliberate refusal, exit 1, does)"
printf '#!/nonexistent\n' > /usr/local/hestia/bin/v-check-package-source
chmod 755 /usr/local/hestia/bin/v-check-package-source
run apt-get install -y --reinstall /work/hestia-foo.deb | tail -2
ok "apt installs another package although the checker cannot run" dpkg -s hestia-foo
printf '#!/bin/sh\nexit 1\n' > /usr/local/hestia/bin/v-check-package-source
ok "a checker that exits 1 still blocks apt" bash -c '! apt-get install -y --reinstall /work/hestia-foo.deb > /dev/null 2>&1'
apt-get install -y --reinstall /debs/own-old.deb > /dev/null 2>&1 || dpkg -i /debs/own-old.deb > /dev/null 2>&1
ok "checker restored by the own package" bash -c 'echo /work/foreign.deb | /usr/local/hestia/bin/v-check-package-source 2>/dev/null; test $? -eq 1'

say "10c. UPSTREAM_UPDATES=yes counts as the override; a directory named like the override file does not"
mkdir -p /usr/local/hestia/conf
cp -a /usr/local/hestia/conf/hestia.conf /work/hestia.conf.save 2> /dev/null || : > /work/hestia.conf.save
echo "UPSTREAM_UPDATES='yes'" >> /usr/local/hestia/conf/hestia.conf
ok "UPSTREAM_UPDATES=yes: checker passes a foreign hestia" bash -c 'echo /work/foreign.deb | /usr/local/hestia/bin/v-check-package-source'
cp /work/hestia.conf.save /usr/local/hestia/conf/hestia.conf
mkdir -p /etc/hestiacp/allow-foreign-hestia
ok "a directory with the override name does not disable the guard" bash -c 'echo /work/foreign.deb | /usr/local/hestia/bin/v-check-package-source 2>/dev/null; test $? -eq 1'
rmdir /etc/hestiacp/allow-foreign-hestia

say "11. checker: other packages, odd file names, speed"
chk=/usr/local/hestia/bin/v-check-package-source
for p in hestia-nginx hestia-php hestia-web-terminal hestia-foo hestia-tools nothestia; do
	ok "stdin: $p.deb passes" bash -c "echo /work/$p.deb | $chk"
done
ok "stdin: foreign.deb refused (exit 1)" bash -c "echo /work/foreign.deb | $chk; test \$? -eq 1"
ok "stdin: file name with spaces refused" bash -c "echo '/work/dir with space/foreign hestia.deb' | $chk; test \$? -eq 1"
ok "stdin: file name with a leading dash refused" bash -c "cd /work && echo '-foreign.deb' | $chk; test \$? -eq 1"
ok "stdin: own package passes" bash -c "echo /debs/own-new.deb | $chk"
ok "stdin: missing file ignored" bash -c "echo /work/does-not-exist.deb | $chk"
ok "stdin: not a deb ignored" bash -c "echo /etc/hostname | $chk"
ok "stdin: empty input passes" bash -c "$chk < /dev/null"
ok "stdin: no trailing newline still refused" bash -c "printf /work/foreign.deb | $chk; test \$? -eq 1"
ok "stdin: mixed list refused, message names only the foreign file" bash -c "out=\$(printf '/work/hestia-nginx.deb\n/work/foreign.deb\n/work/hestia-php.deb\n' | $chk 2>&1); echo \"\$out\" | grep -q '/work/foreign.deb' && ! echo \"\$out\" | grep -q 'hestia-nginx'"
ok "argument: foreign.deb refused" bash -c "$chk /work/foreign.deb; test \$? -eq 1"
ok "override file makes the checker pass" bash -c "touch /etc/hestiacp/allow-foreign-hestia; echo /work/foreign.deb | $chk; rc=\$?; rm -f /etc/hestiacp/allow-foreign-hestia; test \$rc -eq 0"
ok "override variable makes the checker pass" bash -c "echo /work/foreign.deb | VYLARIS_ALLOW_FOREIGN_HESTIA=yes $chk"
echo "    message of the checker:"
echo /work/foreign.deb | $chk 2>&1 | sed 's/^/      /'
s=$(date +%s%N)
for _ in $(seq 1 50); do echo /debs/own-new.deb | $chk > /dev/null; done
e=$(date +%s%N)
echo "    50 runs with the large own package: $(((e - s) / 1000000)) ms in total"
ok "fast: 50 runs under 5 seconds" test $(((e - s) / 1000000)) -lt 5000

say "12. the shipped checker is the one in the tree"
ok "checker in the package equals bin/v-check-package-source of the checkout" cmp /src/v-check-package-source "$chk"

say "13. after a refusal dpkg calls the installed postinst with abort-upgrade: it must do nothing"
cp /var/lib/dpkg/info/hestia.postinst /work/postinst.orig
printf '#!/bin/sh\necho "postinst $*" >> /work/postinst.calls\nexit 0\n' > /var/lib/dpkg/info/hestia.postinst
chmod 755 /var/lib/dpkg/info/hestia.postinst
rm -f /work/postinst.calls
dpkg -i /work/foreign.deb > /dev/null 2>&1
echo "    calls of the installed postinst during the refused upgrade (stub that only logs):"
sed 's/^/      /' /work/postinst.calls 2> /dev/null || echo "      (none)"
ok "dpkg did call postinst abort-upgrade" grep -q '^postinst abort-upgrade' /work/postinst.calls
cp /work/postinst.orig /var/lib/dpkg/info/hestia.postinst
chmod 755 /var/lib/dpkg/info/hestia.postinst
mkdir -p /usr/local/hestia/data/users/admin
out=$(/var/lib/dpkg/info/hestia.postinst abort-upgrade 1.10.6-1 2>&1)
rc=$?
echo "    real postinst abort-upgrade (data/users present): exit $rc, output: '${out}'"
ok "real postinst does nothing on abort-upgrade" bash -c "test $rc -eq 0 && test -z '$out'"
rm -rf /usr/local/hestia/data

say "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
