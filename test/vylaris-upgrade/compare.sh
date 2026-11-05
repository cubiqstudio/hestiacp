#!/bin/bash
# compare.sh - compare two snapshots (snapshot.sh) taken before and after an update.
#
#   compare.sh <before-dir> <after-dir> [--pkg-a A.tsv --pkg-b B.tsv] [--allow FILE] [--strict]
#   compare.sh --pkg-tsv <hestia.deb>        print the file list of a deb in the pkgfiles.tsv format
#
# Reports
#   (a) admin / customer / branding / generated-config files that changed, were removed or added
#   (b) package-owned files: A != B but the installed file is not B (did NOT change when it should),
#       files that changed although A == B, local edits that the update overwrote or kept
#   (c) hestia.conf keys (and /etc/hestiacp) that changed, were added or removed
#   (d) what the panel reports (v-list-*), the customer database, services, apt policy
#
# Every difference is classified:
#   expected  matches a pattern in the ALLOW list below, with the reason. Only things that change
#             by their nature (logs, history, notifications of the update, sessions).
#   UNEXPECTED everything else. The exit status is 1 when there is at least one.
# The ALLOW list is deliberately short; add to it only with a reason.
# --strict: do not use the NORMALIZE list below. A file that differs in a volatile field (disk usage,
#           DNS serial, time stamps) is then UNEXPECTED too. The update from revision 100 to 101 runs
#           no upgrade step and no user rebuild, so run.sh compares strictly: a rebuild would show.
set -u

if [ "${1:-}" = "--pkg-tsv" ]; then
	deb=${2:?deb}
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	dpkg-deb -x "$deb" "$tmp"
	(cd "$tmp" && find . \( -type f -o -type l \) -print0 | sort -z | while IFS= read -r -d '' p; do
		q=${p#.}
		if [ -L "$p" ]; then
			printf '%s\tl\t%s\troot:root\t0\t-\t%s\n' "$q" "$(stat -c %a "$p")" "$(readlink "$p")"
		else
			printf '%s\tf\t%s\troot:root\t%s\t%s\t-\n' "$q" "$(stat -c %a "$p")" "$(stat -c %s "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"
		fi
	done)
	exit 0
fi

BEFORE=${1:?usage: compare.sh <before-dir> <after-dir> [--pkg-a A.tsv --pkg-b B.tsv] [--allow FILE]}
AFTER=${2:?after-dir}
shift 2
PKG_A=''
PKG_B=''
EXTRA_ALLOW=''
STRICT=0
while [ $# -gt 0 ]; do
	case "$1" in
		--pkg-a)
			PKG_A=$2
			shift 2
			;;
		--pkg-b)
			PKG_B=$2
			shift 2
			;;
		--allow)
			EXTRA_ALLOW=$2
			shift 2
			;;
		--strict)
			STRICT=1
			shift
			;;
		*)
			echo "unknown option $1" >&2
			exit 2
			;;
	esac
done

# ---- ALLOW list: <ERE on the path / key><TAB>reason ----
ALLOW=$(mktemp)
trap 'rm -f "$ALLOW" "$ALLOW".*' EXIT
cat > "$ALLOW" << 'EOA'
^/usr/local/hestia/data/sessions/	web sessions, volatile
^/usr/local/hestia/data/queue/	panel job queue, volatile
^/usr/local/hestia/data/users/[^/]+/history\.log$	panel action log of the user, the update itself logs an action
^/usr/local/hestia/data/users/[^/]+/notifications\.conf$	the update adds the "Upgrade complete" notification for the admin
^/usr/local/hestia/data/users/[^/]+/stats\.log$	traffic / disk statistics, recomputed on rebuild
^/usr/local/hestia/data/users/[^/]+/log/	per-user logs
^/usr/local/hestia/conf/defaults/	reference copies of the config formats; written by the upgrade (prepare_upgrade / syshealth), empty on a fresh install
^/usr/local/hestia/data/users/admin/backup/	backup bookkeeping
^/usr/local/hestia/data/(api|firewall)/.*\.lock$	lock files
^/usr/local/hestia/conf/hestia\.conf$	content is compared key by key in section (c)
^/usr/local/hestia/web/css/themes/dark\.min\.css$	CANARY seeded by seed.sh: a package-owned file edited by hand; the documented rule is that package files are replaced by an update (own themes belong in themes/custom)
^/var/spool/cron/crontabs/.*	crontab files are rewritten by the user rebuild; entries compared in (d) via v-list-cron-jobs
EOA
[ -n "$EXTRA_ALLOW" ] && cat "$EXTRA_ALLOW" >> "$ALLOW"

# ---- NORMALIZE list: <ERE on the path><TAB><sed -E expression><TAB>reason> ----
# A changed text file is "expected" only if it is byte-identical after the expression removed the
# volatile fields. Any other difference stays UNEXPECTED.
NORM=$(mktemp)
cat > "$NORM" << 'EON'
^/usr/local/hestia/data/users/[^/]+/((user|web|db|dns|mail|cron)\.conf|(web|db|dns|mail)/[^/]+\.conf)$	s/(U_DISK[A-Z_]*|U_BANDWIDTH|SERIAL|TIME|DATE)='[^']*'//g	the rebuild recomputes disk usage, zone serial and time stamps; no other field differs
^/home/[^/]+/conf/dns/[^/]+\.db$	s/^[[:space:]]+[0-9]{10}[[:space:]]*$/ SERIAL/	the rebuild increments the SOA serial of the zone; the records are identical
^/etc/php/[^/]+/fpm/pool\.d/[^/]+\.conf$	/^; EDITED BY THE OWNER/d	the pool is regenerated from the admin-edited template: the edit made after the domain was created now takes effect (a customisation applied, not lost)
EON
[ "$STRICT" -eq 1 ] && : > "$NORM"
NORM_REASON=''
norm_equal() { # $1 = path; true when before/after are identical after the volatile fields are removed
	local pat expr reason b a
	while IFS=$'\t' read -r pat expr reason; do
		[[ "$1" =~ $pat ]] || continue
		b="$BEFORE/content$1"
		a="$AFTER/content$1"
		[ -f "$b" ] && [ -f "$a" ] || continue
		if cmp -s <(sed -E "$expr" "$b") <(sed -E "$expr" "$a"); then
			NORM_REASON=$reason
			return 0
		fi
	done < "$NORM"
	return 1
}

reason_for() { # $1 = path/key, prints the reason of the first matching ALLOW line, empty if none
	local line pat
	while IFS=$'\t' read -r pat line; do
		[ -n "$pat" ] || continue
		if [[ "$1" =~ $pat ]]; then
			printf '%s' "$line"
			return 0
		fi
	done < "$ALLOW"
	return 1
}

UNEXPECTED=0
UNEXPECTED_PERM=0
EXPECTED=0
report() { # kind path detail
	local r
	if r=$(reason_for "$2"); then
		EXPECTED=$((EXPECTED + 1))
		printf '  expected    %-9s %s %s\n                         reason: %s\n' "$1" "$2" "$3" "$r"
	else
		# a change of mode / owner only is counted separately from a change of content
		if [ "$1" = CHANGED ] && [[ "$2" == /* ]] && [[ "$3" != *content* ]] && [[ "$3" != *type* ]] && [[ "$3" != *link* ]]; then
			UNEXPECTED_PERM=$((UNEXPECTED_PERM + 1))
			printf '  UNEXPECTED  %-9s %s %s  [permissions only]\n' "$1" "$2" "$3"
		else
			UNEXPECTED=$((UNEXPECTED + 1))
			printf '  UNEXPECTED  %-9s %s %s\n' "$1" "$2" "$3"
		fi
	fi
}

# first changed lines of a text file (needs the content/ copies of both snapshots)
show_diff() {
	local b="$BEFORE/content$1" a="$AFTER/content$1"
	[ -f "$b" ] && [ -f "$a" ] || return 0
	grep -qaP '\x00' "$b" "$a" 2> /dev/null && return 0
	diff -u "$b" "$a" | tail -n +3 | grep -E '^[+-]' | head -6 | cut -c1-170 | sed 's/^/                         | /'
}

# row diff of two TSV files (path type mode owner size sha link mtime): prints kind<TAB>path<TAB>detail
tsv_diff() {
	awk -F'\t' '
		NR == FNR { t[$1] = $2; m[$1] = $3; o[$1] = $4; h[$1] = $6; l[$1] = $7; mt[$1] = $8; seen[$1] = 1; next }
		{
			p = $1; cur[p] = 1
			if (!(p in seen)) { print "ADDED\t" p "\t(" $2 " mode " $3 " " $4 ")"; next }
			d = ""
			if (t[p] != $2) d = d " type " t[p] "->" $2
			if (h[p] != $6) d = d " content " substr(h[p], 1, 12) "->" substr($6, 1, 12)
			if (m[p] != $3) d = d " mode " m[p] "->" $3
			if (o[p] != $4) d = d " owner " o[p] "->" $4
			if (l[p] != $7) d = d " link " l[p] "->" $7
			if (d != "") print "CHANGED\t" p "\t" d
			else if ($2 == "f" && mt[p] != $8) print "TOUCHED\t" p "\t(rewritten by the update, content identical)"
		}
		END { for (p in seen) if (!(p in cur)) print "REMOVED\t" p "\t" }
	' "$1" "$2" | sort -t$'\t' -k2
}

echo "================================================================================"
echo " before: $(cat "$BEFORE/label.txt" 2> /dev/null)    after: $(cat "$AFTER/label.txt" 2> /dev/null)    $([ "$STRICT" -eq 1 ] && echo '[strict: no normalisation of volatile fields]')"
echo "================================================================================"

# ---------------------------------------------------------------- (a)
echo
echo "(a) admin / customer / branding / generated-config files  [files.tsv: $(wc -l < "$BEFORE/files.tsv") before, $(wc -l < "$AFTER/files.tsv") after]"
na=0
nt=0
while IFS=$'\t' read -r kind path detail; do
	if [ "$kind" = TOUCHED ]; then
		# rewritten with the same content: no harm here, but an admin edit in this file would have been lost
		reason_for "$path" > /dev/null || {
			nt=$((nt + 1))
			printf '  info        TOUCHED   %s %s\n' "$path" "$detail"
		}
		continue
	fi
	na=$((na + 1))
	if [ "$kind" = CHANGED ] && [[ "$detail" == *content* ]] && norm_equal "$path"; then
		detail=$(sed -E 's/ content [0-9a-f]+->[0-9a-f]+//' <<< "$detail")
		if [ -z "${detail// /}" ]; then
			EXPECTED=$((EXPECTED + 1))
			printf '  expected    %-9s %s\n                         reason: %s\n' "$kind" "$path" "$NORM_REASON"
			continue
		fi
	fi
	report "$kind" "$path" "$detail"
	[ "$kind" = CHANGED ] && [[ "$detail" == *content* ]] && show_diff "$path"
done < <(tsv_diff "$BEFORE/files.tsv" "$AFTER/files.tsv")
[ "$na" -eq 0 ] && echo "  no file in these trees changed"
[ "$nt" -gt 0 ] && echo "  ($nt file(s) marked TOUCHED were rewritten by the update with identical content; not counted as a difference)"

# ---------------------------------------------------------------- (b)
echo
echo "(b) files owned by the package hestia"
if [ -n "$PKG_A" ] && [ -n "$PKG_B" ] && [ -f "$BEFORE/pkgfiles.tsv" ]; then
	# A: what deb A contains, B: what deb B contains, pre: installed before, post: installed after
	awk -F'\t' '
		FILENAME == ARGV[1] { a[$1] = $6; next }
		FILENAME == ARGV[2] { b[$1] = $6; next }
		FILENAME == ARGV[3] { pre[$1] = $6; next }
		FILENAME == ARGV[4] { post[$1] = $6; next }
		function s(h) { return substr(h, 1, 12) }
		END {
			for (p in b) {
				chg = (!(p in a) || a[p] != b[p])
				if (chg && !(p in post)) { print "NOT_INSTALLED\t" p "\t(deb B has it, missing after the update)"; continue }
				edited = (p in pre && p in a && pre[p] != a[p])   # differed from deb A before the update
				if (edited) {
					if (post[p] == pre[p]) print "PRESERVED\t" p "\t(local edit / customisation before the update survived, installed " s(post[p]) ", deb " s(b[p]) ")"
					else if (post[p] == b[p]) print "OVERWRITTEN\t" p "\t(local edit " s(pre[p]) " replaced by the content of deb B " s(b[p]) ")"
					else print "ALTERED\t" p "\t(local edit " s(pre[p]) " became " s(post[p]) ", deb B has " s(b[p]) ")"
				} else if (chg) {
					if (post[p] != b[p]) print "NOT_UPDATED\t" p "\t(A and B differ; installed " s(post[p]) ", deb B has " s(b[p]) ")"
				} else if (p in post && post[p] != b[p]) {
					print "ALTERED\t" p "\t(A == B, but installed after = " s(post[p]) ", deb has " s(b[p]) ")"
				}
			}
			for (p in a) if (!(p in b) && (p in post)) print "STALE\t" p "\t(removed in B but still installed)"
		}
	' "$PKG_A" "$PKG_B" "$BEFORE/pkgfiles.tsv" "$AFTER/pkgfiles.tsv" | sort -t$'\t' -k1,1 -k2,2 > "$ALLOW.b"
	nb=$(wc -l < "$ALLOW.b")
	echo "  package files: A=$(wc -l < "$PKG_A") B=$(wc -l < "$PKG_B") installed before=$(wc -l < "$BEFORE/pkgfiles.tsv") after=$(wc -l < "$AFTER/pkgfiles.tsv")"
	echo "  differences between deb A and deb B: $(awk -F'\t' 'FNR==NR{a[$1]=$6;next} !($1 in a) || a[$1]!=$6{n++} END{print n+0}' "$PKG_A" "$PKG_B") file(s)"
	if [ "$nb" -eq 0 ]; then
		echo "  every package file is exactly the content of deb B, no local edit existed before"
	fi
	echo "  (PRESERVED = a package file the admin had changed before, e.g. the whitelabel logos, still has the admin's content)"
	while IFS=$'\t' read -r kind path detail; do
		case "$kind" in
			PRESERVED) echo "  ok          PRESERVED $path $detail" ;;
			*) report "$kind" "$path" "$detail" ;;
		esac
	done < "$ALLOW.b"
	# files of deb B that must have arrived in this update (A != B) and did
	echo "  files that differ between deb A and B and were installed as deb B: $(awk -F'\t' 'FILENAME==ARGV[1]{a[$1]=$6;next} FILENAME==ARGV[2]{b[$1]=$6;next} {post[$1]=$6} END{n=0;for(p in b) if((!(p in a)||a[p]!=b[p]) && post[p]==b[p]) n++; print n}' "$PKG_A" "$PKG_B" "$AFTER/pkgfiles.tsv")"
else
	echo "  (skipped: --pkg-a/--pkg-b not given)"
fi

# ---------------------------------------------------------------- (c)
echo
echo "(c) hestia.conf keys  [/usr/local/hestia/conf/hestia.conf and /etc/hestiacp]"
for f in hestia-conf.kv etc-hestiacp.kv; do
	echo "  -- $f: $(wc -l < "$BEFORE/$f") keys before, $(wc -l < "$AFTER/$f") after"
	diffs=$(awk -F= '
		NR == FNR { k = $1; sub(/^[^=]*=/, ""); b[k] = $0; next }
		{ k = $1; v = $0; sub(/^[^=]*=/, "", v); cur[k] = 1
		  if (!(k in b)) print "ADDED\t" k "\t= " v
		  else if (b[k] != v) print "CHANGED\t" k "\t" b[k] " -> " v }
		END { for (k in b) if (!(k in cur)) print "REMOVED\t" k "\t(was " b[k] ")" }
	' "$BEFORE/$f" "$AFTER/$f" | sort -t$'\t' -k2)
	if [ -z "$diffs" ]; then
		echo "  unchanged"
	else
		while IFS=$'\t' read -r kind key detail; do
			report "$kind" "$f:$key" "$detail"
		done <<< "$diffs"
	fi
done

# ---------------------------------------------------------------- (d)
echo
echo "(d) what the panel reports, customer database, packages, services"
for f in "$BEFORE"/lists/*.json; do
	n=$(basename "$f")
	if [ ! -f "$AFTER/lists/$n" ]; then
		report REMOVED "list:$n" ""
	elif ! cmp -s "$f" "$AFTER/lists/$n"; then
		report CHANGED "list:$n" "$(diff <(tr ',' '\n' < "$f") <(tr ',' '\n' < "$AFTER/lists/$n") | grep '^[<>]' | head -8 | tr '\n' ' ')"
	fi
done
for f in "$AFTER"/lists/*.json; do
	[ -f "$BEFORE/lists/$(basename "$f")" ] || report ADDED "list:$(basename "$f")" ""
done
if [ -f "$BEFORE/db-content.txt" ]; then
	if cmp -s "$BEFORE/db-content.txt" "$AFTER/db-content.txt"; then
		echo "  customer database content: identical ($(wc -l < "$BEFORE/db-content.txt") rows/lines)"
	else
		report CHANGED "customer-database" "$(diff "$BEFORE/db-content.txt" "$AFTER/db-content.txt" | head -5 | tr '\n' ' ')"
	fi
fi
echo "  health after the update (panel, nginx, bind, failed units, customer site, customer files):"
sed 's/^/      /' "$AFTER/health.txt"
echo "  health, lines that differ from before:"
diff "$BEFORE/health.txt" "$AFTER/health.txt" | grep '^[<>]' | sed 's/^/    /'
[ "${PIPESTATUS[0]}" -eq 0 ] && echo "    (none)"
echo "  apt / pin state before -> after:"
diff <(sed -n '/^---/,$p' "$BEFORE/apt.txt") <(sed -n '/^---/,$p' "$AFTER/apt.txt") | grep '^[<>]' | sed 's/^/    /'
echo "  hestia package: $(grep -m1 '^ii hestia ' "$BEFORE/dpkg.txt") -> $(grep -m1 '^ii hestia ' "$AFTER/dpkg.txt")"
echo "  other packages that changed:"
diff <(grep -v '^[a-z][a-z] ' "$BEFORE/dpkg.txt") <(grep -v '^[a-z][a-z] ' "$AFTER/dpkg.txt") | grep '^[<>]' | sed 's/^/    /' | head -20
[ "${PIPESTATUS[0]}" = 0 ] || true
if cmp -s "$BEFORE/services.txt" "$AFTER/services.txt"; then
	echo "  running services: identical ($(wc -l < "$BEFORE/services.txt"))"
else
	echo "  running services differ:"
	diff "$BEFORE/services.txt" "$AFTER/services.txt" | grep '^[<>]' | sed 's/^/    /'
fi

echo
echo "================================================================================"
echo " RESULT: $UNEXPECTED UNEXPECTED content/removal difference(s), $UNEXPECTED_PERM UNEXPECTED permission-only difference(s),"
echo "         $EXPECTED expected (documented) difference(s)"
echo "================================================================================"
rm -f "$NORM"
[ $((UNEXPECTED + UNEXPECTED_PERM)) -eq 0 ]
