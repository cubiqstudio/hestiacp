#!/bin/bash
# guard-phase.sh - runs INSIDE the server container after the update from A to B.
# Tries to put a foreign (upstream-like) hestia package over the installed VylarisSpace package
# and checks that it is refused and that nothing of the server changed.
#
#   /root/guard/foreign.deb   package named hestia, version 1.10.6-1, no Vylaris-Edition field
#
# Output: lines "PASS: ..." and "FAIL: ..." (run.sh counts the FAIL lines), plus the raw output
# of the commands. The exit status is the number of FAIL lines (capped at 100).
export DEBIAN_FRONTEND=noninteractive LC_ALL=C TERM=dumb
H=/usr/local/hestia
FOREIGN=/root/guard/foreign.deb
pass=0
fail=0

ok() { # description, command...
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
say() { printf '\n### %s\n' "$*"; }
ver() { dpkg-query -W -f='${Version}' hestia 2> /dev/null; }
status() { dpkg-query -W -f='${db:Status-Abbrev}' hestia 2> /dev/null | tr -d ' '; }
conf_sha() { sha256sum "$H/conf/hestia.conf" | cut -d' ' -f1; }
login_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:8083/login/; }
# one hash over every file of the package plus the owner's own trees
tree_sha() {
	{
		dpkg-query -L hestia | sort -u | while IFS= read -r p; do [ -f "$p" ] && sha256sum "$p"; done
		find "$H/web/css/themes/custom" "$H/web/js/custom_scripts" "$H/web/images/custom" "$H/data/templates" "$H/data/packages" /etc/hestiacp -type f -exec sha256sum {} +
	} | sort -k2 | sha256sum | cut -d' ' -f1
}

V0=$(ver)
CONF0=$(conf_sha)
TREE0=$(tree_sha)
echo "installed before: hestia $V0 ($(status)), foreign package: $(dpkg-deb -f "$FOREIGN" Package Version | tr '\n' ' ')"
echo "installed package, status file: $(grep -m1 '^Vylaris-Edition' /var/lib/dpkg/status)"
echo "Vylaris-Edition of the foreign package : '$(dpkg-deb -f "$FOREIGN" Vylaris-Edition)'"
rm -f /root/foreign-postinst-ran
ok "guard files of the installed package: hook, checker, prerm" bash -c "test -f /etc/apt/apt.conf.d/90vylarisspace-guard && test -x $H/bin/v-check-package-source && test -x /var/lib/dpkg/info/hestia.prerm"
ok "no override file exists" test ! -e /etc/hestiacp/allow-foreign-hestia
ok "panel login page answers 200 before the attempts" test "$(login_code)" = 200

unchanged() { # label: the installed package and the server are exactly as before
	local l=$1
	ok "$l: installed version is still $V0" test "$(ver)" = "$V0"
	ok "$l: package state is 'ii' (installed, configured)" test "$(status)" = ii
	ok "$l: dpkg --audit reports nothing" test -z "$(dpkg --audit 2>&1)"
	ok "$l: no foreign file was unpacked" test ! -e "$H/web/foreign.txt"
	ok "$l: foreign postinst did not run" test ! -e /root/foreign-postinst-ran
	ok "$l: VylarisSpace themes still present" bash -c "ls $H/web/css/themes/vylaris*.css > /dev/null"
	ok "$l: apt hook, checker and prerm still present" bash -c "test -f /etc/apt/apt.conf.d/90vylarisspace-guard && test -x $H/bin/v-check-package-source && test -x /var/lib/dpkg/info/hestia.prerm"
	ok "$l: hestia.conf byte-identical" test "$(conf_sha)" = "$CONF0"
	ok "$l: every package file and every owner tree file identical" test "$(tree_sha)" = "$TREE0"
	ok "$l: panel login page answers 200" test "$(login_code)" = 200
}

say "1. dpkg -i of the foreign package: refused by the prerm of the installed package"
dpkg -i "$FOREIGN" > /root/guard/dpkg-i.out 2>&1
rc=$?
sed 's/^/    /' /root/guard/dpkg-i.out
echo "    [exit $rc]"
ok "dpkg -i exits non-zero" test "$rc" -ne 0
ok "dpkg -i output says REFUSED" grep -q 'REFUSED' /root/guard/dpkg-i.out
ok "dpkg -i output names the override file" grep -q 'allow-foreign-hestia' /root/guard/dpkg-i.out
unchanged "after dpkg -i"

say "2. apt-get install ./foreign.deb: refused by the apt hook, before dpkg runs"
apt-get install -y "$FOREIGN" > /root/guard/apt-install.out 2>&1
rc=$?
sed 's/^/    /' /root/guard/apt-install.out
echo "    [exit $rc]"
ok "apt-get install exits non-zero" test "$rc" -ne 0
ok "apt-get output says REFUSED" grep -q 'REFUSED' /root/guard/apt-install.out
ok "dpkg was not even started by apt (no 'Unpacking hestia')" bash -c '! grep -q "Unpacking hestia" /root/guard/apt-install.out'
unchanged "after apt-get install"

say "3. another package named like a hestia component passes the hook (hestia-foo is not hestia)"
d=$(mktemp -d)
mkdir -p "$d/t/DEBIAN" "$d/t/usr/share/hestia-foo"
printf 'Package: hestia-foo\nVersion: 1.0-1\nArchitecture: all\nMaintainer: t <t@example.org>\nDescription: stand-in\n' > "$d/t/DEBIAN/control"
echo x > "$d/t/usr/share/hestia-foo/file"
dpkg-deb --root-owner-group -Zgzip -b "$d/t" "$d/hestia-foo.deb" > /dev/null
ok "bin/v-check-package-source accepts hestia-foo.deb" "$H/bin/v-check-package-source" "$d/hestia-foo.deb"
ok "bin/v-check-package-source refuses the foreign hestia.deb" bash -c "! $H/bin/v-check-package-source $FOREIGN"
rm -rf "$d"

say "4. recovery: dpkg and apt are healthy and the panel's own update channel still works"
ok "apt-get check" apt-get check
ok "dpkg --audit empty" test -z "$(dpkg --audit 2>&1)"
$H/bin/v-update-sys-vylaris status > /root/guard/status.out 2>&1
rc=$?
sed 's/^/    /' /root/guard/status.out
ok "v-update-sys-vylaris status works (exit 0)" test "$rc" -eq 0
ok "the foreign file is not in the file list of the package" bash -c '! dpkg-query -L hestia | grep -q foreign.txt'

echo
echo "guard phase: $pass passed, $fail failed"
[ "$fail" -gt 100 ] && fail=100
exit "$fail"
