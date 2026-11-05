#!/bin/bash
# guard-override.sh - runs INSIDE a throw-away container started from a copy (docker commit) of the
# server after the guard phase. No systemd, no services: only dpkg and apt are exercised.
# It shows that the deliberate override works: the foreign package is installed once the admin
# asks for it with the file /etc/hestiacp/allow-foreign-hestia or VYLARIS_ALLOW_FOREIGN_HESTIA=yes.
#
# Usage: guard-override.sh file|env dpkg|apt
export DEBIAN_FRONTEND=noninteractive LC_ALL=C TERM=dumb
H=/usr/local/hestia
FOREIGN=/guard/foreign.deb
how=${1:?file|env}
tool=${2:?dpkg|apt}
pass=0
fail=0
ok() {
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
install_foreign() {
	if [ "$tool" = dpkg ]; then dpkg -i "$FOREIGN"; else apt-get install -y "$FOREIGN"; fi
}

V0=$(ver)
FV=$(dpkg-deb -f "$FOREIGN" Version)
echo "container 2 ($how override, $tool): installed hestia $V0, foreign $FV"
rm -f /etc/hestiacp/allow-foreign-hestia /root/foreign-postinst-ran

echo "--- without the override the same call is refused"
install_foreign > /tmp/refused.out 2>&1
rc=$?
sed 's/^/    /' /tmp/refused.out
ok "[$how/$tool] refused without the override (exit $rc)" test "$rc" -ne 0
ok "[$how/$tool] still $V0 after the refusal" test "$(ver)" = "$V0"

echo "--- with the override"
if [ "$how" = file ]; then
	touch /etc/hestiacp/allow-foreign-hestia
else
	export VYLARIS_ALLOW_FOREIGN_HESTIA=yes
fi
install_foreign > /tmp/allowed.out 2>&1
rc=$?
sed 's/^/    /' /tmp/allowed.out
ok "[$how/$tool] install succeeds with the override (exit $rc)" test "$rc" -eq 0
ok "[$how/$tool] installed version is now $FV" test "$(ver)" = "$FV"
ok "[$how/$tool] package state ii" test "$(dpkg-query -W -f='${db:Status-Abbrev}' hestia | tr -d ' ')" = ii
ok "[$how/$tool] the foreign file is there" test -e "$H/web/foreign.txt"
ok "[$how/$tool] the foreign postinst ran" test -e /root/foreign-postinst-ran
ok "[$how/$tool] hestia.conf is still there with the owner's APP_NAME" grep -q "^APP_NAME='Customer Brand'" "$H/conf/hestia.conf"
ok "[$how/$tool] customer data untouched (user cust, its web domain config)" test -e "$H/data/users/cust/web.conf"

echo
echo "override ($how/$tool): $pass passed, $fail failed"
exit "$fail"
