#!/usr/bin/env bash
# assert.sh - explicit checks on the result of one run (host side), on top of compare.sh.
#
#   assert.sh <result-dir> [closed|open]
#
# compare.sh reports every difference it finds; this script states what MUST hold after an update
# from revision 100 to 101 of the same base version:
#   - the update succeeded and ran NO version step and NO user rebuild
#   - therefore: the DNS zone of the customer (webmail record, SOA serial), the modes and owners of
#     every file in the compared trees, and the generated configs are exactly as before
#   - hand-edited and "#" containing hestia.conf values, the whitelabel logos, local.conf survive
#   - the comparison itself finished with 0 unexpected differences
# Prints "PASS:"/"FAIL:" lines. Exit status: number of failed checks (0 = all good).
set -u
RES=${1:?usage: assert.sh <result-dir> [closed|open]}
MODE=${2:-closed}
B=$RES/snap-before
A=$RES/snap-after
fail=0
pass=0

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
nok() { # description, command... (passes when the command FAILS)
	local d=$1
	shift
	if "$@" > /dev/null 2>&1; then
		echo "FAIL: $d"
		fail=$((fail + 1))
	else
		echo "PASS: $d"
		pass=$((pass + 1))
	fi
}
col() { awk -F'\t' -v p="$2" -v c="$3" '$1 == p {print $c; exit}' "$1/files.tsv"; } # snapshot path column
# same_col PATH COLUMN: the value in that column of files.tsv is the same before and after
same_col() {
	[ -n "$(col "$B" "$1" "$2")" ] && [ "$(col "$B" "$1" "$2")" = "$(col "$A" "$1" "$2")" ]
}
logs() { cat "$RES"/upd/update.log "$RES"/upd/hst_backups/*/*.log 2> /dev/null; }

echo "## the update itself"
ok "v-update-sys-vylaris install exited 0" grep -q 'exit status 0' "$RES/summary.txt"
ok "hestia 1.10.5-100 before, 1.10.5-101 after" bash -c "grep -q '^ii hestia 1.10.5-100' $B/dpkg.txt && grep -q '^ii hestia 1.10.5-101' $A/dpkg.txt"
ok "the upgrade procedure ran (log: Starting upgrade from 1.10.5 to 1.10.5)" bash -c "grep -Eq 'Starting upgrade from 1\.10\.5 to 1\.10\.5' <(cat $RES/upd/update.log $RES/upd/hst_backups/*/*.log)"
ok "the upgrade reports that the latest version is already installed" bash -c "grep -q 'latest version of .* is already installed' <(cat $RES/upd/update.log $RES/upd/hst_backups/*/*.log)"

echo "## no version step, no rebuild"
nok "log has no 'applying patches and updates for version'" bash -c "grep -Eqi 'applying patches( and updates)? for( version)? v?[0-9]' <(cat $RES/upd/update.log $RES/upd/hst_backups/*/*.log)"
nok "log does not mention v1.10.6" bash -c "grep -Eq '1\.10\.6([^0-9]|$)' <(cat $RES/upd/update.log $RES/upd/hst_backups/*/*.log)"
nok "log has no rebuild message" bash -c "grep -Eqi 'rebuild' <(cat $RES/upd/update.log $RES/upd/hst_backups/*/*.log)"
# strace follows every process of the update: a rebuild would show as an execve of v-rebuild-*
nok "no v-rebuild-* program was started during the update (strace execve)" grep -Eq 'execve\([^)]*v-rebuild-' "$RES/upd/connect.trace"
nok "no upgrade step script was sourced or run (strace has no versions/*.sh)" grep -Eq 'install/upgrade/versions/[0-9.]+\.sh' "$RES/upd/connect.trace"
echo "     (VERSION in hestia.conf: $(grep '^VERSION=' "$B/hestia-conf.kv") before, $(grep '^VERSION=' "$A/hestia-conf.kv") after)"

echo "## the things the rebuild used to change"
# the customer zone: record file, zone file (SOA serial), the webmail record
ZF=/home/cust/conf/dns/shop.example.org.db
ZC=/usr/local/hestia/data/users/cust/dns/shop.example.org.conf
ok "zone file $ZF has the same content hash (SOA serial unchanged)" same_col "$ZF" 6
ok "record file shop.example.org.conf has the same content hash" same_col "$ZC" 6
ok "webmail record before: CNAME" grep -q "RECORD='webmail'.*TYPE='CNAME'" "$B/content$ZC"
ok "webmail record after: still CNAME (not turned into an A record)" grep -q "RECORD='webmail'.*TYPE='CNAME'" "$A/content$ZC"
ok "zone file text identical before and after (SOA serial included)" cmp -s "$B/content$ZF" "$A/content$ZF"
# modes and owners of everything in the compared trees
perm_changes=$(awk -F'\t' 'NR==FNR {m[$1]=$3; o[$1]=$4; next} ($1 in m) && (m[$1] != $3 || o[$1] != $4) {n++} END {print n+0}' "$B/files.tsv" "$A/files.tsv")
echo "     (modes/owners that differ between before and after in files.tsv: $perm_changes)"
ok "no file or directory changed mode or owner (the 17 permission changes of the rebuild are gone)" test "$perm_changes" -eq 0
for p in /home/cust/web /home/cust/conf/mail /home/cust/conf/dns /home/cust/conf/web /home/cust/web/shop.example.org/logs /usr/local/hestia/data/users/cust/cron.conf; do
	[ -n "$(col "$B" "$p" 3)" ] || continue
	ok "mode and owner of $p unchanged ($(col "$A" "$p" 3) $(col "$A" "$p" 4))" bash -c "[ \"$(col "$B" "$p" 3) $(col "$B" "$p" 4)\" = \"$(col "$A" "$p" 3) $(col "$A" "$p" 4)\" ]"
done
# generated customer configs must not even be rewritten
rewritten=$(awk -F'\t' 'NR==FNR {h[$1]=$8; next} ($1 in h) && $2=="f" && h[$1] != $8 && $1 ~ /^\/(home\/cust\/(conf|web)|etc\/(nginx\/conf\.d\/domains|php\/[^\/]+\/fpm\/pool\.d))/ {n++} END {print n+0}' "$B/files.tsv" "$A/files.tsv")
ok "no generated config of the customer (nginx domains, php-fpm pool, mail, dns, document_errors) was rewritten ($rewritten with a new mtime)" test "$rewritten" -eq 0

echo "## hestia.conf: hand edits and values with a hash sign"
for kv in "APP_NAME='Customer Brand'" "THEME='vylaris-dark'" "HIDE_DOCS='no'" "LANGUAGE='de'" "BACKUP_GZIP='7'" "OWNER_NOTE='written by hand, must survive'" "SERVER_SMTP_PASSWD='pa#ss'" "OWNER_HASH_NOTE='a#b # c&d|e'"; do
	ok "before and after: $kv" bash -c "grep -qxF \"$kv\" $B/hestia-conf.kv && grep -qxF \"$kv\" $A/hestia-conf.kv"
done
ok "the raw hestia.conf line SERVER_SMTP_PASSWD='pa#ss' is intact after the update" grep -qxF "SERVER_SMTP_PASSWD='pa#ss'" "$A/content/usr/local/hestia/conf/hestia.conf"
ok "/etc/hestiacp/local.conf unchanged" same_col /etc/hestiacp/local.conf 6
# last value of a key wins (the same rule as compare.sh and as the upgrade); VERSION is excluded
lastwins() { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | grep -v '^VERSION=' | awk -F= '{k=$1; v=$0; sub(/^[^=]*=/, "", v); val[k]=v; if (!(k in pos)) {pos[k]=++n; key[n]=k}} END {for (i=1;i<=n;i++) print key[i] "=" val[key[i]]}' | sort; }
RAWB=$B/content/usr/local/hestia/conf/hestia.conf
RAWA=$A/content/usr/local/hestia/conf/hestia.conf
ok "no key was added, removed or changed (raw hestia.conf, last line of a key wins, VERSION excluded)" bash -c "diff <($(declare -f lastwins); lastwins $RAWB) <($(declare -f lastwins); lastwins $RAWA)"
ok "OWNER_DUP was written twice before; after the update it is one line with the last value" bash -c "[ \"\$(grep -c '^OWNER_DUP=' $RAWB)\" = 2 ] && [ \"\$(grep -c '^OWNER_DUP=' $RAWA)\" = 1 ] && grep -qxF \"OWNER_DUP='last#value|with&chars'\" $RAWA"
ok "SERVER_SMTP_PASSWD is present once, with the hash sign" bash -c "[ \"\$(grep -c '^SERVER_SMTP_PASSWD=' $A/hestia-conf.kv)\" = 1 ]"

echo "## whitelabel"
LOGO=$(awk -F'\t' '$1=="/usr/local/hestia/web/images/logo.svg" {print $6}' "$A/pkgfiles.tsv")
CUSTOM=$(col "$A" /usr/local/hestia/web/images/custom/logo.svg 6)
ok "web/images/logo.svg is still the owner's logo (hash equals web/images/custom/logo.svg)" test -n "$LOGO" -a "$LOGO" = "$CUSTOM"
ok "custom theme, custom script and custom logos unchanged" bash -c "[ \"$(col "$B" /usr/local/hestia/web/css/themes/custom/mytheme.css 6)\" = \"$(col "$A" /usr/local/hestia/web/css/themes/custom/mytheme.css 6)\" ] && [ \"$(col "$B" /usr/local/hestia/web/js/custom_scripts/custom.js 6)\" = \"$(col "$A" /usr/local/hestia/web/js/custom_scripts/custom.js 6)\" ]"

echo "## health after the update"
ok "panel login page answers 200" grep -q '^panel login page: 200' "$A/health.txt"
ok "customer site answers with its marker" grep -q 'customer site http : SEED-MARKER' "$A/health.txt"
ok "customer own nginx include still served" grep -qi 'x-customer-include-ssl' "$A/health.txt"
ok "customer database rows identical" cmp -s "$B/db-content.txt" "$A/db-content.txt"

echo "## the comparison"
if [ "$MODE" = closed ]; then
	ok "compare.sh: 0 unexpected content/removal and 0 unexpected permission-only differences" grep -Eq 'RESULT: 0 UNEXPECTED content/removal difference\(s\), 0 UNEXPECTED permission-only' "$RES/compare.txt"
else
	echo "NOTE: open network run, the comparison is not asserted (the Cloudflare list is replaced from api.cloudflare.com, see README)"
fi

echo
echo "assert.sh: $pass passed, $fail failed"
exit "$fail"
